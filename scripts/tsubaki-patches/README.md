# tsbvm `host(...)` — patches for nyanrus/tsubaki

`scripts/*.jl` (emoji_import, oban_queues_check, env_audit) call
`host("env.get", ...)` and friends. That needs tsbvm's `host` builtin, which
`nyanrus/tsubaki` `main` (4921bd9) does not have yet. These two patches add it.

```
cd tsubaki                         # at main = 4921bd9
git am /path/to/sukhi-fedi/scripts/tsubaki-patches/*.patch
cd tsbvm && cargo build --release --features http
```

1. `0001` — `host(name, args...)`: the embedder decides what leaves the VM.
   `StdHost`: `env.get`, `fs.dirs/exists/read/write/mkdirp/copy/rmrf`,
   `json.parse/stringify`, `http.post_json` (feature `http`, ureq), `exit`
   (not catchable). Tests in `tsbvm/tests/host.rs`.
2. `0002` — `fs.files(path)`: every file below a directory, sorted. Used by
   `env_audit.jl` and `oban_queues_check.jl`.

Checked: applied with `git am` to a fresh clone of main; `cargo test
--features http` → `tests/host.rs` 6 passed. Three doctests in `src/vm.rs`
(`float_repr`, `elem_type_of`, `array_prefix`) fail — they fail identically
on unpatched main.

Run the scripts: `scripts/run_tree_tests.sh`.
