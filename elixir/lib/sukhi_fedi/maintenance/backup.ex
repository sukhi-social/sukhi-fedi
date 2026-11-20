# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Maintenance.Backup do
  @moduledoc """
  A copy of everything a Datalevin instance needs to come back
  (docs/OPS_DRAIN_BACKUP.ja.md), into one directory:

      <root>/<UTC stamp>/
        datalevin/            dtlv copy of DATALEVIN_DIR   (the business data)
        datalevin/.sukhi-store.json
        backup-manifest.json  the restore inventory `Release.check_datalevin_backup_manifest!/1` reads
        backup-info.json      what this run copied: sizes, versions, the door's state

  The directory is built as `<stamp>.partial` and renamed only after every
  piece was copied **and read back** (`dtlv stat` on each copy), so a
  directory with a bare stamp is a copy that opened. A failed run removes its partial and leaves nothing that
  looks like a backup.

  The copy tool is the one built for a database in use: `dtlv copy`
  ("regardless of whether it is now in use", dtlv's own help). So `run/1`
  works on a live server; the drain (`SukhiFedi.Maintenance.Drain.backup/1`)
  is what makes the moment quiet. A plain `cp` of these files is not a backup
  and is never used here.

  **Not covered**: everything in PostgreSQL (the job queues, and the raw bodies
  when `SUKHI_RAW_BACKEND=postgres`, the default; take those with the
  database's own backup), raw bodies in S3 (the bucket's own
  versioning/replication), the mounted `/etc/sukhi/instance.json`, and every
  `podman secret` — a secret copied into a backup directory would be a secret
  copied to every place the backup goes. `backup-info.json` says which raw
  backend applied.

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
  `:config` (a `Datalevin.Config`), `:cmd`, `:free_bytes`,
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

    stamp = Calendar.strftime(ctx.now.(), "%Y%m%dT%H%M%SZ")
    final = Path.join(ctx.root, stamp)
    partial = final <> ".partial"

    result =
      with :ok <- absent(final),
           :ok <- File.mkdir_p(partial),
           :ok <- enough_space(ctx, partial),
           {:ok, items} <- copy_datalevin(ctx, partial),
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

    envs = [{ctx.config.dir, dest, :datalevin}]

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

  # ── Manifests ─────────────────────────────────────────────────────────────

  defp write_manifests(ctx, partial, items) do
    with :ok <- ctx.manifest.(Path.join(partial, "backup-manifest.json")) do
      info = %{
        format: 1,
        created_at: DateTime.to_iso8601(ctx.now.()),
        app_version: to_string(Application.spec(:sukhi_fedi, :vsn)),
        store: "datalevin",
        raw_backend: System.get_env("SUKHI_RAW_BACKEND", "postgres"),
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
    size(ctx.config.dir)
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
      root: Keyword.get_lazy(opts, :root, &root/0),
      config: config,
      cmd: Keyword.get(opts, :cmd, &cmd/2),
      free_bytes: Keyword.get(opts, :free_bytes, &free_bytes/1),
      manifest:
        Keyword.get(opts, :manifest, fn path ->
          SukhiFedi.Release.write_datalevin_backup_manifest!(path)
        end),
      now: Keyword.get(opts, :now, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end)
    }
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
