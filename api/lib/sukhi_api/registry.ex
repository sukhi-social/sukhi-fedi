# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Registry do
  @moduledoc """
  Discovers modules that `use SukhiApi.Capability` within the
  `:sukhi_api` application. Filtered by:

    * `:enabled_capabilities` — `:all` (default) or a module allowlist
    * `:enabled_addons` — `:all` (default) or a list of addon ids; a
      capability bound via `use SukhiApi.Capability, addon: :id` is
      kept only when its id is in the list. Capabilities declared
      without `:addon` are treated as core and always active.
    * `:disabled_addons` — ids to always exclude (deny-list)
  """

  @spec capabilities() :: [module()]
  def capabilities do
    case :application.get_key(:sukhi_api, :modules) do
      {:ok, modules} ->
        modules
        |> Enum.filter(&capability?/1)
        |> filter_enabled()
        |> filter_by_addon()

      _ ->
        []
    end
  end

  # `routes/0` is asked for on every request (the router scans it for a
  # match). Finding the capabilities and calling each `routes/0` is the same
  # answer every time, so it is kept in :persistent_term, valid for the three
  # settings that decide it; change one and it is rebuilt. The module set is
  # the app's own (from the .app manifest), fixed for a release.
  @cache {__MODULE__, :routes}

  @spec routes() :: [SukhiApi.Capability.route()]
  def routes do
    key = {
      Application.get_env(:sukhi_api, :enabled_capabilities, :all),
      Application.get_env(:sukhi_api, :enabled_addons, :all),
      Application.get_env(:sukhi_api, :disabled_addons, [])
    }

    case :persistent_term.get(@cache, nil) do
      {^key, routes} ->
        routes

      _ ->
        routes = Enum.flat_map(capabilities(), & &1.routes())
        :persistent_term.put(@cache, {key, routes})
        routes
    end
  end

  defp capability?(mod) do
    try do
      Keyword.has_key?(mod.module_info(:attributes), :sukhi_api_capability)
    rescue
      _ -> false
    end
  end

  defp filter_enabled(mods) do
    case Application.get_env(:sukhi_api, :enabled_capabilities, :all) do
      :all -> mods
      list when is_list(list) -> Enum.filter(mods, &(&1 in list))
    end
  end

  defp filter_by_addon(mods) do
    enabled = Application.get_env(:sukhi_api, :enabled_addons, :all)
    disabled = Application.get_env(:sukhi_api, :disabled_addons, [])

    Enum.filter(mods, fn mod ->
      case addon_id(mod) do
        nil ->
          true

        id ->
          cond do
            id in disabled -> false
            enabled == :all -> true
            is_list(enabled) -> id in enabled
            true -> true
          end
      end
    end)
  end

  defp addon_id(mod) do
    mod.module_info(:attributes)
    |> Keyword.get(:sukhi_api_capability_addon, [nil])
    |> List.first()
  rescue
    _ -> nil
  end
end
