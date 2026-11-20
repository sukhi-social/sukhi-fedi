# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.ReleaseTest do
  use ExUnit.Case, async: false

  @moduletag :dtlv

  alias SukhiFedi.Release

  # The one-shot data fixes live as files under priv/scripts and run through
  # run_script/2. These checks need no DB: the script set, that each parses,
  # and that the name is vetted before it touches the filesystem.
  describe "run_script/2" do
    test "the one-shot fixes are all there, and every one parses" do
      assert Release.scripts() ==
               ~w(backfill_followed_outboxes backfill_monitored_instances
                  broadcast_actor_update delete_all_watcher_notes
                  publish_initial_notes_for_backfill resync_default_watcher_summary)

      for name <- Release.scripts() do
        path = Application.app_dir(:sukhi_fedi, "priv/scripts/#{name}.exs")
        assert {:ok, _} = path |> File.read!() |> Code.string_to_quoted(file: path), name
      end
    end

    test "refuses names that are not plain script names" do
      for bad <- ["../mix", "a/b", "", "Upper", "x.exs"] do
        assert_raise ArgumentError, ~r/bad script name/, fn -> Release.run_script(bad) end
      end
    end

    test "an unknown script says what is available" do
      assert_raise ArgumentError, ~r/no such script.*backfill_followed_outboxes/s, fn ->
        Release.run_script("nope")
      end
    end
  end

  describe "migrate_all/0" do
    setup do
      prev_datalevin = Application.get_env(:sukhi_fedi, :datalevin)

      dir =
        Path.join(
          System.tmp_dir!(),
          "sukhi-datalevin-release-test-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:sukhi_fedi, :datalevin, dir: dir)

      on_exit(fn ->
        if prev_datalevin,
          do: Application.put_env(:sukhi_fedi, :datalevin, prev_datalevin),
          else: Application.delete_env(:sukhi_fedi, :datalevin)

        File.rm_rf!(dir)
      end)

      %{datalevin_dir: dir}
    end

    test "opens a new store and runs what it has to run" do
      assert :ok = Release.migrate_all()
    end
  end
end
