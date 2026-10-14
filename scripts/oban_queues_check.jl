# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Oban queues must be named in THREE places, and one forgotten name is a queue
# that never drains in production, quietly (2026-08-27: inbound_archive,
# outbound_archive, publish and preview sat stopped, because runtime.exs
# replaces the whole `queues:` list and only named one of them).
#
# For each app (gateway `elixir/`, `delivery/`) this checks:
#
#   1. config/config.exs and config/runtime.exs name the SAME queues,
#   2. with the same default concurrency (config.exs: `monitor: 5`;
#      runtime.exs: `monitor: String.to_integer(System.get_env("X", "5"))`),
#   3. and every queue a worker declares (`use Oban.Worker, queue: :name`)
#      is one of them.
#
#   tsubakic out.tsb scripts/oban_queues_check.jl && tsbvm out.tsb
#
# Environment:  SUKHI_ROOT  the repo root (default ".")
# Exit code 1 if anything is wrong.
#
# Needs of the host: env.get, fs.exists, fs.read, fs.files, exit
# (see scripts/emoji_import.jl for the contract).
#
# It reads the Elixir as text, not as code, so it relies on the layout the
# files have today: a `queues: [` line, then one `name: value` per entry, and
# the list closed by a `]` line. If that changes it says it found no queues
# rather than guessing.

ROOT = host("env.get", "SUKHI_ROOT", ".")
APPS = ["elixir", "delivery"]

# The entries of the first `queues: [ ... ]` list in `text`, one string each,
# or [] if there is none. The list is either spread over lines (one entry per
# line, closed by a `]` line) or written inline on one line.
function queue_block(text)
    inside = false
    block = []
    for line in split(text, "\n")
        t = strip(line)
        if !inside
            if occursin("queues: [", t) && !startswith(t, "#")
                rest = strip(split(t, "queues: [")[2])
                if occursin("]", rest)
                    # inline: queues: [delivery: 10, federation: 3],
                    for part in split(split(rest, "]")[1], ",")
                        if strip(part) != ""
                            push!(block, strip(part))
                        end
                    end
                    return block
                end
                inside = true
                if rest != ""
                    push!(block, rest)
                end
            end
        else
            if startswith(t, "#") || t == ""
                continue
            end
            if startswith(t, "]")
                return block
            end
            push!(block, t)
        end
    end
    return block
end

# "monitor: 5," -> ("monitor", 5)
# "monitor: String.to_integer(System.get_env(\"OBAN_X\", \"5\"))," -> ("monitor", 5)
# an entry may continue on the next line (`inbound_archive:` then the value).
function parse_queues(block)
    names = []
    values = Dict()
    current = nothing
    for t in block
        head = split(t, ":")[1]
        is_entry = head != "" && head == lowercase(head) && !occursin(" ", head) &&
                   !occursin("(", head) && !occursin(".", head) && !occursin("\"", head)
        if is_entry
            current = head
            push!(names, current)
            values[current] = strip(join(split(t, ":")[2:length(split(t, ":"))], ":"))
        elseif current !== nothing
            values[current] = values[current] * " " * t
        end
    end
    result = Dict()
    for n in names
        result[n] = default_of(values[n])
    end
    return (names, result)
end

# the concurrency written in a value: a bare number, or the last quoted
# string of String.to_integer(System.get_env("VAR", "5"))
function default_of(value)
    if occursin("\"", value)
        pieces = split(value, "\"")
        return parse(Int, strip(pieces[length(pieces) - 1]))
    end
    return parse(Int, strip(replace(value, "," => "")))
end

# queue names a file declares with `queue: :name`
function worker_queues(text)
    found = []
    pieces = split(text, "queue: :")
    for i in 2:length(pieces)
        name = pieces[i]
        for stop in [",", ")", " ", "\n", "]", "}"]
            name = split(name, stop)[1]
        end
        push!(found, name)
    end
    return found
end

# Collected, not counted: a function can push! onto a global list, but
# assigning to a global from inside a function is not something Julia allows
# without `global`, which Tsubaki does not read yet.
PROBLEMS = []

function bad(msg)
    println("FAIL ", msg)
    push!(PROBLEMS, msg)
end

for app in APPS
    problems_before = length(PROBLEMS)
    config_path = ROOT * "/" * app * "/config/config.exs"
    runtime_path = ROOT * "/" * app * "/config/runtime.exs"
    if !host("fs.exists", config_path) || !host("fs.exists", runtime_path)
        bad(app * ": config/config.exs or config/runtime.exs not found under " * ROOT)
        continue
    end

    compiled = parse_queues(queue_block(host("fs.read", config_path)))
    at_runtime = parse_queues(queue_block(host("fs.read", runtime_path)))
    if length(compiled[1]) == 0 || length(at_runtime[1]) == 0
        bad(app * ": found no `queues:` list (compile time: " * string(length(compiled[1])) *
            ", runtime: " * string(length(at_runtime[1])) * ") -- the layout this reads has changed")
        continue
    end

    for n in compiled[1]
        if !haskey(at_runtime[2], n)
            bad(app * ": queue " * n * " is in config.exs but NOT in runtime.exs -- it would never drain in prod")
        elseif at_runtime[2][n] != compiled[2][n]
            bad(app * ": queue " * n * " defaults to " * string(compiled[2][n]) *
                " in config.exs but " * string(at_runtime[2][n]) * " in runtime.exs")
        end
    end
    for n in at_runtime[1]
        if !haskey(compiled[2], n)
            bad(app * ": queue " * n * " is in runtime.exs but not in config.exs")
        end
    end

    used = Dict()
    for path in host("fs.files", ROOT * "/" * app * "/lib")
        if endswith(path, ".ex")
            text = host("fs.read", path)
            if occursin("use Oban.Worker", text)
                for q in worker_queues(text)
                    if !haskey(used, q)
                        used[q] = path
                    end
                end
            end
        end
    end
    for q in sort(collect(keys(used)))
        if !haskey(at_runtime[2], q)
            bad(app * ": a worker uses queue " * q * " (" * used[q] * ") but runtime.exs does not name it")
        end
    end
    for n in at_runtime[1]
        if !haskey(used, n)
            println("note ", app, ": queue ", n, " is declared but no worker in ", app, "/lib names it")
        end
    end
    if length(PROBLEMS) == problems_before
        println("ok   ", app, ": ", length(at_runtime[1]), " queues, ", length(used), " used by workers")
    end
end

if length(PROBLEMS) > 0
    println(length(PROBLEMS), " problem(s)")
    host("exit", 1)
end
println("oban queues: consistent")
