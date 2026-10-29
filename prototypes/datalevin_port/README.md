# datalevin_port — Elixir ⇄ native `dtlv` over a Port (prototype)

Not wired into anything. Answers two questions:

1. Can Elixir drive Datalevin without a JVM or a Clojure client?
2. How much memory does the native `dtlv` really take under a job-queue-shaped load?

`dtlv` is Datalevin's GraalVM native binary (release `dtlv-1.2.10-ubuntu-22.04-amd64`).
`dtlv mcp -w` speaks JSON-RPC on stdio and exposes `open_database`, `transact`,
`query`, `pull`, ... `DatalevinPort` (one GenServer, one child process) wraps that
with `Port.open/2` and OTP 28's `:json`. A crash of the child cannot take the BEAM down.

```
DTLV=/path/to/dtlv DB_DIR=/tmp/dl-bench N=200000 SECS=10 XMX=64m elixir bench.exs
elixir probe.exs   # smallest end-to-end check (needs DTLV and DB_DIR)
```

`XMX` is passed to the native image as a runtime heap flag (`-Xmx64m`).

## Results (Linux x86_64 container, Elixir 1.20 / OTP 28, 200 000 "jobs")

| | `-Xmx` unset | `-Xmx64m` |
|---|---|---|
| RSS right after open | 154 MB (anon 39 + file 114) | 153 MB |
| after 500 single-entity tx (~1.2 ms/tx) | 181 MB | 180 MB |
| after loading 200 000 jobs (~20 000 entities/s) | **480 MB** (anon 325) | **252 MB** (anon 96) |
| after 10 s of claim+query | **507 MB** (anon 343) | **274 MB** (anon 108) |
| DB on disk | 36 MB | 36 MB |

- "file" RSS is the mapped binary plus LMDB pages: reclaimable page cache, not heap.
- Without a cap the Graal heap keeps growing; **`-Xmx64m` roughly halved the total with no
  visible throughput loss** in this run.
- Single-entity transactions cost ~1.1–1.3 ms through the Port. Whether each commit
  is really fsynced on this sandbox disk was not verified.

## Caveats

- MCP is a convenience API, not a production wire protocol. `transact` echoes every
  datom back and the layer rejects results over 10 000 items, so batches are 500 entities.
- One connection, serialised by the GenServer: this is a latency/memory probe, not a pool.
- The native binary is a third-party, unsigned download.
- Not covered: the job queue itself (retries, backoff, lifeline, uniqueness), the
  outbox atomicity with Ecto, backup/replication.
