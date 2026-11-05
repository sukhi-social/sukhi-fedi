# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Migrator do
  @moduledoc """
  Brings a Datalevin store forward to what this release reads, once, before
  the application serves anything (`Release.migrate_all/0`).

  There are two stores to bring forward: `:main` (`DATALEVIN_DIR`, the
  Ecto-shaped one) and `:graph` (`DATALEVIN_DIR/graph`, with `SUKHI_GRAPH=1`).
  Each keeps a `SukhiFedi.Datalevin.Manifest`; this module decides from it.

  For one store:

    1. **A directory with no data** is new. It is created with the current
       schema and every known migration is recorded as applied: there is
       nothing for them to change.
    2. **Data but no manifest**, or a format-1 manifest, is a store made
       before migrations existed. It is taken as it stands (a format-1
       fingerprint must still match this catalog), stamped, and every
       migration is pending: they are idempotent, so running one over data
       that did not need it changes nothing.
    3. **A manifest** is compared with this release (`plan/3`):
         * migrations it has run that this release does not know: the data
           is from a newer release. Refused.
         * a pending migration older than one applied: refused, as Postgres is.
         * the schema differs from the one it was stamped with
           (`SchemaDiff`): new attributes alone are fine; a removed or
           changed one with no pending migration is refused.
         * otherwise the pending migrations run, oldest first.
    4. After the migrations, the store is opened with the current schema
       once (so anything dtlv refuses is found *here*, before traffic) and
       the manifest is stamped with it.

  Before the first pending migration runs, the directory is copied to
  `datalevin-premigrate/` beside it (`DATALEVIN_PREMIGRATE_BACKUP=0` turns
  that off). Nothing deletes those copies.

  Nothing else may have the store open: `dtlv` is single-writer. The
  entrypoint runs this before the application starts; the application then
  refuses to start on a store this has not been run for (`check_current!/2`).
  """

  require Logger

  alias SukhiFedi.Datalevin.{Catalog, Client, Config, Manifest, Migration, SchemaDiff, SchemaFile}
  alias SukhiFedi.Datalevin.Migration.Ctx

  @type schema :: SchemaDiff.schema()
  @type store :: Migration.store()
  @type descriptor :: %{
          module: module(),
          version: pos_integer(),
          store: store(),
          description: String.t()
        }
  @type spec :: %{
          name: store(),
          config: Config.t(),
          schema: schema(),
          backup_root: String.t()
        }

  @client __MODULE__.Client
  @namespace "Elixir.SukhiFedi.Datalevin.Migrations."

  # ------------------------------------------------------------------ stores

  @doc "The stores this node runs: `:main`, and `:graph` when `SUKHI_GRAPH` is on."
  @spec specs(Config.t()) :: [spec()]
  def specs(base \\ Config.current()) do
    root = base.premigrate_dir || Path.join(Path.dirname(base.dir), "datalevin-premigrate")

    main = spec(:main, base, Catalog.dtlv_schema(), root)

    graph =
      if SukhiFedi.Graph.enabled?(),
        do: [
          spec(
            :graph,
            %{base | dir: Path.join(base.dir, "graph")},
            SchemaFile.to_dtlv(SchemaFile.read()),
            root
          )
        ],
        else: []

    [main | graph]
  end

  @spec spec(store(), Config.t(), schema(), String.t()) :: spec()
  def spec(name, %Config{} = config, schema, backup_root),
    do: %{name: name, config: config, schema: schema, backup_root: backup_root}

  # -------------------------------------------------------------- migrations

  @doc """
  The migrations in this release: modules under `SukhiFedi.Datalevin.Migrations`
  that `use SukhiFedi.Datalevin.Migration`, oldest first. Two with the same
  store and version are a mistake and raise.
  """
  @spec discover() :: [descriptor()]
  def discover do
    _ = Application.load(:sukhi_fedi)

    case :application.get_key(:sukhi_fedi, :modules) do
      {:ok, modules} ->
        modules
        |> Enum.filter(&String.starts_with?(Atom.to_string(&1), @namespace))
        |> describe_all()

      _ ->
        []
    end
  end

  @doc "Descriptors for the given modules (`discover/0` for the ones of this release), sorted, checked."
  @spec describe_all([module()]) :: [descriptor()]
  def describe_all(modules) do
    ds = modules |> Enum.map(&Migration.describe/1) |> Enum.reject(&is_nil/1)

    dup =
      ds
      |> Enum.group_by(&{&1.store, &1.version})
      |> Enum.find(fn {_, group} -> length(group) > 1 end)

    case dup do
      nil ->
        Enum.sort_by(ds, & &1.version)

      {{store, version}, group} ->
        raise ArgumentError,
              "two datalevin migrations share store=#{store} version=#{version}: " <>
                Enum.map_join(group, ", ", &inspect(&1.module))
    end
  end

  @doc "Newest migration version for the store in this release (0: none)."
  @spec latest_version(store()) :: non_neg_integer()
  def latest_version(store, migrations \\ nil) do
    (migrations || discover())
    |> Enum.filter(&(&1.store == store))
    |> Enum.map(& &1.version)
    |> Enum.max(fn -> 0 end)
  end

  # -------------------------------------------------------------------- plan

  @doc """
  What a format-2 manifest needs to meet `desired` with the `known`
  migrations of its store. Pure.
  """
  @spec plan(Manifest.t(), [descriptor()], schema()) ::
          {:ok, %{pending: [descriptor()], drift: SchemaDiff.t()}}
          | {:error, {:unknown_migrations, [integer()]}}
          | {:error, {:out_of_order, [integer()]}}
          | {:error, {:unmigrated, SchemaDiff.t()}}
  def plan(manifest, known, desired) do
    applied = for m <- manifest["migrations"] || [], do: m["version"]
    known_versions = Enum.map(known, & &1.version)
    pending = Enum.reject(known, &(&1.version in applied))
    newest = Enum.max(applied, fn -> 0 end)
    out_of_order = for d <- pending, d.version < newest, do: d.version
    drift = SchemaDiff.diff(manifest["schema"] || %{}, desired)

    cond do
      applied -- known_versions != [] ->
        {:error, {:unknown_migrations, Enum.sort(applied -- known_versions)}}

      out_of_order != [] ->
        {:error, {:out_of_order, out_of_order}}

      pending == [] and not SchemaDiff.additive?(drift) ->
        {:error, {:unmigrated, drift}}

      true ->
        {:ok, %{pending: pending, drift: drift}}
    end
  end

  @doc false
  @spec explain(term(), spec()) :: String.t()
  def explain({:unknown_migrations, versions}, spec) do
    "datalevin #{spec.name} store #{spec.config.dir} has run migrations this release does not " <>
      "know (#{Enum.join(versions, ", ")}): its data was written by a newer release. " <>
      "Start that release again, or restore a backup from before it ran."
  end

  def explain({:out_of_order, versions}, spec) do
    "datalevin #{spec.name} migrations #{Enum.join(versions, ", ")} are older than one already " <>
      "applied to #{spec.config.dir}. Rename them to a newer version " <>
      "(`mix sukhi.datalevin.gen.migration` takes the current time)."
  end

  def explain({:unmigrated, drift}, spec) do
    "datalevin #{spec.name} schema changed in a way that needs a migration " <>
      "(#{SchemaDiff.describe(drift)}) and none is pending for #{spec.config.dir}. " <>
      "Write one: `mix sukhi.datalevin.gen.migration NAME --store #{spec.name}`."
  end

  def explain({:pending, pending}, spec) do
    "datalevin #{spec.name} store #{spec.config.dir} has migrations to run " <>
      "(#{Enum.map_join(pending, ", ", & &1.version)}). " <>
      "Run `SukhiFedi.Release.migrate_all()` first (the container entrypoint does)."
  end

  def explain({:incompatible, expected, found}, spec) do
    "datalevin store is incompatible: #{Manifest.path(spec.config)}; " <>
      "stored catalog=#{inspect(found)} current catalog=#{expected}; " <>
      "it was stamped before migrations existed and its schema cannot be compared. " <>
      "Use the image that wrote it, or restore a compatible backup."
  end

  # --------------------------------------------------------------------- run

  @doc "Bring every store of this node forward (`Release.migrate_all/0`)."
  @spec run_all!(keyword()) :: :ok
  def run_all!(opts \\ []) do
    for spec <- Keyword.get_lazy(opts, :specs, &specs/0), do: run!(spec, opts)
    :ok
  end

  @doc """
  Bring one store forward. `opts[:migrations]` replaces `discover/0` (tests).
  Raises with a message that says what to do.
  """
  @spec run!(spec(), keyword()) :: :ok
  def run!(spec, opts \\ []) do
    known = known(spec, opts)
    {origin, manifest} = load!(spec, known)
    Logger.info("datalevin_store_start store=#{spec.name} dir=#{spec.config.dir} origin=#{origin}")

    manifest =
      case origin do
        :fresh ->
          manifest

        _ ->
          case plan(manifest, known, spec.schema) do
            {:error, reason} -> raise ArgumentError, explain(reason, spec)
            {:ok, %{pending: []}} ->
              manifest

            {:ok, %{pending: pending}} ->
              if manifest["migrating"],
                do:
                  Logger.warning(
                    "datalevin migration #{manifest["migrating"]["version"]} stopped midway " <>
                      "last time; running it again store=#{spec.name}"
                  )

              apply_pending!(spec, manifest, pending)
          end
      end

    # The proof: open with the schema this release wants. dtlv refuses what
    # it cannot reconcile, and that has to happen here, not after traffic.
    with_client(spec, spec.schema, fn _client -> :ok end)

    Manifest.write!(
      spec.config,
      Manifest.build(spec.config, spec.name, spec.schema, manifest["migrations"])
    )

    Logger.info(
      "datalevin_store_ready store=#{spec.name} schema_version=#{latest_applied(manifest)}"
    )

    :ok
  end

  @doc """
  The application's gate: a store with a manifest must have nothing left to
  migrate. No manifest (a new directory, tests, a store `run!/2` has not
  seen) passes: `run!/2` is what stamps those.
  """
  @spec check_current!(spec(), keyword()) :: :ok
  def check_current!(spec, opts \\ []) do
    case Manifest.read(spec.config) do
      {:ok, %{"format" => 2} = manifest} ->
        case plan(manifest, known(spec, opts), spec.schema) do
          {:ok, %{pending: []}} -> :ok
          {:ok, %{pending: pending}} -> raise ArgumentError, explain({:pending, pending}, spec)
          {:error, reason} -> raise ArgumentError, explain(reason, spec)
        end

      _ ->
        :ok
    end
  end

  @doc "Where each store stands, without changing anything."
  @spec status(keyword()) :: [map()]
  def status(opts \\ []) do
    for spec <- Keyword.get_lazy(opts, :specs, &specs/0) do
      known = known(spec, opts)
      base = %{store: spec.name, dir: spec.config.dir, latest: latest_version(spec.name, known)}

      case Manifest.read(spec.config) do
        {:error, msg} ->
          Map.merge(base, %{state: :error, problem: msg})

        :none ->
          if fresh?(spec),
            do: Map.merge(base, %{state: :fresh, version: nil, pending: []}),
            else: Map.merge(base, %{state: :legacy, version: nil, pending: versions(known)})

        {:ok, %{"format" => 2} = m} ->
          case plan(m, known, spec.schema) do
            {:ok, %{pending: pending, drift: drift}} ->
              Map.merge(base, %{
                state: if(pending == [], do: :current, else: :pending),
                version: m["schema_version"],
                pending: versions(pending),
                drift: drift
              })

            {:error, reason} ->
              Map.merge(base, %{
                state: :error,
                version: m["schema_version"],
                problem: explain(reason, spec)
              })
          end

        {:ok, m} ->
          Map.merge(base, %{state: :legacy, version: nil, pending: versions(known), format: m["format"]})
      end
    end
  end

  # ------------------------------------------------------------------ states

  # `{origin, format-2 manifest}`: what the store is, and what it is taken to be.
  defp load!(spec, known) do
    case Manifest.read(spec.config) do
      {:error, msg} ->
        raise ArgumentError, msg

      :none ->
        if fresh?(spec) do
          applied = Enum.map(known, &entry(&1, "new store"))
          {:fresh, Manifest.build(spec.config, spec.name, spec.schema, applied)}
        else
          Logger.warning(
            "datalevin store without a manifest; taking it as it stands store=#{spec.name} " <>
              "dir=#{spec.config.dir}"
          )

          {:legacy, Manifest.build(spec.config, spec.name, spec.schema, [])}
        end

      {:ok, %{"format" => 2} = manifest} ->
        {:existing, manifest}

      {:ok, %{"format" => 1} = manifest} ->
        expected = Manifest.legacy_sha256(spec.schema)

        if manifest["catalog_sha256"] == expected,
          do: {:legacy, Manifest.build(spec.config, spec.name, spec.schema, [])},
          else:
            raise(ArgumentError, explain({:incompatible, expected, manifest["catalog_sha256"]}, spec))

      {:ok, manifest} ->
        raise ArgumentError,
              "unknown store manifest format #{inspect(manifest["format"])}: #{Manifest.path(spec.config)}"
    end
  end

  # No data yet: nothing in the directory but our own files (and, for the
  # main store, the graph's subdirectory).
  defp fresh?(spec) do
    case File.ls(spec.config.dir) do
      {:ok, entries} -> entries -- ignorable(spec) == []
      {:error, :enoent} -> true
      {:error, reason} -> raise "cannot list #{spec.config.dir}: #{inspect(reason)}"
    end
  end

  defp ignorable(spec) do
    own = [Manifest.file_name(), Manifest.file_name() <> ".tmp"]
    if spec.name == :main, do: ["graph" | own], else: own
  end

  # ----------------------------------------------------------------- applying

  defp apply_pending!(spec, manifest, pending) do
    backup!(spec, hd(pending).version)

    # Old attributes stay defined while the migrations read them; the
    # snapshot wins over the new schema where the two disagree, because
    # that is what the data is.
    run_schema =
      spec.schema
      |> Map.merge(manifest["schema"] || %{})
      |> then(fn base ->
        Enum.reduce(pending, base, fn d, acc -> Map.merge(acc, d.module.schema()) end)
      end)

    with_client(spec, run_schema, fn client ->
      ctx = %Ctx{client: client, config: spec.config, store: spec.name}

      Enum.reduce(pending, manifest, fn d, m ->
        m = mark!(spec, m, d)
        Logger.info("datalevin_migration_start store=#{spec.name} version=#{d.version} #{d.description}")

        case d.module.up(ctx) do
          :ok -> :ok
          other -> raise "#{inspect(d.module)}.up/1 must return :ok, got #{inspect(other)}"
        end

        m = record!(spec, m, d)
        Logger.info("datalevin_migration_done store=#{spec.name} version=#{d.version}")
        m
      end)
    end)
  end

  defp mark!(spec, manifest, d) do
    manifest
    |> Map.put("migrating", %{"version" => d.version, "started_at" => now()})
    |> then(&write_through!(spec, &1))
  end

  defp record!(spec, manifest, d) do
    applied = (manifest["migrations"] || []) ++ [entry(d)]

    manifest
    |> Map.merge(%{
      "migrations" => applied,
      "schema_version" => applied |> Enum.map(& &1["version"]) |> Enum.max(),
      "migrating" => nil
    })
    |> then(&write_through!(spec, &1))
  end

  defp write_through!(spec, manifest) do
    :ok = Manifest.write!(spec.config, manifest)
    manifest
  end

  defp entry(d, note \\ nil) do
    base = %{"version" => d.version, "name" => d.description, "applied_at" => now()}
    if note, do: Map.put(base, "note", note), else: base
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp latest_applied(manifest),
    do: (manifest["migrations"] || []) |> Enum.map(& &1["version"]) |> Enum.max(fn -> 0 end)

  # ------------------------------------------------------------------ helpers

  defp known(spec, opts) do
    case Keyword.fetch(opts, :migrations) do
      {:ok, modules} -> describe_all(modules)
      :error -> discover()
    end
    |> Enum.filter(&(&1.store == spec.name))
  end

  defp versions(ds), do: Enum.map(ds, & &1.version)

  # A throwaway `dtlv` child on this store: the migrator is the only thing
  # that has it open, and closes it before anything else may.
  defp with_client(spec, schema, fun) do
    trapping? = Process.flag(:trap_exit, true)

    try do
      case Client.start_link(name: @client, config: spec.config, schema: schema) do
        {:ok, pid} ->
          try do
            fun.(@client)
          after
            stop(pid)
          end

        {:error, reason} ->
          raise "datalevin could not open #{spec.config.dir}: #{inspect(reason)}"
      end
    after
      flush_exits()
      Process.flag(:trap_exit, trapping?)
    end
  end

  defp stop(pid) do
    GenServer.stop(pid, :normal, 60_000)
  catch
    :exit, _ -> :ok
  end

  defp flush_exits do
    receive do
      {:EXIT, _, _} -> flush_exits()
    after
      0 -> :ok
    end
  end

  # ------------------------------------------------------------------ backups

  defp backup!(%{config: %{premigrate_backup: false}}, _version), do: :skipped

  defp backup!(spec, version) do
    src = spec.config.dir

    skip = [Manifest.file_name() <> ".tmp" | if(spec.name == :main, do: ["graph"], else: [])]

    keep =
      case File.ls(src) do
        {:ok, entries} -> entries -- skip
        {:error, :enoent} -> []
      end

    if keep == [] do
      :skipped
    else
      stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
      dest = Path.join(spec.backup_root, "#{spec.name}-#{stamp}-before-#{version}")
      File.mkdir_p!(dest)

      for entry <- keep do
        case File.cp_r(Path.join(src, entry), Path.join(dest, entry)) do
          {:ok, _} -> :ok
          {:error, reason, file} -> raise "premigrate backup failed at #{file}: #{inspect(reason)}"
        end
      end

      Logger.info("datalevin_premigrate_backup store=#{spec.name} from=#{src} to=#{dest}")
      {:ok, dest}
    end
  end
end
