# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.PullFederation.Route do
  @moduledoc """
  Which follower inboxes get an activity pushed, and which hosts are told to
  pull it instead. This is the one place that decision is made (CODE_STYLE
  §3); `Outbox.Consumer` asks and does not look at capabilities itself.

  A host is pulled from only when **all** of these hold:

    * we run Pull Federation ourselves (`SukhiShared.Capability.advertised?/0`);
    * the host declared the capability (FEP-844e, `SukhiShared.PeerCapabilities`)
      within the freshness window;
    * its notifications have not tripped the breaker — `trip/0` consecutive
      failures push the host back to plain delivery, and after `half_open_ms/0`
      one notification is tried again.

  Everything else is pushed exactly as before, so a server that has never
  heard of Pull Federation sees no difference.
  """

  import Ecto.Query

  alias SukhiDelivery.Repo
  alias SukhiShared.{Capability, PeerCapabilities}

  @trip 5
  @half_open_ms :timer.minutes(30)

  @doc "Consecutive notification failures after which a host goes back to push."
  def trip, do: @trip

  @doc "How long a tripped host stays on push before one notification is tried."
  def half_open_ms, do: @half_open_ms

  @doc """
  Split `inboxes` into `{push_inboxes, pull_hosts}`. One query per call
  (capabilities for the whole batch) plus one for the breaker.
  """
  @spec split([String.t()], DateTime.t()) :: {[String.t()], [String.t()]}
  def split(inboxes, now \\ DateTime.utc_now()) do
    if Capability.advertised?() do
      by_host = Enum.group_by(inboxes, &PeerCapabilities.host_of/1)
      hosts = by_host |> Map.keys() |> Enum.reject(&is_nil/1)

      pull = pull_hosts(hosts, now)

      push =
        by_host
        |> Enum.reject(fn {host, _} -> host in pull end)
        |> Enum.flat_map(fn {_, urls} -> urls end)

      {push, MapSet.to_list(pull)}
    else
      {inboxes, []}
    end
  end

  @doc "Of `hosts`, those we should notify rather than push to."
  @spec pull_hosts([String.t()], DateTime.t()) :: MapSet.t(String.t())
  def pull_hosts(hosts, now \\ DateTime.utc_now()) do
    capable = PeerCapabilities.capable_hosts(Repo, hosts, Capability.pull_federation(), now)
    MapSet.difference(capable, tripped(MapSet.to_list(capable), now))
  end

  defp tripped([], _now), do: MapSet.new()

  defp tripped(hosts, now) do
    since = DateTime.add(now, -@half_open_ms, :millisecond)

    from(p in "pull_peers",
      where: p.host in ^hosts and p.failures >= ^@trip and p.notified_at > ^since,
      select: p.host
    )
    |> Repo.all()
    |> MapSet.new()
  end
end
