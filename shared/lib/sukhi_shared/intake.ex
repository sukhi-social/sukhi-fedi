# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.Intake do
  @moduledoc """
  Is this server taking anything new in? The one answer, and the one place it
  is kept.

  `:open` is the normal state. `:closed` is the quiet before a planned
  shutdown (docs/OPS_DRAIN_BACKUP.ja.md): the gateway answers every write
  with `503` + `Retry-After` and reads keep working, the federation inbox is
  refused (a `5xx`, so the sender tries again later instead of believing the
  activity landed), and the background writers stand still.

  Everyone who has to *decide* asks here (`closed?/0`): the HTTP gate
  (`SukhiFedi.Web.IntakePlug`), the pull-federation puller, the drain
  procedure. Nobody keeps a copy of the flag. It lives in `:persistent_term`
  — written rarely, read on every request — so it is one BEAM wide: the
  gateway, delivery and api share it in the combined release, which is the
  only shape Datalevin runs in (one writer).

  ## Opening is the default

  A fresh BEAM is always `:open`. A drain is a property of the running
  process, not of the disk: after the update that follows it, nobody has to
  remember to open the door, and a crash restart in the middle of a drain
  loses nothing (every step can be run again).

  ## The marker file

  Every change is also written to a small JSON file (`SUKHI_INTAKE_FILE`,
  default `/var/lib/sukhi/intake.json`, on the data volume) so that something
  that is *not* this BEAM can see it — most of all a static "we are under
  maintenance, you can still read" page served while the gateway is stopped.
  The file is written whole, through a temp file and a rename, so a reader
  never sees half of it. It stays `closed` while the gateway is down for the
  update; the next boot overwrites it with `open`.

  The public view (`public/1`, what `GET /.sukhi/intake.json` says) never
  carries a path or a count — only the state, since when, why, and when to
  come back. The marker adds the backup that was taken, for the operator.
  """

  require Logger

  @key {__MODULE__, :state}
  @default_retry_after_s 300
  @default_file "/var/lib/sukhi/intake.json"

  @type state :: :open | :closed
  @type t :: %{
          required(:state) => state(),
          required(:since) => DateTime.t(),
          optional(:reason) => String.t(),
          optional(:until) => DateTime.t() | nil,
          optional(:retry_after_s) => pos_integer(),
          optional(:settled_at) => DateTime.t() | nil,
          optional(:backup) => %{dir: String.t(), at: DateTime.t()} | nil
        }

  # ── Asking ────────────────────────────────────────────────────────────────

  @doc "Is the door shut? The only predicate; everything that gates on intake calls this."
  @spec closed?() :: boolean()
  def closed?, do: match?(%{state: :closed}, :persistent_term.get(@key, nil))

  @doc "The negation, for call sites that read better that way."
  @spec open?() :: boolean()
  def open?, do: not closed?()

  @doc "The whole state. An untouched BEAM is open since the epoch."
  @spec status() :: t()
  def status do
    case :persistent_term.get(@key, nil) do
      nil -> %{state: :open, since: ~U[1970-01-01 00:00:00Z]}
      status -> status
    end
  end

  @doc "Seconds a refused caller is told to wait (`Retry-After`)."
  @spec retry_after_s() :: pos_integer()
  def retry_after_s do
    case status() do
      %{retry_after_s: s} when is_integer(s) and s > 0 -> s
      _ -> @default_retry_after_s
    end
  end

  # ── Changing ──────────────────────────────────────────────────────────────

  @doc """
  Shut the door. Idempotent: closing a closed server keeps its `since` (and
  whatever was learnt since — settled, backup) and only takes the new reason,
  `until` and `retry_after_s` if they were given.

  Options: `:reason` (a short word, default `"maintenance"`), `:until`
  (a `DateTime` the operator expects to be back by), `:retry_after_s`.
  """
  @spec close(keyword()) :: t()
  def close(opts \\ []) do
    now = now()

    base =
      case status() do
        %{state: :closed} = s -> s
        _open -> %{state: :closed, since: now, settled_at: nil, backup: nil}
      end

    next =
      base
      |> Map.put(:reason, reason(Keyword.get(opts, :reason), base))
      |> put_given(:until, opts)
      |> Map.put(:retry_after_s, retry(Keyword.get(opts, :retry_after_s), base))

    commit(next)
  end

  @doc "Open the door. A no-op (apart from the marker) when it is already open."
  @spec open(keyword()) :: t()
  def open(_opts \\ []) do
    case status() do
      %{state: :open} = s -> commit(s)
      _closed -> commit(%{state: :open, since: now()})
    end
  end

  @doc """
  Record something learnt while closed: `settled_at` (the queues stood still)
  or `backup` (`%{dir:, at:}`). Ignored when open — a backup note on an open
  server would be a lie by the time anyone read it.
  """
  @spec note(:settled_at | :backup, term()) :: t()
  def note(key, value) when key in [:settled_at, :backup] do
    case status() do
      %{state: :closed} = s -> commit(Map.put(s, key, value))
      open -> open
    end
  end

  @doc """
  Called once as the application starts: make the marker say `open`, so a
  marker left `closed` by the shutdown before this boot does not outlive it.
  """
  @spec boot() :: t()
  def boot, do: open()

  # ── Showing ───────────────────────────────────────────────────────────────

  @doc """
  What any visitor may be told (`GET /.sukhi/intake.json`): state, since,
  why, and when to come back. No paths, no counts, no backup.
  """
  @spec public(t()) :: map()
  def public(%{state: :open, since: since}), do: %{state: "open", since: iso(since)}

  def public(%{state: :closed} = s) do
    %{
      state: "closed",
      since: iso(s.since),
      reason: Map.get(s, :reason),
      until: iso(Map.get(s, :until)),
      retry_after_s: Map.get(s, :retry_after_s, @default_retry_after_s)
    }
  end

  @doc "The marker's content: the public view plus what the operator needs."
  @spec marker(t()) :: map()
  def marker(%{state: :open} = s), do: public(s)

  def marker(%{state: :closed} = s) do
    Map.merge(public(s), %{
      settled_at: iso(Map.get(s, :settled_at)),
      backup:
        case Map.get(s, :backup) do
          %{dir: dir, at: at} -> %{dir: dir, at: iso(at)}
          nil -> nil
        end
    })
  end

  @doc "Where the marker is written."
  @spec marker_path() :: String.t()
  def marker_path do
    case Application.get_env(:sukhi_shared, :intake_file) || System.get_env("SUKHI_INTAKE_FILE") do
      path when is_binary(path) and path != "" -> path
      _ -> @default_file
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  # The memory is the authority; the marker follows it. A marker that cannot
  # be written (no volume in dev, a read-only disk) must not stop the door
  # from shutting, so the failure is logged and the caller reads it back with
  # `marker_status/0`.
  defp commit(status) do
    :persistent_term.put(@key, status)

    case write_marker(status) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("intake marker not written: #{inspect(reason)}")
    end

    status
  end

  @doc "Write the marker for `status`: `:ok`, or `{:error, reason}`."
  @spec write_marker(t()) :: :ok | {:error, term()}
  def write_marker(status \\ status()) do
    path = marker_path()
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, JSON.encode!(marker(status)) <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  @doc "Does the marker on disk say what memory says? For the operator's `status`."
  @spec marker_status() :: :ok | {:error, term()}
  def marker_status do
    with {:ok, body} <- File.read(marker_path()),
         {:ok, %{"state" => on_disk}} <- JSON.decode(body),
         true <- on_disk == Atom.to_string(status().state) do
      :ok
    else
      false -> {:error, :stale}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unreadable}
    end
  end

  defp reason(nil, %{reason: kept}), do: kept
  defp reason(nil, _), do: "maintenance"
  defp reason(given, base) when is_atom(given), do: reason(Atom.to_string(given), base)
  defp reason(given, _) when is_binary(given) and given != "", do: String.slice(given, 0, 40)
  defp reason(_empty, base), do: reason(nil, base)

  defp retry(given, _) when is_integer(given) and given > 0, do: given
  defp retry(nil, %{retry_after_s: kept}), do: kept
  defp retry(nil, _), do: @default_retry_after_s

  defp put_given(map, key, opts) do
    if Keyword.has_key?(opts, key), do: Map.put(map, key, Keyword.fetch!(opts, key)), else: map
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
