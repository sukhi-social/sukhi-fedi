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

  require Logger

  @app :sukhi_fedi

  def migrate_all do
    load_app()

    if SukhiFedi.Store.datalevin?() do
      # Nothing to migrate: the Datalevin schema is derived from
      # priv/datalevin/catalog.exs and installed when the store opens, and the
      # job queue creates its own SQLite tables at boot (docs/DATALEVIN.md).
      Logger.info("store_init_start store=datalevin")
      initialize_datalevin!()
      Logger.info("store_init_complete store=datalevin")
      :ok
    else
      Logger.info("migration_start store=postgres")
      migrate_postgres()
      Logger.info("migration_complete store=postgres")
      :ok
    end
  end

  @doc """
  Write a non-secret backup manifest describing the Datalevin restore unit.
  It does not copy data or credentials.
  """
  def write_datalevin_backup_manifest!(path \\ "/var/lib/sukhi/backup-manifest.json") do
    config = SukhiFedi.Datalevin.Config.current()

    data = %{
      "format" => 1,
      "store" => "datalevin",
      "data_dir" => config.dir,
      "data_dir_manifest" => SukhiFedi.Datalevin.Manifest.path(config),
      "graph_dir" => Path.join(config.dir, "graph"),
      "queue_db" => System.get_env("SUKHI_QUEUE_DB", "/var/lib/sukhi/queue.db"),
      "delivery_queue_db" =>
        System.get_env("DELIVERY_QUEUE_DB", "/var/lib/sukhi/delivery_queue.db"),
      "raw_backend" => System.get_env("SUKHI_RAW_BACKEND", "sqlite"),
      "raw_bucket" => System.get_env("SUKHI_RAW_BUCKET") || System.get_env("S3_BUCKET"),
      "instance_config" => SukhiShared.InstanceConfig.path(),
      "catalog_sha256" => expected_catalog_sha256()
    }

    :ok = File.write!(path, JSON.encode!(data) <> "\n")
    Logger.info("datalevin_backup_manifest_written path=#{path}")
    :ok
  end

  @doc "Validate a restored Datalevin backup inventory before normal startup."
  def check_datalevin_backup_manifest!(path \\ "/var/lib/sukhi/backup-manifest.json") do
    :ok =
      SukhiFedi.Datalevin.Manifest.validate_backup!(
        path,
        SukhiFedi.Datalevin.Config.current()
      )

    :ok
  end

  @doc """
  Verify the external services needed before the HTTP endpoint is opened.

  Postgres is verified by `migrate_all/0`; Datalevin is opened above. NATS
  still needs an explicit protocol check because its supervisor retries
  asynchronously during a normal application boot.
  """
  def check_runtime_connections! do
    config = SukhiShared.InstanceConfig.load()

    Logger.info(
      "instance_config_resolved path=#{SukhiShared.InstanceConfig.path()} " <>
        "site_name=#{Map.fetch!(config, "site_name")} " <>
        "declared_frontends=#{map_size(Map.fetch!(config, "frontends"))} " <>
        "external_frontends=#{map_size(SukhiShared.InstanceConfig.frontends(config))} " <>
        "active_frontends=#{map_size(SukhiShared.InstanceConfig.active_frontends(config))} " <>
        "routes=#{length(SukhiShared.InstanceConfig.routes(config) || [])}"
    )

    Logger.info("runtime_connection_check_start service=nats")
    check_nats!()
    Logger.info("runtime_connection_check_complete service=nats")
    :ok
  end

  defp migrate_postgres do
    check_migration_sanity()

    paths = migration_paths()

    for repo <- repos() do
      Logger.info("migration_start repo=#{inspect(repo)}")

      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, paths, :up, all: true)
        end)

      Logger.info("migration_complete repo=#{inspect(repo)}")
    end
  rescue
    error ->
      host = System.get_env("DB_HOST", "localhost")
      port = System.get_env("DB_PORT", "5432")

      raise "postgres migration failed endpoint=#{host}:#{port}; check " <>
              "`podman logs <postgres-container>` and `nc -vz #{host} #{port}` " <>
              "as the sukhi user; startup stopped and existing data was not changed: " <>
              Exception.message(error)
  end

  defp initialize_datalevin! do
    config = SukhiFedi.Datalevin.Config.current()
    manifest_status = SukhiFedi.Datalevin.Manifest.verify!(config)
    {:ok, supervisor} = SukhiFedi.Datalevin.Supervisor.start_link([])
    true = Process.alive?(supervisor)
    Supervisor.stop(supervisor)
    if manifest_status == :legacy, do: SukhiFedi.Datalevin.Manifest.write!(config)
    Logger.info("datalevin_init_complete")
  rescue
    error ->
      raise "datalevin initialization failed; inspect DATALEVIN_DIR and run " <>
              "`podman logs <container>` as the sukhi user; startup stopped and " <>
              "existing data was not changed: #{Exception.message(error)}"
  end

  defp expected_catalog_sha256 do
    SukhiFedi.Datalevin.Catalog.dtlv_schema()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp check_nats! do
    config = Application.get_env(:sukhi_fedi, :nats, [])
    host = Keyword.fetch!(config, :host)
    port = Keyword.fetch!(config, :port)
    address = "#{host}:#{port}"

    with {:ok, socket} <-
           :gen_tcp.connect(to_charlist(host), port, [:binary, active: false], 2_000),
         :ok <- :gen_tcp.send(socket, "PING\r\n"),
         {:ok, _response} <- recv_nats_pong(socket, <<>>, 3),
         :ok <- :gen_tcp.close(socket) do
      Logger.info("startup_connection_ok service=nats endpoint=#{address}")
      :ok
    else
      {:error, reason} ->
        raise "nats connection failed endpoint=#{address}; check `podman logs <nats-container>` " <>
                "and `nc -vz #{host} #{port}` as the sukhi user; startup stopped and " <>
                "existing data was not changed: #{inspect(reason)}"

      other ->
        raise "nats connection failed endpoint=#{address}; check `podman logs <nats-container>` " <>
                "and `nc -vz #{host} #{port}`: #{inspect(other)}"
    end
  end

  defp recv_nats_pong(socket, buffer, attempts) when attempts > 0 do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        buffer = buffer <> data

        if String.contains?(buffer, "PONG"),
          do: {:ok, buffer},
          else: recv_nats_pong(socket, buffer, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_nats_pong(_socket, _buffer, 0), do: {:error, :no_pong}

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

    if SukhiFedi.Store.datalevin?(), do: :ok, else: check_postgres_sanity()
  end

  defp check_postgres_sanity do
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
      case SukhiFedi.Accounts.by_local_username(username) do
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
  Run a one-shot maintenance script from `priv/scripts/<name>.exs` against
  the live database, with the Repo started for the call if it isn't already.
  `args` is bound inside the script as `args`; the script's last value is
  printed and returned as `{:ok, value}`.

      bin/sukhi_fedi eval 'SukhiFedi.Release.run_script("backfill_followed_outboxes")'
      bin/sukhi_fedi eval 'SukhiFedi.Release.run_script("broadcast_actor_update", ["nyanrus"])'

  The scripts are the old one-shot `Release` functions (pre-v0.1.22 data
  fixes, manual backfills); they live as files so the module that runs on
  every boot doesn't carry them.
  """
  def run_script(name, args \\ []) when is_binary(name) and is_list(args) do
    load_app()

    unless name =~ ~r/\A[a-z][a-z0-9_]*\z/ do
      raise ArgumentError, "bad script name: #{inspect(name)}"
    end

    path = Application.app_dir(@app, Path.join(["priv", "scripts", name <> ".exs"]))

    unless File.regular?(path) do
      raise ArgumentError,
            "no such script #{inspect(name)} (looked for #{path}); " <>
              "available: #{Enum.join(scripts(), ", ")}"
    end

    source = File.read!(path)
    run = fn -> source |> Code.eval_string([args: args], file: path) |> elem(0) end

    result =
      if Process.whereis(SukhiFedi.Repo) do
        run.()
      else
        {:ok, r, _apps} = Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo -> run.() end)
        r
      end

    IO.inspect(result, label: name)
    {:ok, result}
  end

  @doc "Names `run_script/2` accepts (the files in `priv/scripts/`)."
  def scripts do
    Application.app_dir(@app, Path.join(["priv", "scripts"]))
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".exs"))
    |> Enum.sort()
  end
end
