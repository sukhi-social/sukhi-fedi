# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.PeerCapabilities do
  @moduledoc """
  What each remote *host* implements, learned from the `generator` of the
  actor documents we fetch (FEP-844e, parsed by `SukhiShared.Capability`).

  A capability is per host, not per actor: Pull Federation is a property of
  the server software, and the notification and pull endpoints live at the
  host. The newest actor document from a host wins, so a host that turns the
  capability off stops being treated as capable as soon as we see one of its
  actors again, and a host we have not heard from for `fresh_days/0` is
  treated as not capable (we then push, which every server understands).

  `capable_hosts/3` is the single predicate the rest of the system asks
  ("may I send this host pull-federation traffic?"). The gateway writes
  (`learn/3`); the delivery node reads. Both go through the `repo` they are
  given, so this module carries no Ecto dependency of its own.
  """

  alias SukhiShared.Capability

  @fresh_days 14

  @doc "How long a sighting counts."
  @spec fresh_days() :: pos_integer()
  def fresh_days, do: @fresh_days

  @doc """
  Record what the actor document `actor_json` says about its host. Returns
  `:ok` whether or not a row changed; a document with no usable `id` is
  ignored. Writes only when the declared set changed or the sighting is more
  than an hour old, so ingesting a busy host does not become a write per
  activity.
  """
  @spec learn(module(), map(), DateTime.t()) :: :ok
  def learn(repo, actor_json, now \\ DateTime.utc_now())

  def learn(repo, %{"id" => id} = actor_json, now) when is_binary(id) do
    case host_of(id) do
      nil ->
        :ok

      host ->
        {notify, stream} = Capability.pull_endpoints(actor_json) || {nil, nil}

        repo.query!(
          """
          INSERT INTO peer_capabilities (host, hrefs, seen_at, pull_notify, pull_stream)
          VALUES ($1, $2, $3, $4, $5)
          ON CONFLICT (host) DO UPDATE SET
            hrefs = EXCLUDED.hrefs, seen_at = EXCLUDED.seen_at,
            pull_notify = EXCLUDED.pull_notify, pull_stream = EXCLUDED.pull_stream
          WHERE peer_capabilities.hrefs IS DISTINCT FROM EXCLUDED.hrefs
             OR peer_capabilities.pull_notify IS DISTINCT FROM EXCLUDED.pull_notify
             OR peer_capabilities.pull_stream IS DISTINCT FROM EXCLUDED.pull_stream
             OR peer_capabilities.seen_at < EXCLUDED.seen_at - interval '1 hour'
          """,
          [host, Capability.hrefs(actor_json), DateTime.to_naive(now), notify, stream]
        )

        :ok
    end
  end

  def learn(_repo, _other, _now), do: :ok

  @doc """
  The subset of `hosts` that declared `href` (default: Pull Federation)
  within the freshness window **and** published both endpoints. A host that
  names the capability but not where to send it is not capable: we never
  guess a path. One query for the whole batch.
  """
  @spec capable_hosts(module(), [String.t()], String.t(), DateTime.t()) :: MapSet.t(String.t())
  def capable_hosts(repo, hosts, href \\ Capability.pull_federation(), now \\ DateTime.utc_now())

  def capable_hosts(_repo, [], _href, _now), do: MapSet.new()

  def capable_hosts(repo, hosts, href, now) do
    since = now |> DateTime.add(-@fresh_days * 86_400, :second) |> DateTime.to_naive()

    %{rows: rows} =
      repo.query!(
        """
        SELECT host FROM peer_capabilities
        WHERE host = ANY($1) AND $2 = ANY(hrefs) AND seen_at > $3
          AND pull_notify IS NOT NULL AND pull_stream IS NOT NULL
        """,
        [Enum.uniq(hosts), href, since]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  @doc """
  The URLs `host` published for Pull Federation, as `%{notify: url, stream:
  url}`, or `nil` when it is not (or no longer) capable. The only place a
  peer's endpoint is looked up.
  """
  @spec endpoints(module(), String.t()) :: %{notify: String.t(), stream: String.t()} | nil
  def endpoints(repo, host, now \\ DateTime.utc_now()) do
    since = now |> DateTime.add(-@fresh_days * 86_400, :second) |> DateTime.to_naive()

    case repo.query!(
           """
           SELECT pull_notify, pull_stream FROM peer_capabilities
           WHERE host = $1 AND $2 = ANY(hrefs) AND seen_at > $3
             AND pull_notify IS NOT NULL AND pull_stream IS NOT NULL
           """,
           [String.downcase(host), Capability.pull_federation(), since]
         ) do
      %{rows: [[notify, stream]]} -> %{notify: notify, stream: stream}
      _ -> nil
    end
  end

  @doc "Is this one host capable? Prefer `capable_hosts/3` for more than one."
  @spec capable?(module(), String.t()) :: boolean()
  def capable?(repo, host), do: MapSet.member?(capable_hosts(repo, [host]), host)

  @doc "Lower-cased host of a URL, or nil."
  @spec host_of(term()) :: String.t() | nil
  def host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) and h != "" -> String.downcase(h)
      _ -> nil
    end
  end

  def host_of(_), do: nil
end
