# mnesia_queue — a delivery job queue on Mnesia (prototype)

Not wired into anything. The parts of Oban that `SukhiDelivery` really uses
(`max_attempts: 10`, exponential backoff, rescue of dead workers, de-dup by
`(activity_id, inbox_url)`, pruning) as one ~300-line module, so that the
delivery node would not need Postgres at all.

```
mix test                                   # 9 tests
mix compile && elixir -pa _build/dev/lib/mnesia_queue/ebin bench/crash.exs write DIR
elixir -pa _build/dev/lib/mnesia_queue/ebin bench/crash.exs recover DIR
STORAGE=ram|disc SYNC=true|false N=100000 elixir -pa _build/dev/lib/mnesia_queue/ebin bench/bench.exs
```

Every state change is one `:mnesia.sync_transaction/1`, so the properties live
in `lib/mnesia_queue.ex` and nowhere else:

| property | where |
|---|---|
| a job goes to exactly one claimer | `claim/3` (one transaction; tested with 8 concurrent claimers x 2000 jobs) |
| per-host cap (`host_limit`) | inside `claim/3`, so a dead host cannot starve the rest |
| scheduling (`run_at`) | ordered `{run_at, id}` index; `claim` stops at the first future entry |
| retry + `2^attempt` s backoff, then `:dead` | `fail/3` |
| unique key (`{activity_id, inbox}`) | `enqueue/4` returns `{:duplicate, id}`; key freed when terminal |
| rescue after a crash (lifeline) | `lifeline/1`: expired leases go back to ready; counts toward `max_attempts` |
| retention | `prune/2` |

Time is passed in (`now`, ms): deterministic tests, same style as `prototypes/pull_federation`.

## Measured (4 vCPU container, Elixir 1.20 / OTP 28, one process)

| | enqueue (1 tx each) | claim+complete | memory |
|---|---|---|---|
| `ram_copies`, 200 000 jobs | 24 000/s | 10 000/s | ETS 140 MB (**~0.7 KB/job**), RSS 320 MB peak |
| `disc_copies`, sync, 20 000 jobs | 17 000/s | 7 000/s | ETS 13 MB, RSS ~120 MB |

- `kill -9` of the VM after claiming 100 of 1000 jobs and completing 1: after restart
  900 ready, 99 claimed, 1 completed; `lifeline` returned the 99. (`bench/crash.exs`)
- `prune` of 200 000 jobs in one transaction took 3.4 s and pushed RSS from 240 to 429 MB:
  prune in slices.

## Not covered / known gaps

- **Power loss**: `sync_transaction` flushes Mnesia's log, but fsync-on-commit was not
  verified; only SIGKILL of the VM was tested.
- Single node. A second delivery node would need Mnesia distribution (split-brain
  handling), or one node owning the queue.
- Everything lives in RAM (`disc_copies` is a RAM table with a log): ~0.7 KB/job, so
  100 000 pending jobs cost ~70 MB. A cap on pending jobs per host is needed
  (dead hosts accumulate).
- No telemetry, no worker runner (a supervisor that calls `claim` and runs the
  HTTP POST), no rate limit over time, no `Oban.Web` equivalent.
- The outbox-to-queue hop is at-least-once; de-dup stays in `delivery_receipts`.
