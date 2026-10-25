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

  **A person waiting and a program waiting are not the same.** A request
  that carries `x-sukhi-purpose: background` (a poll, a read-marker sync,
  anything nobody is watching) goes behind every interactive request in line,
  is never held on a socket, is told to come back less often, and is
  refused only when its place would take minutes (`max_wait_bg_ms/0`), not
  seconds (`max_wait_ms/0`). Everything else is interactive: a person is
  looking at it, so it is held briefly for a slot, ticketed with short waits,
  and refused up front when the wait would pass what a person will sit
  through.

  Everything is in three ETS tables owned by `Cache.Ets`:

    * `:admission` — `{ticket, not_before_ms, expires_s}` per waiting ticket,
      plus `{:next, n}` (the next ticket number) and `{:ewma, ms}` (how long
      a request takes, for the wait estimate). Only the 3-tuples are swept.
    * `:admission_bg` — the same `{ticket, not_before_ms, expires_s}` rows for
      background tickets (numbers come from the one counter).
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
  @bg :admission_bg
  @flight :admission_flight
  @ticket_ttl_s 30
  @default_max 64
  @default_queue_max 500
  @default_ewma_ms 150
  @min_wait_ms 100
  @default_hold_ms 300
  @default_max_wait_ms 15_000
  @default_max_wait_bg_ms 120_000
  @poll_ms 10

  @type verdict ::
          :ok
          | :free
          | {:full, retry_after_s :: pos_integer()}
          | {:wait, ticket :: pos_integer(), position :: pos_integer(), retry_after_ms :: pos_integer()}

  def max, do: Application.get_env(:sukhi_fedi, :admission_max, @default_max)
  def queue_max, do: Application.get_env(:sukhi_fedi, :admission_queue_max, @default_queue_max)
  def max_wait_ms, do: Application.get_env(:sukhi_fedi, :admission_max_wait_ms, @default_max_wait_ms)
  def max_wait_bg_ms,
    do: Application.get_env(:sukhi_fedi, :admission_max_wait_bg_ms, @default_max_wait_bg_ms)

  def hold_ms, do: Application.get_env(:sukhi_fedi, :admission_hold_ms, @default_hold_ms)

  @doc """
  Ask to run this request now. `:ok` means a slot is held — pair it with
  `leave/1`; `:free` means the request is too cheap to count (`heavy?/1`). `{:wait, …}` carries the ticket to hand the client.

  An interactive request is first held for a moment (`hold_ms/0`, a few
  hundred milliseconds, re-checking every few): a burst usually clears in
  that time, and a ticket holder takes its slot the moment one is free
  rather than at its next visit. A background request is not held. Only a
  request still blocked is turned into a place in line.
  """
  @spec admit(Plug.Conn.t()) :: verdict()
  def admit(%Plug.Conn{} = conn) do
    if heavy?(conn) do
      ensure_tables()
      cls = class(conn)
      await(cls, ticket(conn), now_ms() + hold(cls))
    else
      :free
    end
  rescue
    # The tables are the queue's, not the request's: with no line to keep,
    # run the request rather than refuse it.
    ArgumentError -> :ok
  end

  @doc """
  False for a request that costs next to nothing: an anonymous read with no
  cursor, which is served from the short cache. Those never join the line --
  they would only be stuck behind the slow ones that fill the slots. Writes,
  anything signed in (the home timeline, notifications) and anything paging
  past the cached head are heavy.
  """
  @spec heavy?(Plug.Conn.t()) :: boolean()
  def heavy?(%Plug.Conn{} = conn) do
    conn.method not in ["GET", "HEAD"] or
      get_req_header(conn, "authorization") != [] or
      get_req_header(conn, "x-queue-ticket") != [] or
      Regex.match?(~r/(^|&)(max_id|since_id|min_id|offset)=/, conn.query_string)
  end

  @doc "`:background` when the client says nobody is watching; else `:interactive`."
  @spec class(Plug.Conn.t()) :: :interactive | :background
  def class(%Plug.Conn{} = conn) do
    case get_req_header(conn, "x-sukhi-purpose") do
      ["background" | _] -> :background
      _ -> :interactive
    end
  end

  defp hold(:interactive), do: hold_ms()
  defp hold(:background), do: 0

  defp await(cls, t, deadline) do
    now = now_ms()

    case try_enter(cls, t, now) do
      :ok ->
        :ok

      :blocked ->
        if now < deadline do
          Process.sleep(@poll_ms)
          await(cls, t, deadline)
        else
          park(cls, t, now)
        end
    end
  end

  # A live ticket gets in when fewer tickets are ahead of it than there are
  # free slots. No ticket (or a dead one) gets in only if there are more free
  # slots than tickets ahead of it — it cannot take a place a ticket holds.
  defp try_enter(cls, t, now) do
    free = max() - in_flight()

    if is_integer(t) and live?(cls, t, now) do
      if rank(cls, t, now) <= free do
        :ets.delete(table(cls), t)
        enter()
        :ok
      else
        :blocked
      end
    else
      if free > waiting(cls, now) do
        enter()
        :ok
      else
        :blocked
      end
    end
  end

  # Still blocked after the hold: keep (or start) a place in line.
  defp park(cls, t, now) do
    if is_integer(t) and live?(cls, t, now) do
      rank = rank(cls, t, now)
      wait = estimate_ms(cls, rank)
      touch(cls, t, now, wait)
      {:wait, t, rank, wait}
    else
      ahead = waiting(cls, now)
      rank = ahead + 1
      total = total_wait_ms(rank)

      # Say no early, and say when to come back, rather than promise a wait
      # longer than this kind of client will sit through: the line is full,
      # or this place would take longer than the limit for its class.
      if live_count(@tickets, now) + live_count(@bg, now) >= queue_max() or
           total > max_wait(cls) do
        {:full, refuse_seconds(cls, total)}
      else
        n = :ets.update_counter(@tickets, :next, 1, {:next, 0})
        wait = estimate_ms(cls, rank)
        :ets.insert(table(cls), {n, now + wait, div(now, 1000) + @ticket_ttl_s})
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

        case :ets.lookup(table(class(conn)), t) do
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

  defp table(:interactive), do: @tickets
  defp table(:background), do: @bg

  defp max_wait(:interactive), do: max_wait_ms()
  defp max_wait(:background), do: max_wait_bg_ms()

  defp live?(cls, t, now) do
    match?([{^t, _, exp}] when exp > div(now, 1000), :ets.lookup(table(cls), t))
  end

  # Interactive tickets all stand ahead of background ones.
  defp rank(:interactive, t, now), do: 1 + count_below(@tickets, t, now)
  defp rank(:background, t, now), do: 1 + live_count(@tickets, now) + count_below(@bg, t, now)

  # Tickets ahead of a newcomer of this class.
  defp waiting(:interactive, now), do: live_count(@tickets, now)
  defp waiting(:background, now), do: live_count(@tickets, now) + live_count(@bg, now)

  defp count_below(tab, t, now) do
    s = div(now, 1000)

    :ets.select_count(tab, [
      {{:"$1", :_, :"$2"}, [{:andalso, {:<, :"$1", t}, {:>, :"$2", s}}], [true]}
    ])
  end

  defp live_count(tab, now) do
    s = div(now, 1000)
    :ets.select_count(tab, [{{:_, :_, :"$1"}, [{:>, :"$1", s}], [true]}])
  end

  defp touch(cls, t, now, wait),
    do: :ets.insert(table(cls), {t, now + wait, div(now, 1000) + @ticket_ttl_s})

  # How long until a slot is likely to be theirs, for one visit. A person
  # gets short waits; a program, long ones (it has nothing else to do).
  # Asking again is cheap (one ETS read), so a person is told to come back
  # soon -- 100 ms near the front, never more than 1 s -- with a little spread
  # so a crowd does not knock in step. The refusal above, not this, is what
  # bounds the whole wait.
  defp estimate_ms(:interactive, rank) do
    base = min(1_000, Kernel.max(@min_wait_ms, total_wait_ms(rank)))
    round(base * (0.8 + :rand.uniform() * 0.4))
  end

  defp estimate_ms(:background, rank),
    do: round(min(10_000, Kernel.max(500, total_wait_ms(rank))))

  # The whole wait for place `rank`: the node finishes `max/0` requests per
  # average request time, so the nth in line waits about n/max of it.
  defp total_wait_ms(rank), do: (lookup(:ewma) || @default_ewma_ms) * rank / max()

  # How long to tell a refused client to stay away: about as long as the line
  # is — a person's within 5-60 s, a program's within 30-300 s.
  defp refuse_seconds(:interactive, total_ms), do: trunc(min(60, Kernel.max(5, total_ms / 1000)))
  defp refuse_seconds(:background, total_ms), do: trunc(min(300, Kernel.max(30, total_ms / 1000)))

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
    for {name, opts} <- [{@tickets, [:set]}, {@bg, [:set]}, {@flight, [:set]}] do
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
