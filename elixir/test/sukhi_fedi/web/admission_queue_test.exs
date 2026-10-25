# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.AdmissionQueueTest do
  # Not async: it lowers the app-wide cap and shares the queue's tables.
  use ExUnit.Case, async: false
  import Plug.Test

  alias SukhiFedi.Web.AdmissionQueue

  setup do
    prev = Application.get_env(:sukhi_fedi, :admission_max)
    Application.put_env(:sukhi_fedi, :admission_max, 2)
    Application.put_env(:sukhi_fedi, :admission_hold_ms, 0)
    # Tables are made lazily by whoever asks first; keep them alive and empty.
    owner = spawn(fn -> Process.sleep(:infinity) end)
    for t <- [:admission, :admission_bg, :admission_flight], :ets.whereis(t) != :undefined, do: :ets.delete(t)

    for {name, opts} <- [{:admission, [:set]}, {:admission_bg, [:set]}, {:admission_flight, [:set]}] do
      :ets.give_away(:ets.new(name, [:named_table, :public] ++ opts), owner, nil)
    end

    on_exit(fn ->
      Process.exit(owner, :kill)
      Application.delete_env(:sukhi_fedi, :admission_hold_ms)
      if prev, do: Application.put_env(:sukhi_fedi, :admission_max, prev),
        else: Application.delete_env(:sukhi_fedi, :admission_max)
    end)

    :ok
  end

  defp background, do: Plug.Conn.put_req_header(plain(), "x-sukhi-purpose", "background")
  defp plain, do: conn(:get, "/api/v1/timelines/public")
  defp with_ticket(t), do: Plug.Conn.put_req_header(plain(), "x-queue-ticket", Integer.to_string(t))

  # A request that is running: admitted in its own process, held until told.
  defp running do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:admitted, self(), AdmissionQueue.admit(plain())})
        receive do: (:done -> :ok)
      end)

    assert_receive {:admitted, ^pid, :ok}
    pid
  end

  defp finish(pid) do
    send(pid, :done)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    # a request that ends gives its slot back (leave/1); a dead one is swept
    :ok
  end

  test "runs up to the cap, then hands out ticket 1 with its place" do
    running()
    running()
    assert {:wait, 1, 1, ms} = AdmissionQueue.admit(plain())
    assert ms >= 50
    assert {:wait, 2, 2, _} = AdmissionQueue.admit(plain())
  end

  test "a late arrival does not jump a line, even if a slot is free" do
    a = running()
    b = running()
    assert {:wait, 1, 1, _} = AdmissionQueue.admit(plain())
    finish(a)
    # one slot free now, but ticket 1 is waiting for it
    assert {:wait, 2, 2, _} = AdmissionQueue.admit(plain())
    finish(b)
  end

  test "tickets are served in order, one slot at a time" do
    a = running()
    b = running()
    {:wait, t1, _, _} = AdmissionQueue.admit(plain())
    {:wait, t2, _, _} = AdmissionQueue.admit(plain())
    finish(a)
    finish(b)

    # two slots free: first in line takes one, and the second is next
    assert AdmissionQueue.admit(with_ticket(t1)) == :ok
    assert AdmissionQueue.admit(with_ticket(t2)) == :ok
  end

  test "a ticket whose turn has not come keeps its place, and waits again" do
    running()
    b = running()
    {:wait, t1, _, _} = AdmissionQueue.admit(plain())
    {:wait, t2, _, _} = AdmissionQueue.admit(plain())
    finish(b)

    # one slot free: ticket 2 is second in line, so it waits; ticket 1 goes
    assert {:wait, ^t2, 2, _} = AdmissionQueue.admit(with_ticket(t2))
    assert AdmissionQueue.admit(with_ticket(t1)) == :ok
  end

  test "a ticket is used once" do
    a = running()
    b = running()
    {:wait, t1, _, _} = AdmissionQueue.admit(plain())
    finish(a)
    finish(b)
    assert AdmissionQueue.admit(with_ticket(t1)) == :ok
    # the same number again is no ticket at all: it queues like anyone, here
    # straight in because the line is empty and a slot is free
    assert AdmissionQueue.admit(with_ticket(t1)) == :ok
  end

  test "ticket_due? is false before the told time and true after" do
    running()
    running()
    {:wait, t1, _, _} = AdmissionQueue.admit(plain())
    refute AdmissionQueue.ticket_due?(with_ticket(t1))

    [{^t1, _not_before, exp}] = :ets.lookup(:admission, t1)
    :ets.insert(:admission, {t1, System.system_time(:millisecond) - 1, exp})
    assert AdmissionQueue.ticket_due?(with_ticket(t1))
    refute AdmissionQueue.ticket_due?(with_ticket(t1 + 100))
    refute AdmissionQueue.ticket_due?(plain())
  end

  test "an expired ticket is nothing" do
    running()
    running()
    {:wait, t1, _, _} = AdmissionQueue.admit(plain())
    :ets.insert(:admission, {t1, 0, 1})
    refute AdmissionQueue.ticket_due?(with_ticket(t1))
    # and it no longer holds a place in line
    assert {:wait, _t2, 1, _} = AdmissionQueue.admit(plain())
  end

  test "a full line answers without a ticket" do
    prev = Application.get_env(:sukhi_fedi, :admission_queue_max)
    Application.put_env(:sukhi_fedi, :admission_queue_max, 1)
    on_exit(fn -> Application.put_env(:sukhi_fedi, :admission_queue_max, prev || 500) end)

    running()
    running()
    assert {:wait, _, 1, _} = AdmissionQueue.admit(plain())
    assert {:full, secs} = AdmissionQueue.admit(plain())
    assert secs >= 5
  end

  test "a request waits a moment for a slot before it is sent away" do
    Application.put_env(:sukhi_fedi, :admission_hold_ms, 500)
    a = running()
    running()
    spawn(fn -> Process.sleep(60) && send(a, :done) end)
    # a's slot is swept as dead within the hold, and this request takes it
    assert AdmissionQueue.admit(plain()) == :ok
  end

  test "a ticket holder takes its slot the moment one is free, within the hold" do
    a = running()
    running()
    {:wait, t1, _, _} = AdmissionQueue.admit(plain())
    Application.put_env(:sukhi_fedi, :admission_hold_ms, 500)
    spawn(fn -> Process.sleep(60) && send(a, :done) end)
    assert AdmissionQueue.admit(with_ticket(t1)) == :ok
  end

  test "a place that would take too long is refused up front, with how long to stay away" do
    running()
    running()
    # a request takes 10 s here, two at a time: place 4 would wait 20 s
    :ets.insert(:admission, {:ewma, 10_000.0})
    assert {:wait, _, 1, _} = AdmissionQueue.admit(plain())
    assert {:wait, _, 2, _} = AdmissionQueue.admit(plain())
    assert {:wait, _, 3, _} = AdmissionQueue.admit(plain())
    assert {:full, secs} = AdmissionQueue.admit(plain())
    assert secs >= 20
  end

  test "the refusal says how long to stay away and asks the client to slow down" do
    c = AdmissionQueue.respond_full(plain(), 12)
    assert c.status == 503
    assert Plug.Conn.get_resp_header(c, "retry-after") == ["12"]
    assert Plug.Conn.get_resp_header(c, "x-slow-down") == ["12"]
    assert %{"error" => "busy", "retry_after" => 12} = JSON.decode!(c.resp_body)
  end

  test "the queued 503 carries the ticket in the header and the place in the body" do
    c = AdmissionQueue.respond_wait(plain(), 7, 3, 1_400)
    assert c.status == 503 and c.halted
    assert Plug.Conn.get_resp_header(c, "x-queue-ticket") == ["7"]
    assert Plug.Conn.get_resp_header(c, "retry-after") == ["2"]

    assert %{
             "error" => "queued",
             "queue" => %{"ticket" => 7, "position" => 3},
             "retry_after_ms" => 1400,
             "retry_after" => 2
           } = JSON.decode!(c.resp_body)
  end

  test "a program that can wait is told to wait longer than a person is" do
    running()
    running()
    :ets.insert(:admission, {:ewma, 10_000.0})
    :ets.insert(:admission_bg, {:ewma, 10_000.0})
    # a person is turned away once the wait passes their patience ...
    for _ <- 1..3, do: assert({:wait, _, _, _} = AdmissionQueue.admit(plain()))
    assert {:full, _} = AdmissionQueue.admit(plain())
    # ... a background caller still gets a place, behind every person
    assert {:wait, _, 4, _} = AdmissionQueue.admit(background())
  end

  test "background requests are not held waiting for a slot" do
    Application.put_env(:sukhi_fedi, :admission_hold_ms, 500)
    running()
    running()
    t0 = System.monotonic_time(:millisecond)
    assert {:wait, _, _, _} = AdmissionQueue.admit(background())
    assert System.monotonic_time(:millisecond) - t0 < 200
  end

  test "a background ticket is only due in the background line" do
    running()
    running()
    {:wait, t, _, _} = AdmissionQueue.admit(background())
    bg = Plug.Conn.put_req_header(background(), "x-queue-ticket", Integer.to_string(t))
    :ets.insert(:admission_bg, {t, 0, System.system_time(:second) + 30})
    assert AdmissionQueue.ticket_due?(bg)
  end
end
