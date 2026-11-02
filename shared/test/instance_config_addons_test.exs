# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.InstanceConfigAddonsTest do
  use ExUnit.Case, async: true

  alias SukhiShared.InstanceConfig

  test "nodeinfo monitor is opt-in in the instance config" do
    refute InstanceConfig.addon_enabled?(%{}, "nodeinfo_monitor")

    refute InstanceConfig.addon_enabled?(
             %{"addons" => %{"nodeinfo_monitor" => false}},
             "nodeinfo_monitor"
           )

    assert InstanceConfig.addon_enabled?(
             %{"addons" => %{"nodeinfo_monitor" => true}},
             "nodeinfo_monitor"
           )
  end

  test "an empty frontend route set is the setup state" do
    refute InstanceConfig.frontend_configured?(%{"routes" => []})

    assert InstanceConfig.frontend_configured?(%{
             "routes" => [%{"pattern" => "/**", "frontend" => "relay"}]
           })
  end

  test "an unauthenticated redirect is optional and exposed as configured" do
    assert InstanceConfig.unauthenticated_redirect(%{}) == nil

    assert InstanceConfig.unauthenticated_redirect(%{
             "unauthenticated_redirect" => "https://about.sukhi.social"
           }) == "https://about.sukhi.social"
  end
end
