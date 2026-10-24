# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Recipients do
  @moduledoc """
  Who an outbox event is for: resolving the acting local account, the
  followers' / author's / relays' inboxes, and the AP ids derived from them.
  Local actors use the `<actor_uri>/inbox` convention (no network hop); remote
  ones go through `Federation.ActorFetcher.inbox_for/1`.
  """

  import Ecto.Query

  alias SukhiDelivery.Relays
  alias SukhiDelivery.Repo
  alias SukhiDelivery.Schema.{Account, Follow}

  @doc false
  def local_actor_uri(%Account{username: u}) do
    domain = SukhiDelivery.Config.domain!()
    "https://#{domain}/users/#{u}"
  end

  @doc false
  def parse_id(id) when is_integer(id), do: id
  def parse_id(id) when is_binary(id), do: String.to_integer(id)

  # ── DB helpers ───────────────────────────────────────────────────────────

  # A genuinely-missing account (Repo.get → nil) or an unparseable id is
  # structural → nil → :no_actor → ACK. But a transient DB error (Repo.get
  # raising on a dropped connection) must NOT be swallowed to nil: that maps a
  # retryable failure onto the permanent :no_actor path and silently drops the
  # outbound activity for an account that really exists. So we no longer
  # blanket-rescue — a DB exception bubbles to handle_event/2's try, which
  # returns :crashed (transient → backoff + retry, never an instant ACK).
  @doc false
  def actor_for(account_id) when is_integer(account_id) or is_binary(account_id) do
    case safe_account_id(account_id) do
      nil ->
        nil

      id ->
        case Repo.get(Account, id) do
          nil ->
            nil

          %Account{username: u} ->
            domain = SukhiDelivery.Config.domain!()
            %{actor_uri: "https://#{domain}/users/#{u}", username: u}
        end
    end
  end

  defp safe_account_id(id) when is_integer(id), do: id

  defp safe_account_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc false
  def follower_uri_to_account(follower_uri) when is_binary(follower_uri) do
    domain = SukhiDelivery.Config.domain!()
    expected_prefix = "https://#{domain}/users/"

    if String.starts_with?(follower_uri, expected_prefix) do
      username = String.replace_prefix(follower_uri, expected_prefix, "")

      case SukhiDelivery.Accounts.by_local_username(username) do
        nil -> nil
        _ -> %{actor_uri: follower_uri, username: username}
      end
    else
      # Remote actor following us — they'd never be the source of an outbound activity.
      nil
    end
  end

  @doc false
  def followers_inboxes(actor_uri) do
    domain = SukhiDelivery.Config.domain!()
    expected_prefix = "https://#{domain}/users/"

    if String.starts_with?(actor_uri, expected_prefix) do
      username = String.replace_prefix(actor_uri, expected_prefix, "")

      case SukhiDelivery.Accounts.by_local_username(username) do
        nil ->
          []

        %Account{id: id} ->
          from(f in Follow,
            where: f.followee_id == ^id and f.state == "accepted",
            select: f.follower_uri
          )
          |> Repo.all()
          |> Enum.map(&inbox_for_actor_uri/1)
          |> Enum.reject(&is_nil/1)
      end
    else
      []
    end
  end

  @doc false
  def note_author_inbox(note_ap_id) when is_binary(note_ap_id) do
    # Convention: a note URI is `<actor_uri>/notes/<id>` or similar; the
    # author's actor URI is the parent path. This works for our own
    # notes and for Mastodon-shaped URIs. Best-effort.
    case URI.parse(note_ap_id) do
      %URI{scheme: scheme, host: host, path: path}
      when is_binary(scheme) and is_binary(host) and is_binary(path) ->
        # Strip the trailing `/notes/<id>` or `/statuses/<id>`
        actor_path =
          path
          |> String.split("/")
          |> Enum.reverse()
          |> Enum.drop(2)
          |> Enum.reverse()
          |> Enum.join("/")

        if actor_path == "" do
          []
        else
          ["#{scheme}://#{host}#{actor_path}/inbox"]
        end

      _ ->
        []
    end
  end

  def note_author_inbox(_), do: []

  # The author's actor URI for a note URI (`<actor_uri>/notes/<id>`), used to
  # address a poll-vote ballot `to` the Question's author. Same convention as
  # note_author_inbox/1, minus the `/inbox` suffix. Returns [] when unparseable
  # so the ballot is still built (best-effort addressing).
  @doc false
  def note_author_uri(note_ap_id) when is_binary(note_ap_id) do
    case URI.parse(note_ap_id) do
      %URI{scheme: scheme, host: host, path: path}
      when is_binary(scheme) and is_binary(host) and is_binary(path) ->
        actor_path =
          path
          |> String.split("/")
          |> Enum.reverse()
          |> Enum.drop(2)
          |> Enum.reverse()
          |> Enum.join("/")

        if actor_path == "", do: [], else: ["#{scheme}://#{host}#{actor_path}"]

      _ ->
        []
    end
  end

  @doc false
  def inbox_for_actor_uri(actor_uri) when is_binary(actor_uri) do
    if local_actor?(actor_uri) do
      # Local actor: skip the network hop, use convention.
      "#{actor_uri}/inbox"
    else
      # Remote actor: prefer sharedInbox / actor.inbox from the actor JSON.
      SukhiDelivery.Federation.ActorFetcher.inbox_for(actor_uri)
    end
  end

  def inbox_for_actor_uri(_), do: nil

  # Exact host match, not a substring — `our.domain.evil.com` and
  # `evil.com/our.domain/...` must NOT count as local.
  defp local_actor?(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) ->
        String.downcase(host) == String.downcase(SukhiDelivery.Config.domain!())

      _ ->
        false
    end
  end

  # Local accounts (domain IS NULL) use the convention; remote shadow
  # accounts carry the actual `actor_uri` + `inbox_url` (or
  # `shared_inbox_url`) from the actor JSON.
  @doc false
  def followee_endpoints(%Account{domain: nil, username: u}) do
    domain = SukhiDelivery.Config.domain!()
    uri = "https://#{domain}/users/#{u}"
    {uri, "#{uri}/inbox"}
  end

  def followee_endpoints(%Account{actor_uri: uri} = a) when is_binary(uri) do
    inbox = a.shared_inbox_url || a.inbox_url || "#{uri}/inbox"
    {uri, inbox}
  end

  @doc false
  def relay_inboxes, do: Relays.get_active_inbox_urls()

  @doc false
  def note_ap_id(actor_uri, note_id) when is_binary(actor_uri) and not is_nil(note_id) do
    "#{actor_uri}/notes/#{note_id}"
  end

  def note_ap_id(_, _), do: nil
end
