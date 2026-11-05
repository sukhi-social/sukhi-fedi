# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.Backup do
  @moduledoc """
  A copy of everything a Datalevin instance needs to come back
  (docs/OPS_DRAIN_BACKUP.ja.md), into one directory:

      <root>/<UTC stamp>/
        datalevin/            dtlv copy of DATALEVIN_DIR   (the business data)
        datalevin/graph/      dtlv copy of its graph env   (only with SUKHI_GRAPH)
        datalevin/.sukhi-store.json
        queue.db              VACUUM INTO of SUKHI_QUEUE_DB
        delivery_queue.db     VACUUM INTO of DELIVERY_QUEUE_DB (combined release)
        backup-manifest.json  the restore inventory `Release.check_datalevin_backup_manifest!/1` reads
        backup-info.json      what this run copied: sizes, versions, the door's state

  The directory is built as `<stamp>.partial` and renamed only after every
  piece was copied **and read back** (`dtlv stat` on each copy, SQLite's
  `quick_check` on each queue file), so a directory with a bare stamp is a
  copy that opened. A failed run removes its partial and leaves nothing that
  looks like a backup.

  Both copy tools are the ones built for a database in use: `dtlv copy`
  ("regardless of whether it is now in use", dtlv's own help) and SQLite's
  `VACUUM INTO`. So `run/1` works on a live server; the drain
  (`SukhiFedi.Maintenance.Drain.backup/1`) is what makes the moment quiet.
  A plain `cp` of these files is not a backup and is never used here.

  **Not covered** (the manifest says which applies): raw bodies when
  `SUKHI_RAW_BACKEND=s3` (the bucket's own versioning/replication), the
  mounted `/etc/sukhi/instance.json`, and every `podman secret` — a secret
  copied into a backup directory would be a secret copied to every place the
  backup goes.

  Only one `run/1` at a time (`:global` lock); a second caller gets
  `{:error, :already_running}` at once.
  """

  alias SukhiFedi.Datalevin.{Config, Manifest}

  @default_root "/var/lib/sukhi/backups"
  @default_keep 3
  @stamp ~r/\A\d{8}T\d{6}Z\z/
  @partial ~r/\A\d{8}T\d{6}Z\.partial\z/
  @cmd_timeout_ms 30 * 60 * 1000

  @type info :: %{dir: String.t(), bytes: non_neg_integer(), items: [map()], pruned: [String.t()]}

  @doc "Where backups go (`SUKHI_BACKUP_DIR`)."
  @spec root() :: String.t()
  def root do
    case Application.get_env(:sukhi_fedi, :backup_dir) || System.get_env("SUKHI_BACKUP_DIR") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> @default_root
    end
  end

  @doc """
  Take a backup. `{:ok, info}` or `{:error, reason}`.

  Options (all for tests, apart from `:keep`): `:root`, `:keep` (how many
  complete backups to retain, default #{@default_keep}; `nil` keeps all),
  `:config` (a `Datalevin.Config`), `:graph_dir`, `:queue_dbs`
  (`[{repo, path}]`), `:cmd`, `:vacuum`, `:quick_check`, `:free_bytes`,
  `:now`, `:manifest`.
  """
  @spec run(keyword()) :: {:ok, info()} | {:error, term()}
  def run(opts \\ []) do
    # `{resource, requester}`: the requester must be this caller, or two
    # callers would count as one and both be let in.
    case :global.trans({__MODULE__, self()}, fn -> locked_run(opts) end, [node()], 0) do
      :aborted -> {:error, :already_running}
      result -> result
    end
  end

  defp locked_run(opts) do
    ctx = ctx(opts)

    if ctx.datalevin? do
      stamp = Calendar.strftime(ctx.now.(), "%Y%m%dT%H%M%SZ")
      final = Path.join(ctx.root, stamp)
      partial = final <> ".partial"

      result =
        with :ok <- absent(final),
             :ok <- File.mkdir_p(partial),
             :ok <- enough_space(ctx, partial),
             {:ok, a} <- copy_datalevin(ctx, partial),
             {:ok, b} <- copy_queues(ctx, partial),
             items = a ++ b,
             :ok <- write_manifests(ctx, partial, items),
             :ok <- File.rename(partial, final) do
          {:ok, %{dir: final, items: items, bytes: Enum.sum(Enum.map(items, & &1.bytes))}}
        end

      case result do
        {:ok, info} ->
          {:ok, Map.put(info, :pruned, prune(ctx.root, Keyword.get(opts, :keep, @default_keep)))}

        {:error, _} = error ->
          File.rm_rf(partial)
          error
      end
    else
      {:error, :not_datalevin}
    end
  end

  @doc """
  Remove all but the newest `keep` complete backups under `root`, and any
  leftover `.partial`. Only directories named like a stamp are touched, and a
  complete one must hold our `backup-info.json`: a directory somebody else put
  there is never removed. Returns the names removed.
  """
  @spec prune(String.t(), pos_integer() | nil) :: [String.t()]
  def prune(root, keep) do
    names =
      case File.ls(root) do
        {:ok, names} -> names
        {:error, _} -> []
      end

    leftovers = Enum.filter(names, &Regex.match?(@partial, &1))

    complete =
      names
      |> Enum.filter(&Regex.match?(@stamp, &1))
      |> Enum.filter(&File.regular?(Path.join([root, &1, "backup-info.json"])))
      |> Enum.sort(:desc)

    old = if is_integer(keep) and keep > 0, do: Enum.drop(complete, keep), else: []

    for name <- leftovers ++ old do
      File.rm_rf!(Path.join(root, name))
      name
    end
  end

  # ── Datalevin ─────────────────────────────────────────────────────────────

  defp copy_datalevin(ctx, partial) do
    dest = Path.join(partial, "datalevin")

    envs =
      [{ctx.config.dir, dest, :datalevin}] ++
        case ctx.graph_dir do
          nil -> []
          dir -> [{dir, Path.join(dest, "graph"), :datalevin_graph}]
        end

    with {:ok, exe} <- dtlv(ctx),
         {:ok, items} <- copy_envs(ctx, exe, envs, partial) do
      store = Manifest.path(ctx.config)

      if File.regular?(store) do
        :ok = File.cp(store, Path.join(dest, Path.basename(store)))
      end

      {:ok, items}
    end
  end

  defp copy_envs(ctx, exe, envs, partial) do
    Enum.reduce_while(envs, {:ok, []}, fn {src, dst, kind}, {:ok, acc} ->
      case copy_env(ctx, exe, src, dst) do
        :ok ->
          item = %{kind: kind, path: Path.relative_to(dst, partial), bytes: size(dst)}
          {:cont, {:ok, acc ++ [item]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # `dtlv -d SRC copy DEST`, then `dtlv -d DEST stat` on the copy: the copy has
  # to open. (-Xmx etc. come first, as for the long-running child.)
  defp copy_env(ctx, exe, src, dst) do
    args = Config.runtime_args(ctx.config)

    with :ok <- File.mkdir_p(dst),
         :ok <- run_cmd(ctx, :dtlv_copy, exe, args ++ ["-d", src, "copy", dst]) do
      run_cmd(ctx, :dtlv_stat, exe, args ++ ["-d", dst, "stat"])
    end
  end

  defp dtlv(ctx) do
    case System.find_executable(ctx.config.bin) do
      nil -> {:error, {:dtlv_not_found, ctx.config.bin}}
      exe -> {:ok, exe}
    end
  end

  defp run_cmd(ctx, what, exe, args) do
    case ctx.cmd.(exe, args) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {what, status, tail(out)}}
    end
  end

  # ── SQLite queues ─────────────────────────────────────────────────────────

  defp copy_queues(ctx, partial) do
    Enum.reduce_while(ctx.queue_dbs, {:ok, []}, fn {repo, path}, {:ok, acc} ->
      dest = Path.join(partial, Path.basename(path))

      with :ok <- ctx.vacuum.(repo, dest),
           :ok <- ctx.quick_check.(dest) do
        item = %{kind: :sqlite, path: Path.basename(path), bytes: size(dest)}
        {:cont, {:ok, acc ++ [item]}}
      else
        {:error, reason} -> {:halt, {:error, {:sqlite, Path.basename(path), reason}}}
      end
    end)
  end

  @doc false
  def vacuum_into(repo, dest) do
    case Ecto.Adapters.SQL.query(repo, "VACUUM INTO ?1", [dest]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc false
  def quick_check(path) do
    with {:ok, conn} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
      try do
        with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, "PRAGMA quick_check"),
             {:ok, rows} <- Exqlite.Sqlite3.fetch_all(conn, stmt),
             :ok <- Exqlite.Sqlite3.release(conn, stmt) do
          case rows do
            [["ok"]] -> :ok
            other -> {:error, {:quick_check, other}}
          end
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  # ── Manifests ─────────────────────────────────────────────────────────────

  defp write_manifests(ctx, partial, items) do
    with :ok <- ctx.manifest.(Path.join(partial, "backup-manifest.json")) do
      info = %{
        format: 1,
        created_at: DateTime.to_iso8601(ctx.now.()),
        app_version: to_string(Application.spec(:sukhi_fedi, :vsn)),
        store: "datalevin",
        raw_backend: System.get_env("SUKHI_RAW_BACKEND", "sqlite"),
        raw_covered: System.get_env("SUKHI_RAW_BACKEND", "sqlite") == "sqlite",
        items: items,
        intake: SukhiShared.Intake.marker(SukhiShared.Intake.status())
      }

      File.write(Path.join(partial, "backup-info.json"), JSON.encode!(info) <> "\n")
    end
  end

  # ── Space and sizes ───────────────────────────────────────────────────────

  # A backup that fills the disk takes the server down with it. Compare what
  # the sources weigh (a little over, for the copy's own overhead) with what
  # the volume has; when the volume cannot be read, say nothing and go on.
  defp enough_space(ctx, partial) do
    need = ceil(source_bytes(ctx) * 1.1)

    case ctx.free_bytes.(partial) do
      free when is_integer(free) and free < need ->
        {:error, {:no_space, %{need: need, free: free}}}

      _ ->
        :ok
    end
  end

  defp source_bytes(ctx) do
    size(ctx.config.dir) + Enum.sum(for {_repo, path} <- ctx.queue_dbs, do: size(path))
  end

  @doc false
  def free_bytes(path) do
    with {out, 0} <- System.cmd("df", ["-Pk", path], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [_fs, _blocks, _used, avail | _] <- String.split(line),
         {kb, ""} <- Integer.parse(avail) do
      kb * 1024
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp size(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: n}} ->
        n

      {:ok, %{type: :directory}} ->
        Path.wildcard(Path.join(path, "**/*"), match_dot: true)
        |> Enum.reduce(0, fn p, acc ->
          case File.stat(p) do
            {:ok, %{type: :regular, size: n}} -> acc + n
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end

  # ── Plumbing ──────────────────────────────────────────────────────────────

  defp absent(path),
    do: if(File.exists?(path), do: {:error, {:exists, path}}, else: :ok)

  defp tail(out), do: out |> String.trim() |> String.slice(-400..-1//1)

  defp ctx(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.current/0)

    %{
      datalevin?: Keyword.get_lazy(opts, :datalevin?, &SukhiFedi.Store.datalevin?/0),
      root: Keyword.get_lazy(opts, :root, &root/0),
      config: config,
      graph_dir: Keyword.get_lazy(opts, :graph_dir, fn -> graph_dir(config) end),
      queue_dbs: Keyword.get_lazy(opts, :queue_dbs, &queue_dbs/0),
      cmd: Keyword.get(opts, :cmd, &cmd/2),
      vacuum: Keyword.get(opts, :vacuum, &vacuum_into/2),
      quick_check: Keyword.get(opts, :quick_check, &quick_check/1),
      free_bytes: Keyword.get(opts, :free_bytes, &free_bytes/1),
      manifest:
        Keyword.get(opts, :manifest, fn path ->
          SukhiFedi.Release.write_datalevin_backup_manifest!(path)
        end),
      now: Keyword.get(opts, :now, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end)
    }
  end

  defp graph_dir(config),
    do: if(SukhiFedi.Graph.enabled?(), do: Path.join(config.dir, "graph"), else: nil)

  # Every SQLite queue this BEAM runs: the gateway's, and delivery's when
  # combined. Whatever file the repo is configured on, not a path guessed
  # from an env var.
  defp queue_dbs do
    for repo <- SukhiFedi.Queue.job_repos(),
        path = repo.config()[:database],
        is_binary(path) do
      {repo, path}
    end
  end

  # One command, with an end: a copy that hangs would hang the rpc and the
  # maintenance window with it.
  defp cmd(exe, args) do
    task = Task.async(fn -> System.cmd(exe, args, stderr_to_stdout: true) end)

    case Task.yield(task, @cmd_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"timed out after #{div(@cmd_timeout_ms, 1000)}s", 124}
    end
  end
end
