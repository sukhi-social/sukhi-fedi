# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Auth.Passkeys do
  @moduledoc """
  WebAuthn passkeys: register in settings, then log in with the key
  alone (discoverable credential, user verification required — the
  authenticator's own unlock is the second factor, so passkey login
  does not stack TOTP on top).

  The spec-heavy byte verification is Wax's job; ours is the state
  around it: one-shot challenges parked in `webauthn_challenges`
  between the options call and the browser's answer, credentials in
  `webauthn_credentials`, and the clone check on the signature
  counter. All binary fields cross this boundary base64url-encoded,
  exactly as the browser's `PublicKeyCredential` JSON hands them over;
  decoding happens here, once.
  """

  import Ecto.Query

  require Logger

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, WebauthnChallenge, WebauthnCredential}

  @challenge_ttl_seconds 300
  # Bound storage/abuse, but generously: a real device label ("Bob's iPhone 15
  # Pro") is far shorter, and a tight 50-char cap once silently ate the tail
  # of a longer label. Stay under the varchar(255) column.
  @nickname_max 200

  # ── registration (signed-in) ─────────────────────────────────────────────

  @doc """
  Mint a registration challenge. Returns `{ref, options}` where `ref`
  is echoed back by the client with the authenticator's response and
  `options` is the browser's `publicKey` creation dict (binary fields
  base64url; the SPA inflates them to ArrayBuffers).
  """
  @spec register_options(Account.t()) :: {String.t(), map()}
  def register_options(%Account{} = account) do
    challenge =
      Wax.new_registration_challenge(
        origin: origin(),
        rp_id: rp_id(),
        attestation: "none",
        user_verification: "required",
        timeout: @challenge_ttl_seconds
      )

    ref = store_challenge(challenge, "register", account.id)

    exclude =
      for cred <- list(account) do
        %{type: "public-key", id: cred.credential_id}
      end

    options = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rp: %{id: rp_id(), name: domain()},
      user: %{
        id: Base.url_encode64(Integer.to_string(account.id), padding: false),
        name: account.username,
        displayName: account.display_name || account.username
      },
      pubKeyCredParams: [
        %{type: "public-key", alg: -7},
        %{type: "public-key", alg: -257},
        %{type: "public-key", alg: -8}
      ],
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "required"
      },
      excludeCredentials: exclude,
      timeout: @challenge_ttl_seconds * 1000,
      attestation: "none"
    }

    {ref, options}
  end

  @spec register_finish(Account.t(), map()) ::
          {:ok, WebauthnCredential.t()}
          | {:error, :invalid_challenge | :verification_failed | :already_registered}
  def register_finish(%Account{id: account_id}, %{} = params) do
    with {:ok, attestation_object} <- b64(params["attestation_object"]),
         {:ok, client_data_json} <- b64(params["client_data_json"]),
         {:ok, row} <- take_challenge(params["ref"], "register"),
         :ok <- challenge_owner_ok(row, account_id),
         {:ok, challenge} <- restore(row),
         {:ok, {auth_data, _attestation_result}} <-
           wax_register(attestation_object, client_data_json, challenge) do
      acd = auth_data.attested_credential_data

      %WebauthnCredential{}
      |> Ecto.Changeset.change(
        account_id: account_id,
        credential_id: Base.url_encode64(acd.credential_id, padding: false),
        cose_key: :erlang.term_to_binary(acd.credential_public_key),
        sign_count: auth_data.sign_count,
        nickname: nickname(params["nickname"])
      )
      |> Ecto.Changeset.unique_constraint(:credential_id,
        name: :webauthn_credentials_credential_id_index
      )
      |> Repo.insert()
      |> case do
        {:ok, cred} -> {:ok, cred}
        {:error, %Ecto.Changeset{}} -> {:error, :already_registered}
      end
    end
  end

  # ── login (nobody signed in) ─────────────────────────────────────────────

  @spec login_options() :: {String.t(), map()}
  def login_options do
    challenge =
      Wax.new_authentication_challenge(
        origin: origin(),
        rp_id: rp_id(),
        user_verification: "required",
        allow_credentials: [],
        timeout: @challenge_ttl_seconds
      )

    ref = store_challenge(challenge, "login", nil)

    options = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rpId: rp_id(),
      userVerification: "required",
      timeout: @challenge_ttl_seconds * 1000
    }

    {ref, options}
  end

  @spec login_finish(map()) ::
          {:ok, Account.t()}
          | {:error, :invalid_challenge | :verification_failed | :unknown_credential}
  def login_finish(%{} = params) do
    credential_id = to_string(params["credential_id"] || "")

    with {:ok, authenticator_data} <- b64(params["authenticator_data"]),
         {:ok, signature} <- b64(params["signature"]),
         {:ok, client_data_json} <- b64(params["client_data_json"]),
         {:ok, row} <- take_challenge(params["ref"], "login"),
         {:ok, challenge} <- restore(row),
         {:ok, cred} <- find_credential(credential_id),
         :ok <- user_handle_ok(params["user_handle"], cred),
         {:ok, auth_data} <-
           wax_authenticate(credential_id, authenticator_data, signature, client_data_json, challenge, cred),
         :ok <- sign_count_ok(auth_data.sign_count, cred.sign_count) do
      touch(cred, auth_data.sign_count)
      {:ok, Repo.get!(Account, cred.account_id)}
    end
  end

  # ── settings surface ─────────────────────────────────────────────────────

  @spec list(Account.t()) :: [WebauthnCredential.t()]
  def list(%Account{id: account_id}) do
    from(c in WebauthnCredential, where: c.account_id == ^account_id, order_by: c.id)
    |> Repo.all()
  end

  # Only the label moves. The key itself, its counter and its dates stay as
  # they are — a renamed key is the same key.
  @spec rename(Account.t(), term(), term()) ::
          {:ok, WebauthnCredential.t()} | {:error, :not_found}
  def rename(%Account{id: account_id}, id, nickname) do
    {n, rows} =
      from(c in WebauthnCredential,
        where: c.account_id == ^account_id and c.id == ^id,
        select: c
      )
      |> Repo.update_all(set: [nickname: nickname(nickname)])

    case {n, rows} do
      {1, [cred]} -> {:ok, cred}
      _ -> {:error, :not_found}
    end
  end

  @spec delete(Account.t(), term()) :: :ok | {:error, :not_found}
  def delete(%Account{id: account_id}, id) do
    {n, _} =
      from(c in WebauthnCredential, where: c.account_id == ^account_id and c.id == ^id)
      |> Repo.delete_all()

    case n do
      1 -> :ok
      0 -> {:error, :not_found}
    end
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp store_challenge(challenge, purpose, account_id) do
    ref = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@challenge_ttl_seconds, :second)
      |> DateTime.truncate(:second)

    {:ok, _} =
      Repo.insert(%WebauthnChallenge{
        ref: ref,
        account_id: account_id,
        purpose: purpose,
        challenge: :erlang.term_to_binary(challenge),
        expires_at: expires_at
      })

    ref
  end

  # One-shot claim: the DELETE returns the row at most once, so a
  # replayed ref loses even when two requests race.
  defp take_challenge(ref, purpose) when is_binary(ref) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Opportunistic sweep — keeps the table at "ceremonies in flight".
    _ = from(c in WebauthnChallenge, where: c.expires_at < ^now) |> Repo.delete_all()

    {n, rows} =
      from(c in WebauthnChallenge, where: c.ref == ^ref and c.purpose == ^purpose, select: c)
      |> Repo.delete_all()

    case {n, rows} do
      {1, [row]} -> {:ok, row}
      _ -> {:error, :invalid_challenge}
    end
  end

  defp take_challenge(_, _), do: {:error, :invalid_challenge}

  defp challenge_owner_ok(%WebauthnChallenge{account_id: id}, id), do: :ok
  defp challenge_owner_ok(_, _), do: {:error, :invalid_challenge}

  defp restore(%WebauthnChallenge{challenge: blob}) do
    {:ok, Plug.Crypto.non_executable_binary_to_term(blob, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_challenge}
  end

  defp find_credential(credential_id) when byte_size(credential_id) > 0 do
    case Repo.get_by(WebauthnCredential, credential_id: credential_id) do
      nil -> {:error, :unknown_credential}
      cred -> {:ok, cred}
    end
  end

  defp find_credential(_), do: {:error, :unknown_credential}

  # A discoverable credential reports the userHandle it was created
  # with (our account id). When present it must point at the same
  # account the credential row belongs to — a mismatch is someone
  # splicing ceremonies together.
  defp user_handle_ok(nil, _cred), do: :ok
  defp user_handle_ok("", _cred), do: :ok

  defp user_handle_ok(handle_b64, cred) do
    expected = Integer.to_string(cred.account_id)

    case Base.url_decode64(to_string(handle_b64), padding: false) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :verification_failed}
    end
  end

  defp wax_register(attestation_object, client_data_json, challenge) do
    case Wax.register(attestation_object, client_data_json, challenge) do
      {:ok, _} = ok ->
        ok

      {:error, e} ->
        Logger.info("passkeys: registration rejected: #{Exception.message(e)}")
        {:error, :verification_failed}
    end
  end

  defp wax_authenticate(credential_id, authenticator_data, signature, client_data_json, challenge, cred) do
    cose_key = Plug.Crypto.non_executable_binary_to_term(cred.cose_key, [:safe])

    case Wax.authenticate(
           credential_id,
           authenticator_data,
           signature,
           client_data_json,
           challenge,
           [{credential_id, cose_key}]
         ) do
      {:ok, _} = ok ->
        ok

      {:error, e} ->
        Logger.info("passkeys: assertion rejected: #{Exception.message(e)}")
        {:error, :verification_failed}
    end
  end

  # WebAuthn §6.1.1: authenticators may not implement the counter (both
  # stay 0 — Apple passkeys do this). When it is implemented it must
  # move strictly forward; a stale value means a cloned key.
  defp sign_count_ok(0, 0), do: :ok
  defp sign_count_ok(new, stored) when new > stored, do: :ok

  defp sign_count_ok(new, stored) do
    Logger.warning("passkeys: sign count regressed (#{stored} → #{new}) — possible clone")
    {:error, :verification_failed}
  end

  defp touch(cred, sign_count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      from(c in WebauthnCredential, where: c.id == ^cred.id)
      |> Repo.update_all(set: [sign_count: sign_count, last_used_at: now])
  end

  defp nickname(nil), do: nil

  defp nickname(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      s -> String.slice(s, 0, @nickname_max)
    end
  end

  defp b64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :verification_failed}
    end
  end

  defp b64(_), do: {:error, :verification_failed}

  defp domain, do: Application.get_env(:sukhi_fedi, :domain, "localhost:4000")

  defp rp_id, do: domain() |> String.split(":", parts: 2) |> hd()

  defp origin do
    d = domain()
    scheme = if String.starts_with?(d, "localhost"), do: "http", else: "https"
    "#{scheme}://#{d}"
  end
end
