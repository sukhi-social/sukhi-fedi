# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Config do
  @moduledoc """
  Every knob of the Datalevin store, and the one place that reads them.

  `from_env/1` turns environment variables (a map, so tests need no real
  environment) into a validated `t:t/0`; `open_opts/1` and `runtime_args/1`
  turn that into what `dtlv` is asked for. docs/DATALEVIN.md says what each
  knob costs and what to set on a small box.

  ## Durability — the one choice that matters

  `DATALEVIN_DURABILITY` picks how a commit reaches the disk:

      strict   write-ahead log, fsync before the commit returns (default)
      relaxed  write-ahead log, fsync in batches; a crash loses a bounded tail
      extra    like strict, plus macOS F_FULLSYNC (the same as strict on Linux)
      lmdb     no log, LMDB syncs every commit (dtlv's own default)
      nosync   no log, LMDB never syncs on commit; fastest, and a crash can
               lose far more than a tail — meant for tests and throwaway data

  The rest are sizes and bounds, all with a default that fits a 0.5 OCPU /
  512 MB box.
  """

  @type durability :: :strict | :relaxed | :extra | :lmdb | :nosync

  @type t :: %__MODULE__{
          dir: String.t(),
          bin: String.t(),
          durability: durability(),
          map_size_mb: pos_integer(),
          xmx: String.t() | nil,
          runtime_args: [String.t()],
          wal_group_commit: pos_integer() | nil,
          wal_group_commit_ms: pos_integer() | nil,
          wal_retention_bytes: pos_integer() | nil,
          wal_retention_hours: pos_integer() | nil,
          write_batch_delay_us: non_neg_integer() | nil,
          write_batch_size: pos_integer() | nil,
          cache_limit: non_neg_integer() | nil,
          batch: pos_integer(),
          timeout_ms: pos_integer()
        }

  defstruct dir: "/var/lib/sukhi/datalevin",
            bin: "dtlv",
            durability: :strict,
            map_size_mb: 1024,
            xmx: "96m",
            runtime_args: [],
            wal_group_commit: nil,
            wal_group_commit_ms: nil,
            wal_retention_bytes: 256 * 1024 * 1024,
            wal_retention_hours: 24,
            write_batch_delay_us: nil,
            write_batch_size: nil,
            cache_limit: nil,
            batch: 500,
            timeout_ms: 30_000

  @durabilities ~w(strict relaxed extra lmdb nosync)

  @doc "The configuration in effect: the environment, with `:sukhi_fedi, :datalevin` overrides on top."
  @spec current() :: t()
  def current do
    base = from_env(System.get_env())
    overrides = Application.get_env(:sukhi_fedi, :datalevin, [])
    struct!(base, overrides)
  end

  @doc """
  Parse and validate. Raises `ArgumentError` naming the variable, so a typo
  fails the boot instead of quietly running with a default.
  """
  @spec from_env(%{optional(String.t()) => String.t()}) :: t()
  def from_env(env) do
    d = %__MODULE__{}

    %__MODULE__{
      dir: str(env, "DATALEVIN_DIR", d.dir),
      bin: str(env, "DATALEVIN_BIN", d.bin),
      durability: durability(env, d.durability),
      map_size_mb: int(env, "DATALEVIN_MAP_SIZE_MB", d.map_size_mb, 16),
      xmx: xmx(env, d.xmx),
      runtime_args: words(env, "DATALEVIN_RUNTIME_ARGS"),
      wal_group_commit: opt_int(env, "DATALEVIN_WAL_GROUP_COMMIT", 1),
      wal_group_commit_ms: opt_int(env, "DATALEVIN_WAL_GROUP_COMMIT_MS", 1),
      wal_retention_bytes:
        case int(env, "DATALEVIN_WAL_RETENTION_MB", div(d.wal_retention_bytes, 1_048_576), 1) do
          mb -> mb * 1_048_576
        end,
      wal_retention_hours: int(env, "DATALEVIN_WAL_RETENTION_HOURS", d.wal_retention_hours, 1),
      write_batch_delay_us: opt_int(env, "DATALEVIN_WRITE_BATCH_DELAY_US", 0),
      write_batch_size: opt_int(env, "DATALEVIN_WRITE_BATCH_SIZE", 1),
      cache_limit: opt_int(env, "DATALEVIN_CACHE_LIMIT", 0),
      batch: int(env, "DATALEVIN_BATCH", d.batch, 1, 5_000),
      timeout_ms: int(env, "DATALEVIN_TIMEOUT_MS", d.timeout_ms, 100)
    }
  end

  @doc "Is the write-ahead log on?"
  @spec wal?(t()) :: boolean()
  def wal?(%__MODULE__{durability: d}), do: d in [:strict, :relaxed, :extra]

  @doc """
  The `opts` map of `datalevin_open_database` (EDN keywords spelled as
  `":"`-prefixed strings, which is how the JSON API takes them).
  """
  @spec open_opts(t()) :: map()
  def open_opts(%__MODULE__{} = c) do
    kv = %{":mapsize" => c.map_size_mb}

    kv =
      case c.durability do
        :nosync -> Map.put(kv, ":flags", [":nosync", ":notls"])
        _ -> kv
      end

    wal =
      if wal?(c) do
        compact(%{
          ":wal?" => true,
          ":wal-durability-profile" => ":" <> Atom.to_string(c.durability),
          ":wal-group-commit" => c.wal_group_commit,
          ":wal-group-commit-ms" => c.wal_group_commit_ms,
          ":wal-retention-bytes" => c.wal_retention_bytes,
          ":wal-retention-ms" => c.wal_retention_hours && c.wal_retention_hours * 3_600_000
        })
      else
        %{}
      end

    compact(%{
      ":kv-opts" => kv,
      ":write-batch-delay-us" => c.write_batch_delay_us,
      ":write-batch-size" => c.write_batch_size,
      ":cache-limit" => c.cache_limit
    })
    |> Map.merge(wal)
  end

  @doc "Arguments placed before `mcp -w`: GraalVM native-image runtime flags."
  @spec runtime_args(t()) :: [String.t()]
  def runtime_args(%__MODULE__{xmx: xmx, runtime_args: extra}) do
    if(xmx, do: ["-Xmx" <> xmx], else: []) ++ extra
  end

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  defp str(env, key, default) do
    case env[key] do
      v when v in [nil, ""] -> default
      v -> v
    end
  end

  defp durability(env, default) do
    case env["DATALEVIN_DURABILITY"] do
      v when v in [nil, ""] ->
        default

      v when v in @durabilities ->
        String.to_atom(v)

      v ->
        raise ArgumentError,
              "DATALEVIN_DURABILITY=#{inspect(v)}: want one of #{Enum.join(@durabilities, ", ")}"
    end
  end

  # `-Xmx` takes a number with a k/m/g suffix; `0` or `none` leaves the heap uncapped.
  defp xmx(env, default) do
    case env["DATALEVIN_XMX"] do
      v when v in [nil, ""] ->
        default

      v when v in ["0", "none"] ->
        nil

      v ->
        if Regex.match?(~r/^\d+[kKmMgG]$/, v),
          do: v,
          else: bad("DATALEVIN_XMX", v, "like 64m or 1g")
    end
  end

  defp words(env, key), do: env |> Map.get(key, "") |> String.split(" ", trim: true)

  defp opt_int(env, key, min) do
    case env[key] do
      v when v in [nil, ""] -> nil
      _ -> int(env, key, nil, min)
    end
  end

  defp int(env, key, default, min, max \\ nil) do
    case env[key] do
      v when v in [nil, ""] ->
        default

      v ->
        case Integer.parse(v) do
          {n, ""} when n >= min and (is_nil(max) or n <= max) -> n
          _ -> bad(key, v, "an integer >= #{min}" <> if(max, do: " and <= #{max}", else: ""))
        end
    end
  end

  defp bad(key, v, want), do: raise(ArgumentError, "#{key}=#{inspect(v)}: want #{want}")
end
