# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.NodeinfoMonitor.PollWorker do
  @moduledoc """
  Polls one `MonitoredInstance`:

    1. fetch NodeInfo
    2. persist a snapshot + update last-polled state
    3. if the version changed, publish a Note from the bot actor
       (Outbox → delivery node's Relay → dispatch job → fan out)
    4. on failure: bump consecutive_failures; when the last successful
       poll is older than 7 days *and* failures are still accruing, the
       instance is flipped to `inactive` and stops being polled.
  """

  use Oban.Worker, queue: :monitor, max_attempts: 3

  require Logger

  alias SukhiFedi.Addons.NodeinfoMonitor
  alias SukhiFedi.Addons.NodeinfoMonitor.NodeinfoFetcher

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => id}}) do
    case NodeinfoMonitor.get(id) do
      nil ->
        Logger.debug("PollWorker: instance #{id} gone, skipping")
        :ok

      %{inactive: true} ->
        :ok

      mi ->
        poll(mi)
    end
  end

  defp poll(mi) do
    case NodeinfoFetcher.fetch(mi.domain) do
      {:ok, snapshot} ->
        handle_snapshot(mi, snapshot)

      {:error, reason} ->
        Logger.info("PollWorker: #{mi.domain} fetch failed: #{inspect(reason)}")
        NodeinfoMonitor.record_failure(mi)
        :ok
    end
  end

  defp handle_snapshot(mi, snapshot) do
    case NodeinfoMonitor.record_snapshot(mi, snapshot) do
      {:ok, :initial} ->
        Logger.info("PollWorker: #{mi.domain} initial snapshot v#{snapshot[:version]}")

        case NodeinfoMonitor.publish_initial_note(mi, snapshot) do
          {:ok, _note} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, :unchanged} ->
        :ok

      {:ok, {:changed, old, new}} ->
        Logger.info("PollWorker: #{mi.domain} upgraded #{old} -> #{new}")

        case NodeinfoMonitor.publish_change_note(mi, old, new) do
          {:ok, _note} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
