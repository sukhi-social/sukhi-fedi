# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate.GateTest do
  use ExUnit.Case, async: false

  alias SukhiFedi.Translate.Gate

  setup_all do
    {:ok, _} = Application.ensure_all_started(:hammer)
    if Process.whereis(SukhiFedi.Cache.Ets) == nil, do: start_supervised!(SukhiFedi.Cache.Ets)
    :ok
  end

  setup do
    prev = Application.get_env(:sukhi_fedi, :translate_max_flight)
    Application.put_env(:sukhi_fedi, :translate_max_flight, 1)

    on_exit(fn ->
      if prev == nil, do: Application.delete_env(:sukhi_fedi, :translate_max_flight), else: Application.put_env(:sukhi_fedi, :translate_max_flight, prev)
    end)

    id = System.unique_integer([:positive])
    {:ok, id: id}
  end

  test "runs the function and returns what it returned", %{id: id} do
    assert {:ok, :done} = Gate.run(id, :libre, fn -> {:ok, :done} end)
    assert {:error, :nope} = Gate.run(id, :deepl, fn -> {:error, :nope} end)
  end

  test "one account gets 60 an hour, then is told how long to wait", %{id: id} do
    for _ <- 1..60, do: assert({:ok, 1} = Gate.run(id, :deepl, fn -> {:ok, 1} end))
    assert {:error, {:busy, seconds}} = Gate.run(id, :deepl, fn -> flunk("ran past the limit") end)
    assert seconds >= 1

    other = id + 1
    assert {:ok, 1} = Gate.run(other, :deepl, fn -> {:ok, 1} end)
  end

  test "the hosted translator runs only max_flight at once; a full one answers busy", %{id: id} do
    parent = self()

    holder =
      Task.async(fn ->
        Gate.run(id, :libre, fn ->
          send(parent, :holding)

          receive do
            :release -> {:ok, :held}
          end
        end)
      end)

    assert_receive :holding

    assert {:error, {:busy, 10}} = Gate.run(id + 1, :libre, fn -> flunk("ran while full") end)
    # A person's own DeepL key does not use the server's translator.
    assert {:ok, :own} = Gate.run(id + 2, :deepl, fn -> {:ok, :own} end)

    send(holder.pid, :release)
    assert {:ok, :held} = Task.await(holder)

    assert {:ok, :again} = Gate.run(id + 3, :libre, fn -> {:ok, :again} end)
  end

  test "a request that dies frees its place", %{id: id} do
    parent = self()

    pid =
      spawn(fn ->
        Gate.run(id, :libre, fn ->
          send(parent, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding
    Process.exit(pid, :kill)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}

    assert {:ok, :free} = Gate.run(id + 1, :libre, fn -> {:ok, :free} end)
  end

  test "an exception releases the place", %{id: id} do
    assert_raise RuntimeError, fn -> Gate.run(id, :libre, fn -> raise "boom" end) end
    assert {:ok, :free} = Gate.run(id + 1, :libre, fn -> {:ok, :free} end)
  end

  test "auto has its own allowance, apart from the presses", %{id: id} do
    for _ <- 1..120, do: assert({:ok, 1} = Gate.run(id, :deepl, fn -> {:ok, 1} end, auto: true))
    assert {:error, {:busy, s}} = Gate.run(id, :deepl, fn -> flunk("ran past the auto limit") end, auto: true)
    assert s >= 1

    # The hand-pressed allowance is untouched by all of that.
    assert {:ok, :pressed} = Gate.run(id, :deepl, fn -> {:ok, :pressed} end)
  end

  test "auto leaves one place on the hosted translator for a press", %{id: id} do
    Application.put_env(:sukhi_fedi, :translate_max_flight, 2)
    parent = self()

    holder =
      Task.async(fn ->
        Gate.run(id, :libre, fn ->
          send(parent, :holding)

          receive do
            :release -> {:ok, :held}
          end
        end)
      end)

    assert_receive :holding

    # One place is taken: auto may not take the last one …
    assert {:error, {:busy, 10}} = Gate.run(id + 1, :libre, fn -> flunk("auto took the last place") end, auto: true)
    # … but a person's press may.
    assert {:ok, :pressed} = Gate.run(id + 2, :libre, fn -> {:ok, :pressed} end)

    send(holder.pid, :release)
    assert {:ok, :held} = Task.await(holder)
    # With nothing running, auto has the one place it is allowed.
    assert {:ok, :auto} = Gate.run(id + 3, :libre, fn -> {:ok, :auto} end, auto: true)
  end

  test "with a single place, auto never runs on the hosted translator", %{id: id} do
    assert {:error, {:busy, 10}} = Gate.run(id, :libre, fn -> flunk("auto ran with one place") end, auto: true)
    assert {:ok, :own} = Gate.run(id + 1, :deepl, fn -> {:ok, :own} end, auto: true)
  end
end
