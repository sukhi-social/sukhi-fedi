# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.FanOut do
  @moduledoc """
  The origin's side of the bill: one popular actor on A, followed from
  `domains` remote instances, posting `posts` activities over `window_ms`.

  The structs do the counting (`PushOrigin` makes the jobs, `Origin`
  decides the notifications), so the numbers move if the protocol logic
  changes. What each counted event *costs* is a table of assumptions
  (`@cost`), in arbitrary units where one signed outbound request is
  about 4:

    * `sign`       RSA-sign one HTTP request (push needs one per target
                   per try; the activity itself is signed once, either way)
    * `verify`     check one inbound HTTP signature
    * `send`       open/reuse a connection and write the request
    * `db_write`   one row insert/update/delete
    * `db_scan`    fixed cost of one indexed query
    * `db_row`     per row read
    * `serialize`  build the activity JSON once

  Pull is modelled with every notified domain pulling right away
  (worst case for A; lazy B instances only make it cheaper).
  """

  alias PullFederation.{Origin, PushOrigin}

  @cost %{
    sign: 3.0,
    verify: 0.3,
    send: 1.0,
    db_write: 1.0,
    db_scan: 2.0,
    db_row: 0.05,
    serialize: 1.0
  }
  @activity_bytes 2_000
  @header_bytes 800
  @tick 100

  def run(model, opts) when model in [:push, :pull] do
    p =
      Map.merge(
        %{domains: 1_000, posts: 10, window_ms: 10_000, quiet_ms: 3_000, fail_rate: 0.05},
        Map.new(opts)
      )

    do_run(model, p)
  end

  # --- push ----------------------------------------------------------------

  defp do_run(:push, p) do
    targets = for d <- 1..p.domains, do: "d#{d}"
    gap = div(p.window_ms, p.posts)

    {o, peak} =
      Enum.reduce(0..(p.posts - 1), {PushOrigin.new(), 0}, fn i, {o, peak} ->
        act = %{id: "a#{i}", type: :create, visibility: :public}
        o = PushOrigin.publish(o, act, targets, i * gap)
        {o, max(peak, length(o.jobs))}
      end)

    jobs = length(o.jobs)
    # deterministic share of first tries that fail and are sent again
    retries = round(jobs * p.fail_rate)
    sends = jobs + retries
    c = @cost

    ops = %{
      requests_out: sends,
      signatures: sends + p.posts,
      db_writes: 2 * sends,
      db_queries: p.posts,
      rows_read: p.posts * p.domains,
      inbound_requests: 0
    }

    finish(:push, p, ops, peak, c.serialize * p.posts, sends * (@activity_bytes + @header_bytes))
  end

  # --- pull ----------------------------------------------------------------

  defp do_run(:pull, p) do
    actor = "https://a.example/users/popular"
    gap = div(p.window_ms, p.posts)

    o0 =
      Enum.reduce(1..p.domains, Origin.new(notify_quiet_ms: p.quiet_ms), fn d, acc ->
        Origin.follow(acc, "d#{d}", actor)
      end)

    {o, notes, peak_dirty} =
      Enum.reduce(0..div(p.window_ms + p.quiet_ms, @tick), {o0, 0, 0}, fn k, {o, notes, peak} ->
        now = k * @tick

        o =
          case rem(now, gap) == 0 and div(now, gap) < p.posts do
            true ->
              elem(Origin.publish(o, actor, %{id: "a#{div(now, gap)}", visibility: :public}), 0)

            false ->
              o
          end

        peak = max(peak, map_size(o.dirty))
        {o, sent} = Origin.due_notifications(o, now)
        {o, notes + length(sent), peak}
      end)

    _ = o
    # every notified domain pulls once; rows served = what each is behind by
    pulls = notes
    rows = p.domains * p.posts
    c = @cost

    ops = %{
      requests_out: notes,
      signatures: notes + p.posts,
      db_writes: p.posts,
      db_queries: pulls,
      rows_read: rows,
      inbound_requests: pulls
    }

    bytes =
      notes * (@header_bytes + 200) + pulls * @header_bytes + rows * @activity_bytes

    extra = c.serialize * p.posts + pulls * (c.verify + c.send) + rows * 0.1
    finish(:pull, p, ops, peak_dirty, extra, bytes)
  end

  defp finish(model, p, ops, peak_queue, extra, bytes) do
    c = @cost

    units =
      ops.requests_out * c.send + ops.signatures * c.sign + ops.db_writes * c.db_write +
        ops.db_queries * c.db_scan + ops.rows_read * c.db_row +
        ops.inbound_requests * c.verify + extra

    Map.merge(ops, %{
      model: model,
      domains: p.domains,
      posts: p.posts,
      origin_cost_units: Float.round(units, 1),
      units_per_post: Float.round(units / p.posts, 1),
      peak_queue_entries: peak_queue,
      megabytes_out: Float.round(bytes / 1_000_000, 2)
    })
  end
end
