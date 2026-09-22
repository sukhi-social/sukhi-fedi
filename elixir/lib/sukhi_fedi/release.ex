# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Release do
  @moduledoc """
  Release tasks (no Mix available). Called by the container entrypoint:

      bin/sukhi_fedi eval 'SukhiFedi.Release.migrate_all()'

  Walks `priv/repo/migrations/core/` and each enabled addon's
  `migrations_path/0`, in that order.

  Before applying anything, `migrate_all/0` runs `check_migration_sanity/0`,
  which refuses to migrate against a schema this release can't reason about
  (an unapplied migration sitting *below* one already applied — an
  out-of-order history that `:up` `all: true` would silently skip over).
  `Mix.Tasks.Sukhi.Migrate` routes through `migrate_all/0`, so dev gets the
  same gate.
  """

  import Ecto.Query, only: [from: 2]

  @app :sukhi_fedi

  def migrate_all do
    load_app()

    check_migration_sanity()

    paths = migration_paths()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, paths, :up, all: true)
        end)
    end
  end

  @doc """
  Refuse to migrate against an out-of-order schema. For each repo, over the
  exact same path set `migrate_all/0` uses, ask Ecto which migrations are
  applied vs pending; if any pending (`:down`) migration sits *below* the
  highest applied (`:up`) version, raise listing the offending versions.

  Such a state means the database carries history this release can't account
  for — a migration was applied out of order, or this release is missing one
  that ran below its newest. `:up` with `all: true` would happily run the
  stragglers without complaint, leaving the schema in an order no release
  reasoned about. Better to stop, loudly.
  """
  def check_migration_sanity do
    load_app()

    paths = migration_paths()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          repo
          |> Ecto.Migrator.migrations(paths)
          |> migrations_out_of_order()
          |> case do
            [] ->
              :ok

            offending ->
              raise """
              #{inspect(repo)}: refusing to migrate — pending migrations sit \
              below an already-applied one. The schema's history is out of \
              order; this release can't reason about it. Offending versions: \
              #{Enum.join(offending, ", ")}.
              """
          end
        end)
    end

    :ok
  end

  # Pending (`:down`) versions that sit below the highest applied (`:up`)
  # one, given `Ecto.Migrator.migrations/2`'s `[{status, version, name}]`.
  # Empty when the history is a clean prefix of applied followed by pending.
  # Public (and DB-free) so the rule is testable in isolation; not API.
  @doc false
  def migrations_out_of_order(migrations) do
    applied = for {:up, version, _name} <- migrations, do: version
    highest_up = Enum.max(applied, fn -> nil end)

    case highest_up do
      nil ->
        []

      _ ->
        for {:down, version, _name} <- migrations, version < highest_up, do: version
    end
  end

  defp migration_paths do
    [core_path() | addon_paths()]
  end

  defp core_path do
    Application.app_dir(@app, Path.join(["priv", "repo", "migrations", "core"]))
  end

  defp addon_paths do
    SukhiFedi.Addon.Registry.migrations_paths()
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  @doc """
  Seed a per-site watcher actor for `domain`. Username is
  `watcher-<domain with dots → underscores>` (so `mastodon.social` →
  `watcher-mastodon_social`), and `monitored_domain` is populated so
  the UI can recover the original.

      bin/sukhi_fedi eval 'SukhiFedi.Release.seed_watcher("mastodon.social")'
  """
  def seed_watcher(domain) when is_binary(domain) do
    username = "watcher-" <> String.replace(domain, ".", "_")

    seed_actor(username,
      display_name: "Watcher — #{domain}",
      summary: "Monitors version changes on #{domain}. Follow for updates.",
      monitored_domain: domain
    )
  end

  @doc """
  Seed a local actor (Person) that remote servers can Follow. Idempotent:
  a second call with the same username is a no-op.

      bin/sukhi_fedi eval 'SukhiFedi.Release.seed_actor("watcher")'
  """
  def seed_actor(username, opts \\ []) when is_binary(username) do
    load_app()

    display_name = Keyword.get(opts, :display_name, username)
    summary = Keyword.get(opts, :summary, "")
    monitored_domain = Keyword.get(opts, :monitored_domain)

    do_seed = fn ->
      case SukhiFedi.Repo.get_by(SukhiFedi.Schema.Account, username: username) do
        nil ->
          keys = SukhiFedi.Addons.NodeinfoMonitor.KeyGen.generate()

          %SukhiFedi.Schema.Account{}
          |> Ecto.Changeset.change(%{
            username: username,
            display_name: display_name,
            summary: summary,
            is_bot: true,
            monitored_domain: monitored_domain,
            public_key_pem: keys.public_pem,
            public_key_jwk: keys.public_jwk,
            private_key_jwk: keys.private_jwk,
            ed25519_private_key_jwk: keys.ed25519_private_jwk,
            ed25519_public_multibase: keys.ed25519_public_multibase
          })
          |> SukhiFedi.Repo.insert!()

          :created

        _existing ->
          :already_exists
      end
    end

    if Process.whereis(SukhiFedi.Repo) do
      # Running inside the live app (web request or rpc) — Repo is up.
      {:ok, do_seed.()}
    else
      # Invoked via `eval` as a one-shot — start the Repo for this call.
      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> do_seed.() end)

      {:ok, result}
    end
  end

  @doc """
  Bootstrap the first admin account. Creates a local account with
  `is_admin: true`, bypassing the invite-code requirement that normal
  signup enforces.

      bin/sukhi_fedi eval 'SukhiFedi.Release.create_admin("nyanrus", "a-long-passphrase")'

  Optional third arg is a keyword list (`display_name:`, `email:`).
  Once you have one admin, promote others from the back-office UI
  instead of running this again. The password floor is 8 bytes; change
  it later at `/settings/password`.
  """
  def create_admin(username, password, opts \\ [])
      when is_binary(username) and is_binary(password) do
    load_app()

    do_create = fn -> SukhiFedi.LocalAccounts.create_admin(username, password, opts) end

    if Process.whereis(SukhiFedi.Repo) do
      do_create.()
    else
      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> do_create.() end)

      result
    end
  end

  @doc """
  One-shot: for every `MonitoredInstance` that already has at least one
  snapshot, publish an "監視を始めました" Note using the latest snapshot.
  Use after `backfill_monitored_instances/0` on a deployment where the
  initial polls already ran through PollWorker's old :initial branch
  (pre-v0.1.22), which recorded snapshots but did not publish.

      bin/sukhi_fedi eval 'SukhiFedi.Release.publish_initial_notes_for_backfill()'
  """
  def publish_initial_notes_for_backfill do
    load_app()

    do_publish = fn ->
      alias SukhiFedi.Repo
      alias SukhiFedi.Addons.NodeinfoMonitor
      alias SukhiFedi.Schema.{MonitoredInstance, NodeinfoSnapshot}

      per_instance =
        from(m in MonitoredInstance, order_by: [asc: m.domain])
        |> Repo.all()
        |> Enum.map(fn mi ->
          snap =
            from(s in NodeinfoSnapshot,
              where: s.monitored_instance_id == ^mi.id,
              order_by: [desc: s.polled_at],
              limit: 1
            )
            |> Repo.one()

          if snap do
            NodeinfoMonitor.publish_initial_note(
              mi,
              %{software_name: snap.software_name, version: snap.version},
              summary?: false
            )
            |> case do
              {:ok, _note} -> {mi.domain, :ok}
              other -> {mi.domain, other}
            end
          else
            {mi.domain, :no_snapshot}
          end
        end)

      # Fire the @watcher aggregate exactly once after all per-instance
      # posts land, instead of N times from inside the loop.
      NodeinfoMonitor.publish_summary_to_default_watcher()

      per_instance
    end

    result =
      if Process.whereis(SukhiFedi.Repo) do
        do_publish.()
      else
        {:ok, r, _apps} = Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> do_publish.() end)
        r
      end

    IO.inspect(result, label: :publish_initial_notes_for_backfill)
    {:ok, result}
  end

  @doc """
  One-shot: delete every Note owned by the default `@watcher` account
  (aggregate summaries) via the standard Notes.delete_note path, so
  each removal fans out as a Delete(Note). Pair with
  `NodeinfoMonitor.publish_summary_to_default_watcher/0` to re-seed
  a single fresh summary.

      bin/sukhi_fedi eval 'SukhiFedi.Release.resync_default_watcher_summary()'
  """
  def resync_default_watcher_summary do
    load_app()

    do_resync = fn ->
      alias SukhiFedi.{Repo, Notes}
      alias SukhiFedi.Addons.NodeinfoMonitor
      alias SukhiFedi.Schema.{Account, Note}

      case SukhiFedi.Accounts.by_local_username("watcher") do
        nil ->
          :no_default_watcher

        %Account{id: account_id} ->
          deleted =
            from(n in Note, where: n.account_id == ^account_id, select: n.id)
            |> Repo.all()
            |> Enum.map(fn note_id ->
              {note_id, Notes.delete_note(account_id, note_id) |> elem(0)}
            end)

          {:deleted, deleted, NodeinfoMonitor.publish_summary_to_default_watcher()}
      end
    end

    result =
      if Process.whereis(SukhiFedi.Repo) do
        do_resync.()
      else
        {:ok, r, _apps} = Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> do_resync.() end)
        r
      end

    IO.inspect(result, label: :resync_default_watcher_summary)
    {:ok, result}
  end

  @doc """
  One-shot: delete every Note owned by a watcher bot via the standard
  Notes.delete_note path, so each removal fans out as a proper
  Delete(Note) to federation instead of vanishing silently. Useful
  when republishing watcher notes after a Bun translator fix — the
  old ghost copies on remote timelines need a Delete to clear first.

      bin/sukhi_fedi eval 'SukhiFedi.Release.delete_all_watcher_notes()'
  """
  def delete_all_watcher_notes do
    load_app()

    do_delete = fn ->
      alias SukhiFedi.{Repo, Notes}
      alias SukhiFedi.Schema.{Account, Note}

      Repo.all(
        from(n in Note,
          join: a in Account,
          on: a.id == n.account_id,
          where: not is_nil(a.monitored_domain),
          select: {a.id, n.id}
        )
      )
      |> Enum.map(fn {account_id, note_id} ->
        Notes.delete_note(account_id, note_id) |> elem(0) |> then(&{note_id, &1})
      end)
    end

    result =
      if Process.whereis(SukhiFedi.Repo) do
        do_delete.()
      else
        {:ok, r, _apps} = Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> do_delete.() end)
        r
      end

    IO.inspect(result, label: :delete_all_watcher_notes)
    {:ok, result}
  end

  @doc """
  One-shot: fire `Update {Person}` to every known follower's inbox
  (+ relays) for a local account, without changing any profile field.
  Use to nudge a remote server with a stale cached actor — they refresh
  the cached publicKey and HTTP-sig verification recovers.

      bin/sukhi_fedi eval 'SukhiFedi.Release.broadcast_actor_update("nyanrus")'
  """
  def broadcast_actor_update(username) when is_binary(username) do
    load_app()

    do_broadcast = fn -> SukhiFedi.Accounts.broadcast_actor_update(username) end

    result =
      if Process.whereis(SukhiFedi.Repo) do
        do_broadcast.()
      else
        {:ok, r, _apps} =
          Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> do_broadcast.() end)

        r
      end

    IO.inspect(result, label: :broadcast_actor_update)
    result
  end

  @doc """
  One-shot: insert a `monitored_instances` row for every existing
  watcher `Account` that doesn't have one yet. Safe to run multiple
  times (no-op on conflict).

      bin/sukhi_fedi eval 'SukhiFedi.Release.backfill_monitored_instances()'
  """
  def backfill_monitored_instances do
    load_app()

    do_backfill = fn ->
      alias SukhiFedi.Repo
      alias SukhiFedi.Schema.{Account, MonitoredInstance}

      from(a in Account, where: not is_nil(a.monitored_domain))
      |> Repo.all()
      |> Enum.map(fn a ->
        %MonitoredInstance{}
        |> MonitoredInstance.changeset(%{domain: a.monitored_domain, actor_id: a.id})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :domain)
      end)
    end

    if Process.whereis(SukhiFedi.Repo) do
      {:ok, do_backfill.()}
    else
      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> do_backfill.() end)

      {:ok, result}
    end
  end

  @doc """
  One-shot: enqueue an outbox backfill for every accepted remote follow.

  The backfill normally runs when a new follow is accepted
  (`AP.Instructions.maybe_handle_follow_accept/1`), and a restart already
  re-pends the untouched ones on its own (`Federation.OutboxBackfill.
  pending_existing/0`). This is the manual version for when you don't want
  to wait for a restart.

  Rows are inserted straight into `oban_jobs` (not via `Oban.insert/2`), so
  this runs from a plain `eval` with only the Repo started — the running
  gateway's `:backfill` queue picks them up. Running it twice is harmless:
  the mirror is idempotent on `ap_id`, so duplicate jobs just re-read the
  same outbox.

      bin/combined eval 'SukhiFedi.Release.backfill_followed_outboxes()'
  """
  def backfill_followed_outboxes do
    load_app()

    do_backfill = fn ->
      alias SukhiFedi.Repo
      alias SukhiFedi.Schema.{Account, Follow}

      from(f in Follow,
        join: a in Account,
        on: a.id == f.followee_id,
        where: f.state == "accepted" and not is_nil(a.domain) and not is_nil(a.actor_uri),
        distinct: a.id,
        select: a.actor_uri
      )
      |> Repo.all()
      |> Enum.map(fn actor_uri ->
        SukhiFedi.Federation.OutboxBackfill.mark_pending(actor_uri)

        %{"actor_uri" => actor_uri}
        |> SukhiFedi.Federation.OutboxBackfill.new()
        |> Repo.insert()
      end)
    end

    if Process.whereis(SukhiFedi.Repo) do
      {:ok, do_backfill.()}
    else
      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> do_backfill.() end)

      {:ok, result}
    end
  end
end
