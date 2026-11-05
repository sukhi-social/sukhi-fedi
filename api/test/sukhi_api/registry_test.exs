# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.RegistryTest do
  use ExUnit.Case, async: false

  alias SukhiApi.Registry

  setup do
    prev_enabled = Application.get_env(:sukhi_api, :enabled_addons)
    prev_disabled = Application.get_env(:sukhi_api, :disabled_addons)
    prev_caps = Application.get_env(:sukhi_api, :enabled_capabilities)
    prev_nodeinfo = Application.get_env(:sukhi_api, :nodeinfo_monitor_configured)

    on_exit(fn ->
      restore(:enabled_addons, prev_enabled)
      restore(:disabled_addons, prev_disabled)
      restore(:enabled_capabilities, prev_caps)
      restore(:nodeinfo_monitor_configured, prev_nodeinfo)
    end)

    :ok
  end

  test "all addons enabled: both mastodon_api and nodeinfo_monitor capabilities appear" do
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :disabled_addons, [])
    Application.delete_env(:sukhi_api, :enabled_capabilities)
    Application.put_env(:sukhi_api, :nodeinfo_monitor_configured, true)

    caps = Registry.capabilities()
    assert SukhiApi.Capabilities.MastodonInstance in caps
    assert SukhiApi.Capabilities.NodeinfoMonitor in caps
    assert SukhiApi.Capabilities.OAuthApps in caps
    assert SukhiApi.Capabilities.OAuth in caps
    assert SukhiApi.Capabilities.MastodonAccounts in caps
  end

  test "enabling only :mastodon_api hides the nodeinfo_monitor capability" do
    Application.put_env(:sukhi_api, :enabled_addons, [:mastodon_api])
    Application.put_env(:sukhi_api, :disabled_addons, [])
    Application.delete_env(:sukhi_api, :enabled_capabilities)

    caps = Registry.capabilities()
    assert SukhiApi.Capabilities.MastodonInstance in caps
    assert SukhiApi.Capabilities.OAuthApps in caps
    assert SukhiApi.Capabilities.OAuth in caps
    assert SukhiApi.Capabilities.MastodonAccounts in caps
    refute SukhiApi.Capabilities.NodeinfoMonitor in caps
  end

  test "disabling :mastodon_api via deny-list hides its capabilities" do
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :disabled_addons, [:mastodon_api])
    Application.delete_env(:sukhi_api, :enabled_capabilities)
    Application.put_env(:sukhi_api, :nodeinfo_monitor_configured, true)

    caps = Registry.capabilities()
    refute SukhiApi.Capabilities.MastodonInstance in caps
    refute SukhiApi.Capabilities.OAuthApps in caps
    refute SukhiApi.Capabilities.OAuth in caps
    refute SukhiApi.Capabilities.MastodonAccounts in caps
    assert SukhiApi.Capabilities.NodeinfoMonitor in caps
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, value), do: Application.put_env(:sukhi_api, key, value)
end
