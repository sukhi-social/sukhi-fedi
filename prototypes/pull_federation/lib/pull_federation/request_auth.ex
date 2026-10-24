# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.RequestAuth do
  @moduledoc """
  The signature on a pull request: who is asking, for what, until when.
  The shape of an RFC 9421 signature with `created`, `expires`, `nonce`,
  `tag` and the covered components `@authority`/`@target-uri` (here
  `target`) and the cursors; the prototype signs Erlang's deterministic
  term encoding instead of the HTTP serialisation.

  It authenticates the *requester*. TLS shows the client the server, not
  the server the client; without this, the domain named in a request is
  just a claim. Activities need their own proof (`PullFederation.Proof`).

  `verify/5` is the whole check; `Origin.authenticated_stream/6` calls it
  once at the boundary and everything behind it trusts the domain.
  """

  @tag "pull-federation"
  @window_ms 60_000
  @skew_ms 5_000

  def keypair, do: PullFederation.Proof.keypair()

  def window_ms, do: @window_ms

  @doc "Sign a pull request for `target` with `cursors` as `domain`."
  def sign(domain, target, cursors, created, private, nonce \\ nil) do
    req = %{
      domain: domain,
      target: target,
      cursors: digest(cursors),
      created: created,
      expires: created + @window_ms,
      tag: @tag,
      nonce: nonce || Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    }

    Map.put(req, :sig, :crypto.sign(:eddsa, :none, message(req), [private, :ed25519]))
  end

  @doc """
  `keys` is `%{domain => public key}`. Errors: `:unauthenticated` (no
  signature, unknown domain, bad signature, wrong tag/target/cursors) and
  `:expired` (outside `created - skew .. expires`).
  """
  def verify(req, keys, target, cursors, now) do
    with %{domain: domain, sig: sig} <- req,
         {:ok, pub} <- Map.fetch(keys, domain),
         true <- req.tag == @tag and req.target == target and req.cursors == digest(cursors),
         true <- :crypto.verify(:eddsa, :none, message(req), sig, [pub, :ed25519]) do
      case now >= req.created - @skew_ms and now <= req.expires do
        true -> {:ok, domain, req.nonce, req.expires}
        false -> {:error, :expired}
      end
    else
      _ -> {:error, :unauthenticated}
    end
  end

  defp digest(cursors),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(cursors, [:deterministic]))

  defp message(req), do: :erlang.term_to_binary(Map.delete(req, :sig), [:deterministic])
end
