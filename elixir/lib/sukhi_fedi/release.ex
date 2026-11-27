# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Release do
  @moduledoc """
  Release tasks (no Mix available). Called by the container entrypoint:

      bin/sukhi_fedi eval 'SukhiFedi.Release.migrate_all()'

  The store (hosigraph) derives its schema from the Ecto schemas when it opens, so
  `migrate_all/0` has nothing to run; `Mix.Tasks.Sukhi.Migrate` routes through it.

  PostgreSQL holds the accounts' tables (`SukhiFedi.AccountRepo`) and the job
  queues; both are brought up to date when the application boots
  (`SukhiFedi.AccountRepo.Migrate`, `SukhiFedi.Queue.Migrate`), not here.
  """

  require Logger

  @app :sukhi_fedi

  def migrate_all do
    load_app()

    # hosigraph derives its schema from the Ecto schemas when the Repo opens
    # (SukhiFedi.Store.Hosi.schemas/0): there is nothing to migrate. Data kept
    # by the old Datalevin store is not carried over (docs/STORE.md).
    Logger.info("store_init_complete store=hosi")
    :ok
  end

  @doc """
  Write a non-secret backup manifest describing the restore unit.
  It does not copy data or credentials.
  """
  def write_backup_manifest!(path \\ "/var/lib/sukhi/backup-manifest.json") do
    config = SukhiFedi.Store.Config.current()

    data = %{
      "format" => 1,
      "store" => "hosi",
      "data_dir" => config.dir,
      "data_dir_manifest" => SukhiFedi.Store.Manifest.path(config),
      "raw_backend" => System.get_env("SUKHI_RAW_BACKEND", "postgres"),
      "raw_bucket" => System.get_env("SUKHI_RAW_BUCKET") || System.get_env("S3_BUCKET"),
      "instance_config" => SukhiShared.InstanceConfig.path()
    }

    :ok = File.write!(path, JSON.encode!(data) <> "\n")
    Logger.info("backup_manifest_written path=#{path}")
    :ok
  end

  @doc "Validate a restored backup inventory before normal startup."
  def check_backup_manifest!(path \\ "/var/lib/sukhi/backup-manifest.json") do
    :ok =
      SukhiFedi.Store.Manifest.validate_backup!(
        path,
        SukhiFedi.Store.Config.current()
      )

    :ok
  end

  @doc """
  Verify the external services needed before the HTTP endpoint is opened.

  The store opens with the application. PostgreSQL (the job queues) and NATS
  need an explicit check because their supervisors retry asynchronously during
  a normal application boot, and a refused connection there would read as a
  crash loop rather than as a missing service.
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

    Logger.info("runtime_connection_check_start service=postgres")
    check_postgres!()
    Logger.info("runtime_connection_check_complete service=postgres")

    if SukhiFedi.Config.nats_enabled?() do
      Logger.info("runtime_connection_check_start service=nats")
      check_nats!()
      Logger.info("runtime_connection_check_complete service=nats")
    else
      Logger.info("runtime_connection_check_skipped service=nats reason=disabled")
    end

    :ok
  end

  # One connection, one `SELECT 1`, with the settings the queue will use.
  defp check_postgres! do
    config = Application.get_env(@app, SukhiFedi.QueueRepo, [])
    host = Keyword.get(config, :hostname, "localhost")
    port = Keyword.get(config, :port, 5432)
    keys = [:hostname, :port, :database, :username, :password, :ssl, :ssl_opts]

    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, conn} = Postgrex.start_link(Keyword.take(config, keys))

    try do
      case Postgrex.query(conn, "SELECT 1", []) do
        {:ok, _} ->
          Logger.info("startup_connection_ok service=postgres endpoint=#{host}:#{port}")
          :ok

        {:error, reason} ->
          raise "postgres connection failed endpoint=#{host}:#{port}; check " <>
                  "`podman logs <postgres-container>` and `nc -vz #{host} #{port}` " <>
                  "as the sukhi user; startup stopped and existing data was not changed: " <>
                  Exception.message(reason)
      end
    after
      GenServer.stop(conn)
    end
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

  # Inside the live app (web request or rpc) the stores are up. A one-shot
  # `eval` starts both for the length of the call.
  defp with_stores(fun) do
    if Process.whereis(SukhiFedi.Repo) do
      fun.()
    else
      {:ok, result, _apps} =
        Ecto.Migrator.with_repo(SukhiFedi.Repo, fn _repo ->
          {:ok, result, _apps} =
            Ecto.Migrator.with_repo(SukhiFedi.AccountRepo, fn _repo -> fun.() end)

          result
        end)

      result
    end
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
          %SukhiFedi.Schema.Account{}
          |> Ecto.Changeset.change(
            Map.merge(
              %{
                username: username,
                display_name: display_name,
                summary: summary,
                is_bot: true,
                monitored_domain: monitored_domain
              },
              SukhiFedi.Keys.new_attrs()
            )
          )
          |> SukhiFedi.AccountRepo.insert!()

          :created

        _existing ->
          :already_exists
      end
    end

    {:ok, with_stores(do_seed)}
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

    with_stores(do_create)
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

    result = with_stores(run)

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
