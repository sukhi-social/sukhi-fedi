# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Calendar do
  @moduledoc """
  The origin's appointment book for pull streams. Pure; every function
  takes `now` (ms). This module is the **only** place that decides when a
  declined receiver may come back; `Origin` asks it and obeys.

  The idea: when every stream slot is taken, do not make receivers guess a
  backoff. Hand each one the next free appointment, one every `slot_ms`
  (observed stream time divided by slots times utilization), and let the
  receiver wait exactly that long.

  ## State (bounded)

    * `next_slot`: the time of the next free appointment. One integer.
    * `entries`: `domain => at`, only for domains that hold a promise.
      At most one per known domain, and swept after `grace_ms`.
    * `ewma_stream_ms`: running average of how long a stream really takes,
      so `slot_ms` follows reality instead of a constant.

  ## Rules

    1. **One promise per domain.** A domain that asks again while holding
       one gets the time that is left, and no second promise.
    2. **Early is refused, on time is served, late within `grace_ms` is
       served, later forfeits.** A forfeited slot is simply lost; the
       domain is treated as a fresh arrival.
    3. **Beyond `horizon_ms` ahead nothing is promised** (`:shed`). The
       receiver is told to retry after `horizon_ms`, and the book cannot
       grow without bound however many domains ask.
    4. **Promises are spaced `slot_ms` apart, with headroom.** `slot_ms` is
       the stream time divided by `slots * utilization` (0.8): the book
       fills only 80% of capacity. At 100% a single late arrival displaces
       the next one, which displaces the next, and the same few receivers
       keep coming back every slot while the queue never drains (the first
       version of this module did exactly that: 13 requests per domain).
       The 20% is what lets a delayed arrival be absorbed.
    5. **No cutting in line.** While anything is promised ahead
       (`pending?/2`), a domain with no promise must book like everybody
       else instead of taking a free slot.
    6. **Idle book resets.** If `next_slot` is in the past, the next booking
       starts at `now + slot_ms`.
  """

  defstruct slot_ms: 50,
            slots: 8,
            horizon_ms: 300_000,
            grace_ms: 2_000,
            next_slot: 0,
            entries: %{},
            ewma_stream_ms: nil,
            alpha: 0.2,
            utilization: 0.8,
            booked: 0

  @type t :: %__MODULE__{}
  @type claim :: :none | :due | :expired | {:early, pos_integer}

  # Until a stream has been observed, assume streams take `@first_stream_ms`.
  # (A fixed 50 ms spacing is wrong for any slot count: with 64 slots the
  # first wave of 1000 receivers was spread over 50 s.)
  @first_stream_ms 100

  def new(opts \\ []) do
    c = struct!(__MODULE__, opts)

    case Keyword.has_key?(opts, :slot_ms) do
      true -> c
      false -> %{c | slot_ms: max(1, round(@first_stream_ms / (c.slots * c.utilization)))}
    end
  end

  @doc "What this domain holds: nothing, a promise not yet due, one that is due now, or one it let lapse."
  @spec claim(t, String.t(), integer) :: claim
  def claim(%__MODULE__{} = c, domain, now) do
    case Map.fetch(c.entries, domain) do
      :error -> :none
      {:ok, at} when now < at -> {:early, at - now}
      {:ok, at} when now <= at + c.grace_ms -> :due
      {:ok, _at} -> :expired
    end
  end

  @doc "Has this domain a promise that is still alive (early or due)?"
  @spec claimed?(t, String.t(), integer) :: boolean
  def claimed?(%__MODULE__{} = c, domain, now),
    do: match?({:early, _}, claim(c, domain, now)) or claim(c, domain, now) == :due

  @doc "Is anything promised in the future? (rule 5)"
  @spec pending?(t, integer) :: boolean
  def pending?(%__MODULE__{next_slot: n}, now), do: n > now

  @doc "Book the next free appointment: `{calendar, {:ok, delay_ms}}` or `{calendar, {:shed, retry_ms}}`."
  @spec book(t, String.t(), integer) :: {t, {:ok, pos_integer} | {:shed, pos_integer}}
  def book(%__MODULE__{} = c, domain, now) do
    at = max(c.next_slot, now + c.slot_ms)

    case at - now > c.horizon_ms do
      true ->
        {c, {:shed, c.horizon_ms}}

      false ->
        {%{
           c
           | next_slot: at + c.slot_ms,
             entries: Map.put(c.entries, domain, at),
             booked: c.booked + 1
         }, {:ok, at - now}}
    end
  end

  @doc """
  A domain that is due found every slot taken (someone walked in, a stream
  ran long). It keeps its promise, moved one slot ahead of now; the book
  itself is untouched, so the delay is a small excess, not a new booking.
  """
  @spec postpone(t, String.t(), integer) :: {t, pos_integer}
  def postpone(%__MODULE__{} = c, domain, now) do
    {%{c | entries: Map.put(c.entries, domain, now + c.slot_ms)}, c.slot_ms}
  end

  @spec release(t, String.t()) :: t
  def release(%__MODULE__{} = c, domain), do: %{c | entries: Map.delete(c.entries, domain)}

  @doc "Feed in how long a finished stream really took."
  @spec observe_stream(t, non_neg_integer) :: t
  def observe_stream(%__MODULE__{} = c, duration_ms) do
    avg =
      case c.ewma_stream_ms do
        nil -> duration_ms * 1.0
        old -> c.alpha * duration_ms + (1 - c.alpha) * old
      end

    %{c | ewma_stream_ms: avg, slot_ms: max(1, round(avg / (c.slots * c.utilization)))}
  end

  @doc "Drop promises that have lapsed. Call now and then; bounded by the number of known domains."
  @spec sweep(t, integer) :: t
  def sweep(%__MODULE__{} = c, now) do
    %{c | entries: Map.reject(c.entries, fn {_d, at} -> now > at + c.grace_ms end)}
  end

  @spec size(t) :: non_neg_integer
  def size(%__MODULE__{entries: e}), do: map_size(e)
end
