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
  @default_max 32
  @default_queue_max 500
  @default_ewma_ms 150
  @min_wait_ms 200
  @max_wait_ms 5_000

  @type verdict ::
          :ok
          | :full
          | {:wait, ticket :: pos_integer(), position :: pos_integer(), retry_after_ms :: pos_integer()}

  def max, do: Application.get_env(:sukhi_fedi, :admission_max, @default_max)
  def queue_max, do: Application.get_env(:sukhi_fedi, :admission_queue_max, @default_queue_max)

  @doc """
  Ask to run this request now. `:ok` means a slot is held — pair it with
  `leave/1`. `{:wait, …}` carries the ticket to hand the client.
  """
  @spec admit(Plug.Conn.t()) :: verdict()
  def admit(%Plug.Conn{} = conn) do
    ensure_tables()
    now = now_ms()
    free = max() - in_flight()

    case ticket(conn) do
      t when is_integer(t) ->
        if live?(t, now) do
          rank = rank(t, now)

          if rank <= free do
            :ets.delete(@tickets, t)
            enter()
            :ok
          else
            wait = estimate_ms(rank)
            touch(t, now, wait)
            {:wait, t, rank, wait}
          end
        else
          ticketless(free, now)
        end

      nil ->
        ticketless(free, now)
    end
  rescue
    # The tables are the queue's, not the request's: with no line to keep,
    # run the request rather than refuse it.
    ArgumentError -> :ok
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

  # ── internals ────────────────────────────────────────────────────────────

  defp ticketless(free, now) do
    waiting = live_count(now)

    cond do
      free > 0 and waiting == 0 ->
        enter()
        :ok

      waiting >= queue_max() ->
        :full

      true ->
        t = :ets.update_counter(@tickets, :next, 1, {:next, 0})
        rank = waiting + 1
        wait = estimate_ms(rank)
        :ets.insert(@tickets, {t, now + wait, div(now, 1000) + @ticket_ttl_s})
        {:wait, t, rank, wait}
    end
  end

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

  # How long until a slot is likely to be theirs: the line ahead, in rounds of
  # `max/0` requests, at the recent time per request.
  defp estimate_ms(rank) do
    per = lookup(:ewma) || @default_ewma_ms
    rounds = div(rank + max() - 1, max())
    round(min(@max_wait_ms, Kernel.max(@min_wait_ms, per * rounds)))
  end

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
