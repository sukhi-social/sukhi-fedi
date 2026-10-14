# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.Ojak do
  @moduledoc """
  The one door to `ojak-ex` (Rust signatures + JSON-LD, as a NIF).

  Nothing else in the tree calls `Ojak.*` — key shapes, error shapes and
  the two switches live here, so an audit of "what does the NIF touch"
  reads one file:

    * `shadow?/0` — `OJAK_SHADOW=1`. Verifiers keep their own answer and
      only *compare* with ojak's (`OjakShadow`).
    * `ld_backend/0` — `OJAK_LD_BACKEND=ojak`. `LdSignature` signs and
      verifies through ojak instead of `Canon` + `:public_key`.

  Both default off: with neither set, ojak is loaded but never called.

  The adapter speaks our dialect on both sides:

    * keys come in as what `Fedi.JWK` produces (`:public_key` records,
      raw Ed25519 bytes, the PEM from a remote actor document) and leave
      ojak as PEM / `{:ed25519, bytes}`;
    * results are `:ok | {:error, atom}`, with ojak's `{:not_covered, _}`
      style reasons flattened to their atom.

  ojak only reports *whose key* verified; binding that to the activity's
  `actor` stays with the callers (`Verifier`, `Oip.check_controller/2`).
  A NIF fault, unlike a raise, takes the VM down; the only bound on
  what reaches it is `Plug.Parsers`' default body limit at the router.
  """

  alias SukhiFedi.Fedi.JWK

  @doc "Whether verifiers should also ask ojak and log disagreements."
  @spec shadow?() :: boolean()
  def shadow?, do: Application.get_env(:sukhi_fedi, :ojak_shadow, false) == true

  @doc "Which implementation `LdSignature` uses."
  @spec ld_backend() :: :native | :ojak
  def ld_backend do
    case Application.get_env(:sukhi_fedi, :ld_backend, :native) do
      :ojak -> :ojak
      _ -> :native
    end
  end

  # ── HTTP signatures ──────────────────────────────────────────────────────

  @doc """
  Verifies an inbound HTTP signature (cavage or RFC 9421, detected from
  the headers) against an already-fetched RSA public key PEM. Same inputs
  as `HttpSignature.verify/6`, with the key in its published PEM form.
  """
  @spec verify_http_signature(
          String.t(),
          String.t(),
          %{String.t() => String.t()},
          binary(),
          String.t(),
          keyword()
        ) :: :ok | {:error, atom()}
  def verify_http_signature(method, url, headers, body, public_pem, opts \\ []) do
    uri = URI.parse(url)
    request = {String.upcase(method), path_and_query(uri), Map.to_list(headers), body}
    fetch_key = fn _key_id -> {:ok, {:rsa_pem, public_pem}} end

    guard(fn ->
      request
      |> Ojak.HTTPSignature.verify(Keyword.merge([hosts: hosts(uri), fetch_key: fetch_key], opts))
      |> verdict()
    end)
  end

  # ── FEP-8b32 object integrity proofs ─────────────────────────────────────

  @doc """
  Verifies the `proof` member of `document` against a raw 32-byte Ed25519
  public key (what `JWK.ed25519_public_key_from_multibase/1` returns).
  """
  @spec verify_proof(map(), JWK.ed25519_public_key(), keyword()) :: :ok | {:error, atom()}
  def verify_proof(document, <<_::binary-size(32)>> = public_key, opts \\ []) do
    fetch_key = fn _verification_method -> {:ok, {:ed25519, public_key}} end

    guard(fn -> document |> Ojak.Proof.verify([fetch_key: fetch_key] ++ opts) |> verdict() end)
  end

  # ── RsaSignature2017 ─────────────────────────────────────────────────────

  @doc """
  `LdSignature.sign/4` through ojak. `:created` (ISO 8601) pins the clock
  the way it does for the native signer.
  """
  @spec ld_sign(map(), JWK.rsa_private_key(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def ld_sign(document, private_key, key_id, opts \\ []) do
    guard(fn ->
      with {:ok, key} <- Ojak.Key.from_pem(private_pem(private_key)),
           {:ok, signed} <-
             Ojak.LinkedDataSignature.sign(document, key, [key_id: key_id] ++ now_opt(opts)) do
        {:ok, signed}
      else
        {:error, reason} -> {:error, reason_atom(reason)}
      end
    end)
  end

  @doc "`LdSignature.verify/2` through ojak."
  @spec ld_verify(map(), JWK.rsa_public_key(), keyword()) :: :ok | {:error, atom()}
  def ld_verify(document, public_key, opts \\ [])

  def ld_verify(%{"signature" => _} = document, public_key, opts) do
    pem = public_pem(public_key)
    fetch_key = fn _creator -> {:ok, {:rsa_pem, pem}} end

    guard(fn ->
      document
      |> Ojak.LinkedDataSignature.verify([fetch_key: fetch_key] ++ opts)
      |> verdict()
      |> invalid_as_bad_signature()
    end)
  end

  def ld_verify(_document, _public_key, _opts), do: {:error, :no_signature}

  # ── Pieces ───────────────────────────────────────────────────────────────

  # `Ojak.Key.from_pem/2` reads the PEM strictly and refuses the blank line
  # `:public_key.pem_encode/1` leaves at the end (ojak-ex README, "Before you
  # use it"), so the tail is trimmed here and nowhere else.
  defp private_pem(private_key) do
    [:public_key.pem_entry_encode(:RSAPrivateKey, private_key)]
    |> :public_key.pem_encode()
    |> String.trim_trailing()
  end

  defp public_pem(public_key) do
    [:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)]
    |> :public_key.pem_encode()
    |> String.trim_trailing()
  end

  defp now_opt(opts) do
    with created when is_binary(created) <- Keyword.get(opts, :created),
         {:ok, at, _offset} <- DateTime.from_iso8601(created) do
      [now: at]
    else
      _ -> []
    end
  end

  defp path_and_query(%URI{path: path, query: nil}), do: path || "/"
  defp path_and_query(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  # The `Host` a peer signs is `host[:port]`; accept both spellings of the
  # URL's own authority and nothing else.
  defp hosts(%URI{host: host, port: port, scheme: scheme}) do
    default = URI.default_port(scheme)
    if port in [nil, default], do: [host], else: [host, "#{host}:#{port}"]
  end

  # What every verify here hands back: `:ok` or `{:error, atom}`, whatever
  # ojak's success value and error detail look like.
  defp verdict({:ok, _info}), do: :ok
  defp verdict({:error, reason}), do: {:error, reason_atom(reason)}

  # ojak says `:invalid` for a signature that does not match; the native
  # verifier (and its callers) call that `:bad_signature`.
  defp invalid_as_bad_signature({:error, :invalid}), do: {:error, :bad_signature}
  defp invalid_as_bad_signature(verdict), do: verdict

  defp reason_atom(reason) when is_atom(reason), do: reason
  defp reason_atom({reason, _detail}) when is_atom(reason), do: reason
  defp reason_atom(_), do: :ojak_error

  # A Rust panic arrives as an Elixir exception. Callers get an error
  # tuple, same as for a bad signature — a shadow run must never take a
  # request down, and a switched run rejects instead of crashing.
  defp guard(fun) do
    fun.()
  rescue
    _ -> {:error, :ojak_error}
  end
end
