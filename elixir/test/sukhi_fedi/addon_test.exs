# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AddonTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.Addon.Registry

  defmodule DummyAddon do
    use SukhiFedi.Addon, id: :dummy_test_addon

    @impl true
    def supervision_children, do: []
  end

  defmodule AbiMismatchAddon do
    use SukhiFedi.Addon, id: :abi_mismatch_test, abi_version: "99.0"
  end

  setup do
    prev_enabled = Application.get_env(:sukhi_fedi, :enabled_addons)
    prev_disabled = Application.get_env(:sukhi_fedi, :disabled_addons)

    on_exit(fn ->
      restore(:enabled_addons, prev_enabled)
      restore(:disabled_addons, prev_disabled)
    end)

    :ok
  end

  test "allowlist includes the dummy addon" do
    Application.put_env(:sukhi_fedi, :enabled_addons, [:dummy_test_addon])
    Application.put_env(:sukhi_fedi, :disabled_addons, [])

    assert DummyAddon in Registry.all()
  end

  test "denylist excludes the dummy addon even when enabled_addons is :all" do
    Application.put_env(:sukhi_fedi, :enabled_addons, :all)
    Application.put_env(:sukhi_fedi, :disabled_addons, [:dummy_test_addon])

    refute DummyAddon in Registry.all()
  end

  test "abi major mismatch raises at verify_abi!" do
    Application.put_env(:sukhi_fedi, :enabled_addons, [:abi_mismatch_test])
    Application.put_env(:sukhi_fedi, :disabled_addons, [])

    assert_raise RuntimeError, ~r/ABI 99\.0/, fn -> Registry.verify_abi!() end
  end

  test "matching abi does not raise" do
    Application.put_env(:sukhi_fedi, :enabled_addons, [:dummy_test_addon])
    Application.put_env(:sukhi_fedi, :disabled_addons, [])

    assert :ok = Registry.verify_abi!()
  end

  test "nodeinfo_monitor addon is discovered when enabled" do
    Code.ensure_loaded(SukhiFedi.Addons.NodeinfoMonitor)
    Application.put_env(:sukhi_fedi, :enabled_addons, [:nodeinfo_monitor])
    Application.put_env(:sukhi_fedi, :disabled_addons, [])

    assert SukhiFedi.Addons.NodeinfoMonitor in Registry.all()
    assert SukhiFedi.Addons.NodeinfoMonitor.id() == :nodeinfo_monitor
  end

  test "nodeinfo_monitor migrations_path resolves to its addon dir" do
    Code.ensure_loaded(SukhiFedi.Addons.NodeinfoMonitor)
    path = SukhiFedi.Addons.NodeinfoMonitor.migrations_path()

    assert path != nil
    assert String.ends_with?(path, "priv/repo/migrations/addons/nodeinfo_monitor")
    assert File.dir?(path)
  end

  test "Registry.migrations_paths includes enabled addons" do
    Code.ensure_loaded(SukhiFedi.Addons.NodeinfoMonitor)
    Application.put_env(:sukhi_fedi, :enabled_addons, [:nodeinfo_monitor])
    Application.put_env(:sukhi_fedi, :disabled_addons, [])

    paths = Registry.migrations_paths()
    assert Enum.any?(paths, &String.ends_with?(&1, "addons/nodeinfo_monitor"))
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_fedi, key)
  defp restore(key, value), do: Application.put_env(:sukhi_fedi, key, value)

  test "Registry.all/0 is computed once per enable/disable setting, not per call" do
    Application.put_env(:sukhi_fedi, :enabled_addons, :all)
    Application.put_env(:sukhi_fedi, :disabled_addons, [])
    first = Registry.all()
    assert {_key, ^first} = :persistent_term.get({Registry, :all})

    # a changed setting is not answered from the old entry
    Application.put_env(:sukhi_fedi, :enabled_addons, [])
    assert Registry.all() == []
  end
end
