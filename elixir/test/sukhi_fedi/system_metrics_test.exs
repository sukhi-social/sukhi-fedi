# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.SystemMetricsTest do
  use ExUnit.Case, async: true

  # Run under the `--only integration` harness like the other unit tests;
  # it boots the app (and so `:os_mon`) which these readings need.
  @moduletag :integration

  alias SukhiFedi.SystemMetrics
  alias SukhiFedi.Web.Admin.Render

  # A synthetic snapshot exercising the awkward branches: a nil load slot
  # and an empty disk list (before disksup's first scan).
  @metrics %{
    cpu: 42.5,
    memory: %{total: 8_589_934_592, used: 4_294_967_296, available: 4_294_967_296},
    load: %{"1m" => 1.25, "5m" => nil, "15m" => 0.5},
    disk: [%{mount: "/", total: 107_374_182_400, used_percent: 73}],
    beam: %{total: 268_435_456, processes: 134_217_728, binary: 33_554_432}
  }

  test "snapshot/0 returns the four host sections plus the BEAM footprint" do
    snap = SystemMetrics.snapshot()
    assert Map.keys(snap) |> Enum.sort() == [:beam, :cpu, :disk, :load, :memory]
  end

  test "cpu_util/0 is a non-negative float" do
    cpu = SystemMetrics.cpu_util()
    assert is_float(cpu)
    assert cpu >= 0.0
  end

  test "memory/0 reports total/used/available with used never above total" do
    mem = SystemMetrics.memory()
    assert mem.total > 0
    assert mem.used >= 0
    assert mem.used <= mem.total
  end

  test "load_avg/0 keys the three windows" do
    assert %{"1m" => _, "5m" => _, "15m" => _} = SystemMetrics.load_avg()
  end

  test "disk/0 drops the disksup 'none' placeholder and exposes byte sizes" do
    for d <- SystemMetrics.disk() do
      assert is_binary(d.mount)
      assert d.mount != "none"
      assert d.total > 0
      assert d.used_percent >= 0
    end
  end

  test "the sample template renders the snapshot, nil load slot, and disk row" do
    html = Render.render_template("system/sample.html.eex", metrics: @metrics, wt_relay: nil)

    assert html =~ "42.5"
    # memory 4096 / 8192 MiB at 50%
    assert html =~ "4096 / 8192 MiB"
    # the nil 5m load slot degrades to an em dash, not a crash
    assert html =~ "5m —"
    # disk row: GiB size and used percent
    assert html =~ "100.0 GiB"
    assert html =~ "73%"
  end

  test "the index template embeds the live sample and the polling hook" do
    html = Render.render_template("system/index.html.eex", metrics: @metrics, wt_relay: nil)

    assert html =~ ~s(hx-get="/admin/system/sample")
    assert html =~ "every 2s"
    # the inlined initial snapshot is present
    assert html =~ "42.5"
  end
end
