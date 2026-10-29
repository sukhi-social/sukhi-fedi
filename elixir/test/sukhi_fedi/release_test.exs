# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.ReleaseTest do
  use ExUnit.Case, async: true

  # DB-free assertions, but the app boots a Repo at test start, so this is
  # picked up by the `--only integration` runner (same as UrlGuardTest).
  @moduletag :integration

  alias SukhiFedi.Release

  # The fail-fast gate's pure core: given Ecto.Migrator.migrations/2's
  # `[{status, version, name}]`, which pending (`:down`) versions sit below
  # the highest applied (`:up`) one? Driving it directly needs no DB.
  describe "migrations_out_of_order/1" do
    test "clean: all applied, then all pending — nothing out of order" do
      migrations = [
        {:up, 1, "a"},
        {:up, 2, "b"},
        {:down, 3, "c"},
        {:down, 4, "d"}
      ]

      assert Release.migrations_out_of_order(migrations) == []
    end

    test "a pending migration below the highest applied is offending" do
      migrations = [
        {:up, 1, "a"},
        {:down, 2, "b"},
        {:up, 3, "c"}
      ]

      assert Release.migrations_out_of_order(migrations) == [2]
    end

    test "lists every offending version, not just the first" do
      migrations = [
        {:down, 1, "a"},
        {:up, 2, "b"},
        {:down, 3, "c"},
        {:up, 5, "e"}
      ]

      assert Release.migrations_out_of_order(migrations) == [1, 3]
    end

    test "fresh database (nothing applied yet) is never out of order" do
      migrations = [{:down, 1, "a"}, {:down, 2, "b"}]

      assert Release.migrations_out_of_order(migrations) == []
    end

    test "a pending migration above the highest applied is fine" do
      migrations = [{:up, 1, "a"}, {:up, 2, "b"}, {:down, 3, "c"}]

      assert Release.migrations_out_of_order(migrations) == []
    end
  end

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

  describe "on the Datalevin store" do
    setup do
      prev = Application.get_env(:sukhi_fedi, :store)
      Application.put_env(:sukhi_fedi, :store, :datalevin)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:sukhi_fedi, :store, prev),
          else: Application.delete_env(:sukhi_fedi, :store)
      end)
    end

    test "there is nothing to migrate, and the gate has nothing to check" do
      assert :ok = Release.migrate_all()
      assert :ok = Release.check_migration_sanity()
    end
  end
end
