# job_queue_dbsp — incremental-Datalog "what may run now?" (prototype)

Not wired into anything. A throwaway experiment for the question
"could the scheduling decision of the delivery queue be a set of rules
that a Datalog-style engine keeps up to date incrementally?"

```
eligible(job) :- available(host, job), not saturated(host), not blocked_parent(job).
saturated(host)   :- count(running(host, _)) >= LIMIT.
blocked_parent(p) :- child(p, c), not done(c).
```

Engine: [`dbsp`](https://crates.io/crates/dbsp) 0.370.0 (Feldera), a Rust
incremental engine that handles retractions (Z-sets). Built with the pinned
toolchain in `rust-toolchain.toml`.

```
cargo run --release -- 100000      # number of available jobs
```

Every tick the program applies ~90 fact changes (jobs start, children finish,
running jobs end) and asserts that the incrementally maintained `eligible` set
equals a from-scratch recompute (`Naive`).

## Results (4 vCPU container, 1 DBSP worker, 200 ticks)

| jobs | dbsp / tick | full recompute / tick | RSS after |
|---|---|---|---|
| 10 000 | 0.98 ms | 0.62 ms | 14 MB |
| 100 000 | 1.9 ms | 9.2 ms | 36 MB |
| 500 000 | 6.0 ms | 66 ms | 163 MB |
| 1 000 000 | 10.7 ms | 130 ms | 269 MB |

The recompute baseline is a naive "rebuild everything" and is a strawman: a
hand-written incremental structure would also be O(change). What this does
show is that the rules above are correct under insert/retract and that the
engine stays within ~270 MB at 1M facts of this shape.

## Gotchas found

- **rustc 1.97.0 ICEs** compiling dbsp 0.370.0 (next-trait-solver panic in
  `StarJoinFuncTrait`). dbsp declares `rust-version = 1.96.1`; use that.
- **`default-features = false` does not compile** in 0.370.0. With the default
  `backend-mode`, typed `antijoin` / `distinct` / `aggregate` are cfg'd out, so
  anti-joins are written as `A - (A semijoin B)`, where `B` is made a set with
  `weighted_count()`.
- **`output()` keeps only the last microstep.** A transaction runs as several
  microsteps; `OutputHandle` is overwritten each step, which gave an empty or
  partly wrong delta for big transactions. Use `accumulate_output()` and sum
  weights over `concat()`.

## Not covered

Durability, atomic claim, the clock (would arrive as facts), the NIF/Port
boundary, `delivery_receipts` de-dup, per-host rate over time.
