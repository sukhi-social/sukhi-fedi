# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.AdmissionQueue do
  @moduledoc """
  The front door for plugin (`/api/*`) requests: at most `max/0` run at once,
  and the rest wait in line — without holding a connection open.

  A request that finds the node full is not made to wait on a socket. It is
  refused with `503` and a **ticket**: a number in a line, the place it holds
  (`position`), and how long to leave it (`retry_after_ms`). The client sends
  the same request again with the ticket in `x-queue-ticket` when that time
  has passed. Tickets are served in order: a request with a ticket gets in
  when fewer tickets are ahead of it than there are free slots; a request
  *without* one gets in only when nobody is waiting, so a late arrival
  cannot jump the line.

  Everything is in two ETS tables owned by `Cache.Ets`:

    * `:admission` — `{ticket, not_before_ms, expires_s}` per waiting ticket,
      plus `{:next, n}` (the next ticket number) and `{:ewma, ms}` (how long
      a request takes, for the wait estimate). Only the 3-tuples are swept.
    * `:admission_flight` — `{pid}` per request running. A pid, not a
      counter, so a request that dies without cleaning up frees its slot.

  A ticket is single-use and expires `@ticket_ttl_s` seconds after it was last
  seen, so a client that walks away leaves nothing behind. The line is capped
  at `queue_max/0`; past it the answer is a plain 503 with no ticket.

  A ticket whose time has come (`ticket_due?/1`) is also what the global rate
  limiter lets through uncounted: a client polling its place in line at the
  pace it was told must not spend its own rate-limit window doing so. A
  ticket polled *early* is counted like any request.
  """

  import Plug.Conn

  @tickets :admission
  @flight :admission_flight
  @ticket_ttl_s 30
  @default_max 64
  @default_queue_max 500
  @default_ewma_ms 150
  @min_wait_ms 50
  @default_hold_ms 300
  @default_max_wait_ms 15_000
  @poll_ms 10
  @max_wait_ms 5_000

  @type verdict ::
          :ok
          | {:full, retry_after_s :: pos_integer()}
          | {:wait, ticket :: pos_integer(), position :: pos_integer(), retry_after_ms :: pos_integer()}

  def max, do: Application.get_env(:sukhi_fedi, :admission_max, @default_max)
  def queue_max, do: Application.get_env(:sukhi_fedi, :admission_queue_max, @default_queue_max)
  def max_wait_ms, do: Application.get_env(:sukhi_fedi, :admission_max_wait_ms, @default_max_wait_ms)
  def hold_ms, do: Application.get_env(:sukhi_fedi, :admission_hold_ms, @default_hold_ms)

  @doc """
  Ask to run this request now. `:ok` means a slot is held — pair it with
  `leave/1`. `{:wait, …}` carries the ticket to hand the client.

  Before sending anyone away, wait for them (`hold_ms/0`, a few hundred
  milliseconds, re-checking every few): a burst usually clears in that time,
  and a client that holds a ticket takes its slot the moment one is free
  rather than at its next visit. Only a request that is still blocked after
  that is turned into a place in line.
  """
  @spec admit(Plug.Conn.t()) :: verdict()
  def admit(%Plug.Conn{} = conn) do
    ensure_tables()
    await(ticket(conn), now_ms() + hold_ms())
  rescue
    # The tables are the queue's, not the request's: with no line to keep,
    # run the request rather than refuse it.
    ArgumentError -> :ok
  end

  defp await(t, deadline) do
    now = now_ms()

    case try_enter(t, now) do
      :ok ->
        :ok

      :blocked ->
        if now < deadline do
          Process.sleep(@poll_ms)
          await(t, deadline)
        else
          park(t, now)
        end
    end
  end

  # A live ticket gets in when fewer tickets are ahead of it than there are
  # free slots. No ticket (or a dead one) gets in only if there are more free
  # slots than tickets waiting — it cannot take a place a ticket holds.
  defp try_enter(t, now) do
    free = max() - in_flight()

    if is_integer(t) and live?(t, now) do
      if rank(t, now) <= free do
        :ets.delete(@tickets, t)
        enter()
        :ok
      else
        :blocked
      end
    else
      if free > live_count(now) do
        enter()
        :ok
      else
        :blocked
      end
    end
  end

  # Still blocked after the hold: keep (or start) a place in line.
  defp park(t, now) do
    if is_integer(t) and live?(t, now) do
      rank = rank(t, now)
      wait = estimate_ms(rank)
      touch(t, now, wait)
      {:wait, t, rank, wait}
    else
      waiting = live_count(now)
      rank = waiting + 1
      total = total_wait_ms(rank)

      # Say no early, and say when to come back, rather than promise a wait
      # longer than a person will sit through: the line is full, or this
      # place would take longer than `max_wait_ms/0`.
      if waiting >= queue_max() or total > max_wait_ms() do
        {:full, refuse_seconds(total)}
      else
        n = :ets.update_counter(@tickets, :next, 1, {:next, 0})
        wait = estimate_ms(rank)
        :ets.insert(@tickets, {n, now + wait, div(now, 1000) + @ticket_ttl_s})
        {:wait, n, rank, wait}
      end
    end
  end

  @doc "Give the slot back; `started` is `System.monotonic_time/0` from before the work."
  @spec leave(integer()) :: :ok
  def leave(started) do
    :ets.delete(@flight, self())
    ms = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
    ewma = (lookup(:ewma) || @default_ewma_ms) * 0.8 + ms * 0.2
    :ets.insert(@tickets, {:ewma, ewma})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  True when `conn` carries a live ticket whose waiting time is over — a poll
  at the pace it was told. For `RateLimitPlug`'s `:skip_if`.
  """
  @spec ticket_due?(Plug.Conn.t()) :: boolean()
  def ticket_due?(%Plug.Conn{} = conn) do
    case ticket(conn) do
      t when is_integer(t) ->
        now = now_ms()

        case :ets.lookup(@tickets, t) do
          [{^t, not_before, expires_s}] -> expires_s > div(now, 1000) and now >= not_before
          _ -> false
        end

      nil ->
        false
    end
  rescue
    ArgumentError -> false
  end

  # ── the 503 that hands out a place in line ───────────────────────────────

  @doc "Send the queued 503: header `x-queue-ticket`, body with the place and the wait."
  @spec respond_wait(Plug.Conn.t(), pos_integer(), pos_integer(), pos_integer()) :: Plug.Conn.t()
  def respond_wait(conn, ticket, position, retry_after_ms) do
    seconds = max(1, div(retry_after_ms + 999, 1000))

    body = %{
      error: "queued",
      queue: %{ticket: ticket, position: position},
      retry_after_ms: retry_after_ms,
      retry_after: seconds
    }

    conn
    |> put_resp_header("x-queue-ticket", Integer.to_string(ticket))
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_resp_content_type("application/json")
    |> send_resp(503, JSON.encode!(body))
    |> halt()
  end

  @doc """
  Send the plain refusal: a 503 that says how long to stay away, in
  `retry-after`, and asks well-behaved clients to space their requests
  (`x-slow-down`) for that long.
  """
  @spec respond_full(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def respond_full(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_resp_header("x-slow-down", Integer.to_string(seconds))
    |> put_resp_content_type("application/json")
    |> send_resp(503, JSON.encode!(%{error: "busy", retry_after: seconds}))
    |> halt()
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp enter, do: :ets.insert(@flight, {self()})

  # Slots in use. Entries whose process is gone are swept when the table
  # looks full, so a crash cannot hold a place.
  defp in_flight do
    n = :ets.info(@flight, :size)

    if n >= max() do
      @flight
      |> :ets.tab2list()
      |> Enum.each(fn {pid} -> if not Process.alive?(pid), do: :ets.delete(@flight, pid) end)

      :ets.info(@flight, :size)
    else
      n
    end
  end

  defp live?(t, now) do
    match?([{^t, _, exp}] when exp > div(now, 1000), :ets.lookup(@tickets, t))
  end

  # Tickets ahead of `t` that are still live, plus itself.
  defp rank(t, now) do
    s = div(now, 1000)

    1 +
      :ets.select_count(@tickets, [
        {{:"$1", :_, :"$2"}, [{:andalso, {:<, :"$1", t}, {:>, :"$2", s}}], [true]}
      ])
  end

  defp live_count(now) do
    s = div(now, 1000)
    :ets.select_count(@tickets, [{{:_, :_, :"$1"}, [{:>, :"$1", s}], [true]}])
  end

  defp touch(t, now, wait),
    do: :ets.insert(@tickets, {t, now + wait, div(now, 1000) + @ticket_ttl_s})

  # How long until `rank` slots are likely to have freed: the node finishes
  # `max/0` requests per average request time, so the nth in line waits
  # about n/max of it.
  defp estimate_ms(rank), do: round(min(@max_wait_ms, Kernel.max(@min_wait_ms, total_wait_ms(rank))))

  # The whole wait for place `rank`, not clamped to one visit.
  defp total_wait_ms(rank), do: (lookup(:ewma) || @default_ewma_ms) * rank / max()

  # How long to tell a refused client to stay away: about as long as the line
  # is, but never under 5 s (a retry that soon only adds to the pile) or over
  # a minute.
  defp refuse_seconds(total_ms), do: trunc(min(60, Kernel.max(5, total_ms / 1000)))

  defp lookup(key) do
    case :ets.lookup(@tickets, key) do
      [{^key, v}] -> v
      _ -> nil
    end
  end

  defp ticket(conn) do
    with [v | _] <- get_req_header(conn, "x-queue-ticket"),
         {t, ""} when t > 0 <- Integer.parse(v) do
      t
    else
      _ -> nil
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  # `Cache.Ets` makes the tables at boot and keeps them for the node's life
  # (an ETS table dies with the process that made it). This is only the way
  # out for a test that never started it.
  defp ensure_tables do
    for {name, opts} <- [{@tickets, [:set]}, {@flight, [:set]}] do
      if :ets.whereis(name) == :undefined do
        try do
          :ets.new(name, [:named_table, :public, write_concurrency: true] ++ opts)
        rescue
          ArgumentError -> :ok
        end
      end
    end

    :ok
  end
end
