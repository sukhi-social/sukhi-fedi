# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.IntakeTest do
  # Not async: the state is one switch for the whole BEAM.
  use ExUnit.Case, async: false

  alias SukhiShared.Intake

  setup do
    dir = Path.join(System.tmp_dir!(), "intake-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "intake.json")
    Application.put_env(:sukhi_shared, :intake_file, file)
    Intake.open()

    on_exit(fn ->
      Intake.open()
      Application.delete_env(:sukhi_shared, :intake_file)
      File.rm_rf!(dir)
    end)

    {:ok, marker_path: file}
  end

  defp marker(path), do: path |> File.read!() |> JSON.decode!()

  test "an untouched server is open" do
    assert Intake.open?()
    refute Intake.closed?()
    assert %{state: :open} = Intake.status()
  end

  test "close shuts the door and says why, open undoes it" do
    assert %{state: :closed, reason: "backup"} = Intake.close(reason: :backup)
    assert Intake.closed?()
    refute Intake.open?()

    assert %{state: :open} = Intake.open()
    refute Intake.closed?()
  end

  test "closing again keeps the first `since` and what was learnt" do
    first = Intake.close(reason: "maintenance")
    Intake.note(:settled_at, ~U[2026-11-05 10:00:00Z])

    again = Intake.close(reason: "update", retry_after_s: 90)

    assert again.since == first.since
    assert again.reason == "update"
    assert again.retry_after_s == 90
    assert again.settled_at == ~U[2026-11-05 10:00:00Z]
  end

  test "a close with no reason keeps the one it had; the default is `maintenance`" do
    assert %{reason: "maintenance"} = Intake.close()
    Intake.close(reason: "backup")
    assert %{reason: "backup"} = Intake.close()
  end

  test "retry_after_s: the default, then what the operator said" do
    assert Intake.retry_after_s() == 300
    Intake.close(retry_after_s: 45)
    assert Intake.retry_after_s() == 45
  end

  test "note is ignored while open: a backup note on an open server would be a lie" do
    assert %{state: :open} = Intake.note(:backup, %{dir: "/x", at: ~U[2026-11-05 10:00:00Z]})
    assert %{state: :open} = Intake.status()
    refute Map.has_key?(Intake.status(), :backup)
  end

  test "the marker follows every change", %{marker_path: path} do
    Intake.close(reason: "backup", until: ~U[2026-11-05 12:00:00Z])

    assert %{"state" => "closed", "reason" => "backup", "until" => "2026-11-05T12:00:00Z"} =
             marker(path)

    Intake.note(:backup, %{
      dir: "/var/lib/sukhi/backups/20261105T100000Z",
      at: ~U[2026-11-05 10:00:00Z]
    })

    assert %{"backup" => %{"dir" => "/var/lib/sukhi/backups/20261105T100000Z"}} = marker(path)

    Intake.open()
    assert %{"state" => "open"} = marker(path)
    assert Intake.marker_status() == :ok
  end

  test "the public view carries no path, no count, no backup" do
    Intake.close(reason: "update")
    Intake.note(:backup, %{dir: "/secret/place", at: ~U[2026-11-05 10:00:00Z]})

    public = Intake.public(Intake.status())

    assert Map.keys(public) |> Enum.sort() == [:reason, :retry_after_s, :since, :state, :until]
    refute inspect(public) =~ "secret"
  end

  test "boot overwrites a marker left closed by the shutdown before it", %{marker_path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"state":"closed"}))

    # a fresh BEAM has no state at all
    :persistent_term.erase({Intake, :state})
    assert Intake.marker_status() == {:error, :stale}

    assert %{state: :open} = Intake.boot()
    assert %{"state" => "open"} = marker(path)
  end

  test "a marker that cannot be written does not stop the door from shutting" do
    Application.put_env(:sukhi_shared, :intake_file, "/proc/sukhi/does/not/exist/intake.json")

    assert %{state: :closed} = Intake.close()
    assert Intake.closed?()
    assert {:error, _} = Intake.write_marker()
  end
end
