# SPDX-License-Identifier: AGPL-3.0-or-later
import Config

# Mirror the gateway's addon selection so capability routes disappear
# in lockstep with their owning addon. ADDON_PRESETS is expanded and
# unioned with ENABLED_ADDONS; DISABLE_ADDONS is the deny-list.
presets =
  System.get_env("ADDON_PRESETS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)

# Implicit ENABLED_ADDONS default yields to ADDON_PRESETS; explicit
# "all" still wins. See elixir/config/runtime.exs for the rationale.
enabled_addons =
  case {System.get_env("ENABLED_ADDONS"), presets} do
    {nil, []} ->
      :all

    {nil, ids} ->
      SukhiApi.Addon.Presets.expand(ids)

    {"all", _} ->
      :all

    {"", []} ->
      :all

    {"", ids} ->
      SukhiApi.Addon.Presets.expand(ids)

    {csv, ids} ->
      explicit = csv |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
      Enum.uniq(SukhiApi.Addon.Presets.expand(ids) ++ explicit)
  end

disabled_addons =
  System.get_env("DISABLE_ADDONS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)

config :sukhi_api, :enabled_addons, enabled_addons
config :sukhi_api, :disabled_addons, disabled_addons

# Public-facing domain. fetch_env! in prod so a misconfigured release
# crashes at boot instead of returning localhost:4000 in /api/v1/instance.
if config_env() == :prod do
  config :sukhi_api, :domain, System.fetch_env!("DOMAIN")
else
  config :sukhi_api, :domain, System.get_env("DOMAIN", "localhost:4000")
end

if config_env() == :prod do
  config :sukhi_api, :title, System.get_env("INSTANCE_TITLE", "sukhi-fedi")

  # GATEWAY_NODE overrides the default gateway@elixir node for
  # `SukhiApi.GatewayRpc`.
  case System.get_env("GATEWAY_NODE") do
    nil ->
      :ok

    "" ->
      :ok

    node ->
      config :sukhi_api, :gateway_node, String.to_atom(node)
  end

  # Allowlist of capability modules. If unset (or empty), all compiled
  # capabilities run. Example:
  #   ENABLED_CAPABILITIES=Elixir.SukhiApi.Capabilities.MastodonInstance
  case System.get_env("ENABLED_CAPABILITIES") do
    nil ->
      :ok

    "" ->
      :ok

    list ->
      mods =
        list
        |> String.split(",", trim: true)
        |> Enum.map(&String.to_existing_atom/1)

      config :sukhi_api, :enabled_capabilities, mods
  end
end

# Dev counterpart of the gateway's :plugin_nodes — one BEAM, so the
# gateway this node reaches back into is itself. Overrides the
# `gateway@elixir` default in config.exs.
if config_env() == :dev do
  config :sukhi_api, :gateway_node, node()
end
