# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Makes `mix deps.compile` skip recompiling dependencies whose locked
# version hasn't changed, when _build persists across builds via a
# BuildKit cache mount (see elixir/Dockerfile).
#
# Mix's own incremental compiler decides "recompile?" primarily by
# mtime (source newer than the compile manifest -> recompile), not by
# content. A Docker build's `mix deps.get` re-extracts every locked
# package fresh each time its layer runs, so ALL deps' source files
# get a "now" mtime regardless of whether their content actually
# changed -- which makes Mix think everything changed, defeating the
# cache entirely.
#
# So: for each package, compare mix.lock's own content hash (immutable
# per version -- checked by hex during deps.get) against what we
# recorded the last time we cached it successfully.
#
#   * hash matches (package unchanged) -> back-date its `deps/<pkg>`
#     source files so Mix's mtime check sees "not newer than the
#     cached compiled output" and correctly skips recompiling it.
#
#   * hash differs, or unseen (package changed, or first run) ->
#     delete its `_build/prod/lib/<pkg>` compiled output outright, so
#     Mix has nothing to skip and must compile it fresh. This is the
#     safety net: it never depends on mtime ordering being right, only
#     on mix.lock's own checksum differing, which is the same
#     guarantee `mix deps.get` already trusts.
#
# Run after `mix deps.get`, before `mix deps.compile`.

fingerprint_dir = "_build/.dep_fingerprints"
File.mkdir_p!(fingerprint_dir)

{lock, _} = Code.eval_file("mix.lock")

# Long before any real `mix deps.compile` could plausibly have run, so
# it never looks newer than an actual compile-manifest timestamp.
old_time = 946_684_800

{unchanged, changed} =
  Enum.split_with(lock, fn {pkg, entry} ->
    pkg = to_string(pkg)
    hash = entry |> Tuple.to_list() |> List.last()
    fp_path = Path.join(fingerprint_dir, pkg)
    File.read(fp_path) == {:ok, hash}
  end)

Enum.each(unchanged, fn {pkg, _entry} ->
  deps_dir = Path.join("deps", to_string(pkg))

  if File.dir?(deps_dir) do
    deps_dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.each(&File.touch!(&1, old_time))
  end
end)

Enum.each(changed, fn {pkg, entry} ->
  pkg = to_string(pkg)
  hash = entry |> Tuple.to_list() |> List.last()
  build_dir = Path.join(["_build", "prod", "lib", pkg])
  File.rm_rf!(build_dir)
  File.write!(Path.join(fingerprint_dir, pkg), hash)
end)

IO.puts(
  "docker-deps-cache: #{length(unchanged)} unchanged (back-dated), " <>
    "#{length(changed)} changed/new (compiled output cleared)"
)
