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
  given, and the queries are plain Ecto ones, so they run on whatever store
  that repo is.
  """

  import Ecto.Query, only: [from: 2]

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

        remember(repo, host, Capability.hrefs(actor_json), DateTime.to_naive(now), notify, stream)

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

    from(p in "peer_capabilities",
      where:
        p.host in ^Enum.uniq(hosts) and p.seen_at > type(^since, :naive_datetime) and
          not is_nil(p.pull_notify) and not is_nil(p.pull_stream),
      select: {p.host, type(p.hrefs, {:array, :string})}
    )
    |> repo.all()
    |> Enum.filter(fn {_host, hrefs} -> href in hrefs end)
    |> MapSet.new(&elem(&1, 0))
  end

  # A changed row, or none yet: the first sighting inserts, later ones write
  # only when what the host declared changed or the sighting is over an hour
  # old. Read, then one write, so the same code runs on any store.
  defp remember(repo, host, hrefs, seen_at, notify, stream) do
    current =
      from(p in "peer_capabilities",
        where: p.host == ^host,
        select: {type(p.hrefs, {:array, :string}), type(p.seen_at, :naive_datetime), p.pull_notify, p.pull_stream}
      )
      |> repo.one()

    row = %{host: host, hrefs: hrefs, seen_at: seen_at, pull_notify: notify, pull_stream: stream}

    case current do
      nil ->
        repo.insert_all("peer_capabilities", [row], on_conflict: :nothing, conflict_target: [:host])

      {^hrefs, old_seen, ^notify, ^stream} ->
        if NaiveDateTime.diff(seen_at, old_seen) > 3600, do: update(repo, row)

      _ ->
        update(repo, row)
    end
  end

  defp update(repo, row) do
    from(p in "peer_capabilities",
      where: p.host == ^row.host,
      update: [
        set: [
          hrefs: ^row.hrefs,
          seen_at: type(^row.seen_at, :naive_datetime),
          pull_notify: ^row.pull_notify,
          pull_stream: ^row.pull_stream
        ]
      ]
    )
    |> repo.update_all([])
  end

  @doc """
  The URLs `host` published for Pull Federation, as `%{notify: url, stream:
  url}`, or `nil` when it is not (or no longer) capable. The only place a
  peer's endpoint is looked up.
  """
  @spec endpoints(module(), String.t()) :: %{notify: String.t(), stream: String.t()} | nil
  def endpoints(repo, host, now \\ DateTime.utc_now()) do
    since = now |> DateTime.add(-@fresh_days * 86_400, :second) |> DateTime.to_naive()

    host = String.downcase(host)
    href = Capability.pull_federation()

    from(p in "peer_capabilities",
      where:
        p.host == ^host and p.seen_at > type(^since, :naive_datetime) and
          not is_nil(p.pull_notify) and not is_nil(p.pull_stream),
      select: {p.pull_notify, p.pull_stream, type(p.hrefs, {:array, :string})}
    )
    |> repo.one()
    |> case do
      {notify, stream, hrefs} -> if href in hrefs, do: %{notify: notify, stream: stream}
      nil -> nil
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
