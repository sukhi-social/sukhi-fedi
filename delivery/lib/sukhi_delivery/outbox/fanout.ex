# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Fanout do
  @moduledoc """
  Event payload → Oban jobs. `translate_and_fanout/6` signs the payload,
  asks the Bun translator for the activity, and `enqueue_jobs/5` pushes it to
  each inbox (and logs it for hosts that pull instead).
  """

  require Logger

  alias SukhiDelivery.Delivery.{FedifyClient, Worker}
  alias SukhiDelivery.PullFederation
  alias SukhiDelivery.Schema.Account

  @doc false
  def translate_and_fanout(object_type, payload, actor_uri, activity_id, inboxes, opts \\ []) do
    payload = inject_signing_for(payload, actor_uri)

    case FedifyClient.translate(object_type, payload) do
      {:ok, translator_result} ->
        body =
          extract_body(translator_result, object_type, opts)

        enqueue_jobs(body, actor_uri, activity_id, inboxes, Keyword.get(opts, :pull))

      {:error, reason} ->
        Logger.warning("Outbox.Consumer: translate(#{object_type}) failed: #{inspect(reason)}")

        :translate_failed
    end
  end

  # Bun translator results carry the payload under different keys per
  # type. Pick the right one — fall back to the whole result.
  defp extract_body(result, "note", _opts), do: Map.get(result, "note", result)
  defp extract_body(result, "update", _opts), do: Map.get(result, "update", result)
  defp extract_body(result, "vote", _opts), do: Map.get(result, "note", result)
  defp extract_body(result, "dm", _opts), do: Map.get(result, "note", result)
  defp extract_body(result, "delete", _opts), do: Map.get(result, "delete", result)
  defp extract_body(result, "follow", _opts), do: Map.get(result, "follow", result)
  defp extract_body(result, "quote_request", _opts), do: Map.get(result, "quoteRequest", result)
  defp extract_body(result, "announce", _opts), do: Map.get(result, "announce", result)
  defp extract_body(result, "like", _opts), do: Map.get(result, "like", result)
  defp extract_body(result, "emoji_react", _opts), do: Map.get(result, "emojiReact", result)
  defp extract_body(result, "undo", _opts), do: Map.get(result, "undo", result)
  defp extract_body(result, "move", _opts), do: Map.get(result, "move", result)
  defp extract_body(result, "add", _opts), do: Map.get(result, "activity", result)
  defp extract_body(result, "remove", _opts), do: Map.get(result, "activity", result)
  defp extract_body(result, _type, _opts), do: result

  # `pull` is `%{account_id: id, hosts: [host]}` for an activity that goes
  # to some followers by notification instead of by POST, else nil. The
  # decision of *which* hosts is `PullFederation.Route`'s, made by the caller
  # before translation; here the activity is only logged and the hosts told.
  @doc false
  def enqueue_jobs(body, actor_uri, activity_id, inboxes, pull \\ nil) do
    pushed = push_jobs(body, actor_uri, activity_id, inboxes)
    pulled = pull_jobs(pull, activity_id, body)

    # Only the activities that *could* have gone by notification are counted,
    # so the push/pull ratio on the dashboard compares like with like.
    if pull, do: SukhiShared.PullStats.bump("push_routed", n: length(Enum.uniq(inboxes)))

    if pushed == :no_recipients and pulled == :none, do: :no_recipients, else: :ok
  end

  defp pull_jobs(%{account_id: account_id, hosts: [_ | _] = hosts}, activity_id, body) do
    {:ok, _} = PullFederation.Log.append(account_id, activity_id, body)
    PullFederation.Notifier.schedule(hosts)
    SukhiShared.PullStats.bump("pull_routed", n: length(hosts))
    :ok
  end

  defp pull_jobs(_pull, _activity_id, _body), do: :none

  defp push_jobs(_body, _actor_uri, _activity_id, []), do: :no_recipients

  defp push_jobs(body, actor_uri, activity_id, inboxes) do
    inboxes = Enum.uniq(inboxes)

    base = %{
      raw_json: body,
      actor_uri: actor_uri,
      activity_id: activity_id
    }

    changesets =
      Enum.map(inboxes, fn inbox -> base |> Map.put(:inbox_url, inbox) |> Worker.new() end)

    Oban.insert_all(SukhiDelivery.Oban, changesets)
    :ok
  end

  # Add the RSA private JWK + keyId every translator needs so the bun
  # builder can produce a valid RsaSignature2017 LD-sig. Without these
  # bun would fall back to generating an in-memory Ed25519 keypair
  # whose signature can't be verified against the actor's published
  # publicKeyPem — that mismatch is what hackers.pub was choking on.
  defp inject_signing_for(payload, actor_uri)
       when is_map(payload) and is_binary(actor_uri) do
    domain = SukhiDelivery.Config.domain!()
    expected_prefix = "https://#{domain}/users/"

    if String.starts_with?(actor_uri, expected_prefix) do
      username = String.replace_prefix(actor_uri, expected_prefix, "")

      case SukhiDelivery.Accounts.by_local_username(username) do
        %Account{private_key_jwk: jwk} = account when is_map(jwk) ->
          payload
          |> Map.put(:privateKeyJwk, jwk)
          |> Map.put(:keyId, "#{actor_uri}#main-key")
          |> put_ed25519_signing(account, actor_uri)

        _ ->
          payload
      end
    else
      payload
    end
  end

  defp inject_signing_for(payload, _), do: payload

  # The Ed25519 key signs a FEP-8b32 Object Integrity Proof alongside
  # the RSA LD-sig. The keyId must match the `assertionMethod` Multikey
  # id ActorJson publishes, or receivers can't resolve the proof.
  defp put_ed25519_signing(payload, %Account{ed25519_private_key_jwk: jwk}, actor_uri)
       when is_map(jwk) do
    payload
    |> Map.put(:ed25519PrivateKeyJwk, jwk)
    |> Map.put(:ed25519KeyId, "#{actor_uri}#ed25519-key")
  end

  defp put_ed25519_signing(payload, _account, _actor_uri), do: payload
end
