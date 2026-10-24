# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.PullFederation.UnitsTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.PullFederation.{Gate, Notify, Puller, Serve}

  describe "Notify.parse/1" do
    defp note(heads),
      do: %{"type" => "PullNotification", "origin" => "A.example", "heads" => heads}

    test "accepts heads that live on the origin, lower-casing it" do
      assert {:ok, "a.example", [{"https://a.example/users/x", 3}]} =
               Notify.parse(note(%{"https://a.example/users/x" => 3}))
    end

    test "an origin cannot speak for another host's actors" do
      assert {:error, :bad_shape} = Notify.parse(note(%{"https://evil.example/users/x" => 1}))
    end

    test "rejects wrong type, empty, oversized, non-https and non-positive heads" do
      assert {:error, :bad_shape} =
               Notify.parse(%{"type" => "Create", "origin" => "a.example", "heads" => %{}})

      assert {:error, :bad_shape} = Notify.parse(note(%{}))
      assert {:error, :bad_shape} = Notify.parse(note(%{"http://a.example/users/x" => 1}))
      assert {:error, :bad_shape} = Notify.parse(note(%{"https://a.example/users/x" => 0}))
      assert {:error, :bad_shape} = Notify.parse(note(%{"https://a.example/users/x" => "7"}))
      assert {:error, :bad_shape} = Notify.parse(note(%{"https://a.example/users/x" => 1.5}))
      assert {:error, :bad_shape} = Notify.parse(nil)

      many = for i <- 1..1001, into: %{}, do: {"https://a.example/users/u#{i}", 1}
      assert {:error, :bad_shape} = Notify.parse(note(many))
    end

    test "one bad entry rejects the whole notification" do
      assert {:error, :bad_shape} =
               Notify.parse(
                 note(%{"https://a.example/users/ok" => 1, "https://a.example/users/bad" => -1})
               )
    end
  end

  describe "Serve.parse_cursors/1" do
    test "reads repeated c / c[] entries and skips what does not parse" do
      qs =
        URI.encode_query([
          {"c[]", "0@https://o.example/users/a"},
          {"c[]", "12@https://o.example/users/b"},
          {"c[]", "junk"},
          {"c[]", "-1@https://o.example/users/c"},
          {"c[]", "5@http://o.example/users/d"},
          {"c", "7@https://o.example/users/e"},
          {"c[]", "9@https://o.example/users/a"}
        ])

      assert Serve.parse_cursors(qs) == [
               {"https://o.example/users/a", 0},
               {"https://o.example/users/b", 12},
               {"https://o.example/users/e", 7}
             ]
    end

    test "is capped" do
      qs = URI.encode_query(for i <- 1..200, do: {"c[]", "1@https://o.example/users/u#{i}"})
      assert length(Serve.parse_cursors(qs)) == 64
    end
  end

  describe "Gate.with_slot/1" do
    test "admits up to max, refuses the next with a retry hint, and releases slots" do
      Application.put_env(:sukhi_fedi, :pull_federation, max_streams: 2)
      on_exit(fn -> Application.delete_env(:sukhi_fedi, :pull_federation) end)
      Gate.init()
      test = self()

      holder = fn tag ->
        spawn_link(fn ->
          Gate.with_slot(fn ->
            send(test, {:in, tag})
            receive do: (:release -> :ok)
          end)
        end)
      end

      a = holder.(:a)
      b = holder.(:b)
      assert_receive {:in, :a}
      assert_receive {:in, :b}

      assert {:busy, secs} = Gate.with_slot(fn -> :never end)
      assert secs in 2..4

      send(a, :release)
      send(b, :release)
      Process.sleep(50)
      assert :ran = Gate.with_slot(fn -> :ran end)
      assert Gate.in_flight() == 0
    end

    test "a crash inside the slot still releases it" do
      Gate.init()
      before = Gate.in_flight()
      assert_raise RuntimeError, fn -> Gate.with_slot(fn -> raise "boom" end) end
      assert Gate.in_flight() == before
    end
  end

  describe "Puller.backoff_ms/1" do
    test "grows, is jittered inside its band, and is capped" do
      for failures <- 1..20 do
        ms = Puller.backoff_ms(failures)
        base = min(1_000 * Integer.pow(2, min(failures, 12)), 3_600_000)
        assert ms >= div(base, 2) and ms <= base
      end

      assert Puller.backoff_ms(40) <= 3_600_000
    end
  end
end
