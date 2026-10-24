# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Mode do
  @moduledoc """
  Per (origin, receiving domain): push the activity itself, or only
  notify and let the receiver pull? This module is the only place that
  decides. Pure; every function takes `now` (ms).

  The measure is **posts that reach this domain per notification window**
  (`window_ms`, the same 3 s as the quiet period), summed over every actor
  of this origin the domain follows. README part 6 shows that break-even
  is about 1.5 posts per window, independent of the follower count.

  Going to pull looks at the live count too (two posts in one window are
  enough, no need to wait for the average); coming back looks only at the
  windowed average, so that the post being handled does not by itself keep
  the domain in pull.

  Rules:

    * start in `:push`;
    * go to `:pull` when `max(ewma, posts in the current window) >= hi`
      (default 1.5) or when the domain recently failed us;
    * come back to `:push` only after the rate has stayed at or under `lo`
      (default 0.7) for `hold_ms` AND the failure penalty has run out;
      the gap between `hi` and `lo`, plus the hold, is the hysteresis that
      stops a domain flapping at the boundary;
    * `observe_failure/3` (a push answered 429/5xx/timeout, or a pull was
      declined by the receiver's own overload) forces `:pull` for
      `penalty_ms`.
  """

  defstruct window_ms: 3_000,
            alpha: 0.3,
            hi: 1.5,
            lo: 0.7,
            hold_ms: 30_000,
            penalty_ms: 60_000,
            domains: %{}

  @fresh %{mode: :push, wstart: nil, count: 0, ewma: 0.0, low_since: nil, unhealthy_until: 0}

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc "A post that this domain follows was published."
  def observe_post(%__MODULE__{} = m, domain, now) do
    d = m |> roll(domain, now) |> then(&%{&1 | count: &1.count + 1})
    put(m, domain, d)
  end

  @doc "The domain answered a push badly (429/5xx/timeout). Force pull for `penalty_ms`."
  def observe_failure(%__MODULE__{} = m, domain, now) do
    d = roll(m, domain, now)
    put(m, domain, %{d | mode: :pull, unhealthy_until: now + m.penalty_ms, low_since: nil})
  end

  @doc "The mode to use for the next post to this domain: `{m, :push | :pull}`."
  def mode(%__MODULE__{} = m, domain, now) do
    d = roll(m, domain, now)
    rate = max(d.ewma, d.count * 1.0)
    healthy? = now >= d.unhealthy_until

    d =
      case d.mode do
        :push -> if rate >= m.hi or not healthy?, do: %{d | mode: :pull, low_since: nil}, else: d
        :pull -> maybe_return(m, d, d.ewma, healthy?, now)
      end

    {put(m, domain, d), d.mode}
  end

  defp maybe_return(m, d, rate, healthy?, now) do
    cond do
      # still dense right now, or the average has not come down
      rate > m.lo or d.count >= m.hi ->
        %{d | low_since: nil}

      not healthy? ->
        d

      true ->
        since = d.low_since || now

        case now - since >= m.hold_ms do
          true -> %{d | mode: :push, low_since: nil}
          false -> %{d | low_since: since}
        end
    end
  end

  defp put(m, domain, d), do: %{m | domains: Map.put(m.domains, domain, d)}

  # Close finished windows: fold the count into the average, decay empty ones.
  defp roll(m, domain, now) do
    d = Map.get(m.domains, domain, @fresh)

    case d.wstart do
      nil ->
        %{d | wstart: now}

      ws ->
        k = div(now - ws, m.window_ms)

        case k do
          0 ->
            d

          k ->
            first = m.alpha * d.count + (1 - m.alpha) * d.ewma
            ewma = first * :math.pow(1 - m.alpha, k - 1)
            %{d | ewma: ewma, count: 0, wstart: ws + k * m.window_ms}
        end
    end
  end

  @doc "Current mode without touching anything (for reporting)."
  def peek(%__MODULE__{} = m, domain),
    do: m.domains |> Map.get(domain, @fresh) |> Map.fetch!(:mode)
end
