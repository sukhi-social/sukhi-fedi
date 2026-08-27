# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.NodeinfoMonitor do
  @moduledoc """
  NodeInfo monitor addon — polls registered fediverse domains and posts
  a Note from a bot actor on version changes.

  One monitored domain = one local bot `Account` (`is_bot=true`) plus
  one `MonitoredInstance` row. Polling runs under Oban cron (see
  `elixir/config/config.exs`); version changes flow through the
  standard Outbox → Delivery pipeline (gateway writes a notes row +
  outbox event; the delivery node's `Outbox.Relay` picks it up and its
  dispatch job fans out).
  """

  use SukhiFedi.Addon, id: :nodeinfo_monitor

  import Ecto.Query
  require Logger

  alias SukhiFedi.{Repo, Notes}
  alias SukhiFedi.Schema.{Account, MonitoredInstance, NodeinfoSnapshot}
  alias SukhiFedi.Addons.NodeinfoMonitor.KeyGen

  @doc """
  Register a domain to monitor. Upserts the bot Account and ensures a
  MonitoredInstance row. Idempotent: re-calling with the same domain
  returns the existing pair instead of raising on the unique index.
  """
  def register(domain) when is_binary(domain) do
    cleaned = domain |> String.trim() |> String.downcase()

    if valid_domain?(cleaned) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:account, fn repo, _ -> upsert_watcher_account(repo, cleaned) end)
      |> Ecto.Multi.run(:monitored_instance, fn repo, %{account: a} ->
        upsert_monitored_instance(repo, cleaned, a.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{monitored_instance: mi, account: a}} -> {:ok, mi, a}
        {:error, _step, reason, _} -> {:error, reason}
      end
    else
      {:error, :invalid_domain}
    end
  end

  @doc """
  Register + record the first snapshot in one go. Used by the public
  `POST /api/watchers` endpoint, which has already fetched the
  snapshot. Publishes an "監視を始めました" Note when record_snapshot
  returns `:initial` (i.e. no prior snapshot).
  """
  def register_and_record(domain, snap, opts \\ []) do
    with {:ok, mi, account} <- register(domain),
         {:ok, change} <- record_snapshot(mi, snap) do
      if change == :initial, do: publish_initial_note(mi, snap, opts)
      {:ok, mi, account}
    end
  end

  defp upsert_watcher_account(repo, domain) do
    case repo.get_by(Account, monitored_domain: domain) do
      %Account{} = existing ->
        {:ok, existing}

      nil ->
        keys = KeyGen.generate()

        %Account{
          username: username_for(domain),
          display_name: domain,
          summary: "NodeInfo monitor bot for #{domain}",
          public_key_jwk: keys.public_jwk,
          private_key_jwk: keys.private_jwk,
          public_key_pem: keys.public_pem,
          ed25519_private_key_jwk: keys.ed25519_private_jwk,
          ed25519_public_multibase: keys.ed25519_public_multibase,
          is_bot: true,
          monitored_domain: domain
        }
        |> repo.insert()
    end
  end

  defp upsert_monitored_instance(repo, domain, actor_id) do
    case repo.get_by(MonitoredInstance, domain: domain) do
      %MonitoredInstance{} = existing ->
        {:ok, existing}

      nil ->
        %MonitoredInstance{}
        |> MonitoredInstance.changeset(%{domain: domain, actor_id: actor_id})
        |> repo.insert()
    end
  end

  def list do
    Repo.all(from(m in MonitoredInstance, order_by: [asc: m.domain]))
  end

  def get(id), do: Repo.get(MonitoredInstance, id)

  def list_active_due(max_age_seconds) do
    threshold = DateTime.add(DateTime.utc_now(), -max_age_seconds, :second)

    from(m in MonitoredInstance,
      where: m.inactive == false,
      where: is_nil(m.last_polled_at) or m.last_polled_at < ^threshold,
      select: m
    )
    |> Repo.all()
  end

  def deactivate(id) do
    case Repo.get(MonitoredInstance, id) do
      nil -> {:error, :not_found}
      mi -> mi |> Ecto.Changeset.change(%{inactive: true}) |> Repo.update()
    end
  end

  def record_snapshot(%MonitoredInstance{} = mi, snapshot) do
    now = DateTime.utc_now()

    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :snapshot,
      NodeinfoSnapshot.changeset(%NodeinfoSnapshot{}, %{
        monitored_instance_id: mi.id,
        polled_at: now,
        version: snapshot[:version],
        software_name: snapshot[:software_name],
        raw: snapshot[:raw]
      })
    )
    |> Ecto.Multi.update(
      :instance,
      Ecto.Changeset.change(mi, %{
        last_polled_at: now,
        last_version: snapshot[:version],
        software_name: snapshot[:software_name],
        consecutive_failures: 0
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, detect_change(mi.last_version, snapshot[:version])}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def detect_change(nil, _new), do: :initial
  def detect_change(old, new) when old == new, do: :unchanged
  def detect_change(old, new), do: {:changed, old, new}

  @inactive_after_days 7

  @doc """
  Bump consecutive failure count. Mark inactive when the instance has
  been failing *and* the last successful poll is older than
  `@inactive_after_days`. Period-based instead of count-based so the
  cron cadence can be tuned without changing the week-of-grace semantic.
  """
  def record_failure(%MonitoredInstance{} = mi) do
    fails = (mi.consecutive_failures || 0) + 1
    updated = %MonitoredInstance{mi | consecutive_failures: fails}

    mi
    |> Ecto.Changeset.change(%{consecutive_failures: fails, inactive: stale?(updated)})
    |> Repo.update()
  end

  defp stale?(%MonitoredInstance{consecutive_failures: fails}) when fails <= 0, do: false
  defp stale?(%MonitoredInstance{last_polled_at: nil}), do: false

  defp stale?(%MonitoredInstance{last_polled_at: last}) do
    threshold = DateTime.add(DateTime.utc_now(), -@inactive_after_days, :day)
    DateTime.before?(last, threshold)
  end

  def publish_change_note(%MonitoredInstance{} = mi, old_version, new_version) do
    content = format_note(mi, old_version, new_version)

    result =
      Notes.create_note(%{
        "account_id" => mi.actor_id,
        "content" => content,
        "visibility" => "public"
      })

    publish_summary_to_default_watcher()
    result
  end

  def publish_initial_note(%MonitoredInstance{} = mi, snap, opts \\ []) do
    sw = snap[:software_name] || snap["software_name"] || mi.software_name || "unknown"
    ver = snap[:version] || snap["version"] || mi.last_version || "?"

    content =
      "\u{1F440} Now monitoring #{mi.domain}\n" <>
        "software: #{sw}\n" <>
        "version: #{ver}"

    result =
      Notes.create_note(%{
        "account_id" => mi.actor_id,
        "content" => content,
        "visibility" => "public"
      })

    # Callers batching many individual posts (backfill) pass
    # `summary?: false` and fire the aggregate once at the end to
    # avoid N duplicate @watcher summaries.
    if Keyword.get(opts, :summary?, true) do
      publish_summary_to_default_watcher()
    end

    result
  end

  @doc """
  Post a single Note from the `@watcher` default bot summarising the
  current status of every active MonitoredInstance. Called alongside
  the per-instance publish paths so the default bot always has a
  fresh aggregate feed.
  """
  def publish_summary_to_default_watcher do
    case SukhiFedi.Accounts.by_local_username("watcher") do
      nil ->
        Logger.debug("NodeinfoMonitor: no default @watcher account; skipping summary")
        :no_default_watcher

      %Account{} = default ->
        instances =
          from(m in MonitoredInstance,
            where: m.inactive == false,
            order_by: [asc: m.domain]
          )
          |> Repo.all()

        case instances do
          [] ->
            :no_instances

          list ->
            lines =
              Enum.map(list, fn mi ->
                "#{mi.domain}: #{mi.software_name || "?"} #{mi.last_version || "?"}"
              end)

            content =
              "\u{1F4E1} Watch status (#{length(list)} instances)\n" <>
                Enum.join(lines, "\n")

            Notes.create_note(%{
              "account_id" => default.id,
              "content" => content,
              "visibility" => "public"
            })
        end
    end
  end

  defp format_note(mi, old, new) do
    sw = mi.software_name || "unknown"

    "\u{1F514} #{mi.domain} upgraded\n" <>
      "software: #{sw}\n" <>
      "version: #{old || "?"} \u2192 #{new}"
  end

  defp valid_domain?(d) do
    byte_size(d) > 2 and byte_size(d) <= 253 and
      String.match?(d, ~r/^[a-z0-9.-]+\.[a-z]{2,}$/i)
  end

  defp username_for(domain), do: "watcher-" <> String.replace(domain, ".", "_")
end
