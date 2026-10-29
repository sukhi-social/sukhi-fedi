# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.RawStore do
  @moduledoc """
  Where the received original (`raw`) of an actor, object or activity lives.

  FEP-8b32 proof checks and forwarding need the original bytes, and some are
  large. A small original stays on the entity as `<ns>/raw`; a large one goes
  to a blob backend and the entity carries only `<ns>/raw-ref` (a
  content address, `sha256:<hex>`) and `<ns>/raw-size`. Exactly one of the
  two is ever set. **This module is the only place that decides which**
  (`put/2`) and the only place that undoes it (`get/2`); callers never branch.

  Blobs are zstd-compressed and content-addressed, so the same original
  arriving twice (a boost, a forward) is one blob, and `get/2` re-hashes what
  it read: a damaged blob is `{:error, :corrupt}`, not silently accepted.

  Write order is blob first, then the entity: a crash in between leaves an
  unreferenced blob, which `gc/2` removes after a grace period. It never
  leaves a reference to nothing.

  docs/DATALEVIN_SCHEMA.md ("大きい raw のポインタ") has the design.
  """

  alias SukhiFedi.RawStore.Config

  @type ns :: String.t()
  @type attrs :: %{optional(atom()) => term()}

  @zstd_level 9

  @doc """
  The attributes to merge into the entity's transaction for `raw`.

  A small original comes back as `%{"object/raw": raw}`; a large one as
  `%{"object/raw-ref": "sha256:…", "object/raw-size": n}`.
  """
  @spec put(ns(), binary(), Config.t()) :: {:ok, attrs()} | {:error, term()}
  def put(ns, raw, %Config{} = config \\ Config.current())
      when is_binary(ns) and is_binary(raw) do
    size = byte_size(raw)

    if size <= config.inline_max do
      {:ok, %{attr(ns, "raw") => raw}}
    else
      ref = ref(raw)

      with :ok <- config.backend.put(ref, compress(raw), config.backend_opts) do
        {:ok, %{attr(ns, "raw-ref") => ref, attr(ns, "raw-size") => size}}
      end
    end
  end

  @doc "The original of `entity` (a map holding `<ns>/raw` or `<ns>/raw-ref`)."
  @spec get(map(), ns(), Config.t()) :: {:ok, binary()} | {:error, :missing | :corrupt | term()}
  def get(entity, ns, %Config{} = config \\ Config.current()) when is_map(entity) do
    case {Map.fetch(entity, attr(ns, "raw")), Map.fetch(entity, attr(ns, "raw-ref"))} do
      {{:ok, raw}, _} when is_binary(raw) -> {:ok, raw}
      {_, {:ok, ref}} when is_binary(ref) -> fetch_ref(ref, config)
      _ -> {:error, :missing}
    end
  end

  @doc """
  Delete every blob that is older than the grace period and not referenced.
  `referenced` is either an enumerable of refs the store still points at, or
  a one-argument function asking the store about one ref (use it when the set
  is too big to list: the caller's answer must be exact, since a wrong
  "unreferenced" loses an original). Returns how many went.
  """
  @spec gc(Enumerable.t() | (String.t() -> boolean()), Config.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def gc(referenced, %Config{} = config \\ Config.current()) do
    referenced? = referenced_fun(referenced)
    cutoff = System.os_time(:second) - config.grace_s

    with {:ok, candidates} <- config.backend.list_older_than(cutoff, config.backend_opts) do
      doomed = Enum.reject(candidates, referenced?)

      Enum.reduce_while(doomed, {:ok, 0}, fn ref, {:ok, n} ->
        case config.backend.delete(ref, config.backend_opts) do
          :ok -> {:cont, {:ok, n + 1}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp referenced_fun(fun) when is_function(fun, 1), do: fun

  defp referenced_fun(refs) do
    set = MapSet.new(refs)
    &MapSet.member?(set, &1)
  end

  @doc "`sha256:<hex>` of the original bytes."
  @spec ref(binary()) :: String.t()
  def ref(raw), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower)

  defp fetch_ref(ref, config) do
    with {:ok, body} <- config.backend.get(ref, config.backend_opts),
         {:ok, raw} <- decompress(body),
         true <- ref(raw) == ref do
      {:ok, raw}
    else
      false -> {:error, :corrupt}
      {:error, _} = err -> err
    end
  end

  defp compress(raw),
    do: raw |> :zstd.compress(%{compressionLevel: @zstd_level}) |> IO.iodata_to_binary()

  defp decompress(body) do
    {:ok, body |> :zstd.decompress() |> IO.iodata_to_binary()}
  rescue
    _ -> {:error, :corrupt}
  catch
    _, _ -> {:error, :corrupt}
  end

  defp attr(ns, name), do: :"#{ns}/#{name}"
end
