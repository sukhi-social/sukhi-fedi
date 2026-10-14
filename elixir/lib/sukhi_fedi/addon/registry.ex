# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addon.Registry do
  @moduledoc """
  Discovers modules that `use SukhiFedi.Addon` within the `:sukhi_fedi`
  application, filtered by config:

    * `:enabled_addons` — `:all` (default) or a list of addon ids
    * `:disabled_addons` — list of ids to always exclude (deny-list)

  Both are populated from `ENABLED_ADDONS` / `DISABLE_ADDONS` env vars
  in `runtime.exs`.
  """

  @abi_major "1"

  # Finding the addons walks every loaded module (thousands) and asks each
  # for its attributes. `enabled?/1` sits on request paths, so the answer is
  # kept in :persistent_term, valid for the enable/disable config it was
  # computed under; changing either setting recomputes it (that is what the
  # addon tests do). Modules loaded later under unchanged config are not
  # noticed: in a release the set is fixed at boot.
  @cache {__MODULE__, :all}

  @spec all() :: [module()]
  def all do
    key = {
      Application.get_env(:sukhi_fedi, :enabled_addons, :all),
      Application.get_env(:sukhi_fedi, :disabled_addons, [])
    }

    case :persistent_term.get(@cache, nil) do
      {^key, mods} ->
        mods

      _ ->
        mods = discover()
        :persistent_term.put(@cache, {key, mods})
        mods
    end
  end

  defp discover do
    candidates()
    |> Enum.filter(&addon?/1)
    |> filter_enabled()
    |> filter_disabled()
  end

  # Union of `:sukhi_fedi` app modules (from the .app manifest — may not be
  # loaded yet, e.g. during `Release.migrate_all/0`) and already-loaded
  # modules (catches test-defined addons that aren't in the main app).
  defp candidates do
    app_mods =
      case :application.get_key(:sukhi_fedi, :modules) do
        {:ok, mods} -> mods
        _ -> []
      end

    Enum.each(app_mods, &Code.ensure_loaded/1)

    loaded = for {m, _} <- :code.all_loaded(), do: m

    Enum.uniq(app_mods ++ loaded)
  end

  @doc """
  Whether the addon with the given id is active under the current
  enable/disable config. Lets request-time route gating (e.g. the
  streaming WS endpoint) mirror what actually booted.
  """
  @spec enabled?(SukhiFedi.Addon.id()) :: boolean()
  def enabled?(id), do: Enum.any?(all(), &(&1.id() == id))

  @spec children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children, do: Enum.flat_map(all(), & &1.supervision_children())

  @spec nats_subscriptions() :: [SukhiFedi.Addon.nats_sub()]
  def nats_subscriptions, do: Enum.flat_map(all(), & &1.nats_subscriptions())

  @spec migrations_paths() :: [Path.t()]
  def migrations_paths do
    all()
    |> Enum.map(& &1.migrations_path())
    |> Enum.reject(&is_nil/1)
  end

  @spec verify_abi!() :: :ok
  def verify_abi! do
    for addon <- all() do
      version = addon.abi_version()
      [major | _] = String.split(version, ".")

      if major != @abi_major do
        raise """
        addon #{inspect(addon.id())} declares ABI #{version}; \
        core is #{@abi_major}.x — refusing to start.
        """
      end
    end

    :ok
  end

  defp addon?(mod) do
    try do
      Keyword.has_key?(mod.module_info(:attributes), :sukhi_fedi_addon)
    rescue
      _ -> false
    end
  end

  defp filter_enabled(mods) do
    case Application.get_env(:sukhi_fedi, :enabled_addons, :all) do
      :all -> mods
      list when is_list(list) -> Enum.filter(mods, &(&1.id() in list))
    end
  end

  defp filter_disabled(mods) do
    case Application.get_env(:sukhi_fedi, :disabled_addons, []) do
      [] -> mods
      list when is_list(list) -> Enum.reject(mods, &(&1.id() in list))
    end
  end
end
