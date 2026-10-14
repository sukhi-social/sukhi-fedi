# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Which environment variables does the Elixir code read, and are they written
# down? An operator can only set what the docs name: a variable read in code
# but absent from docs/ENV.md is a knob nobody knows is there (and two
# spellings of one knob -- S3_ACCESS_KEY / S3_ACCESS_KEY_ID -- is how the docs
# and the code drifted apart before).
#
#   tsubakic out.tsb scripts/env_audit.jl && tsbvm out.tsb
#
# Reads, as text:
#   code  : every `System.get_env("NAME"`, `System.fetch_env!("NAME"` and
#           `System.fetch_env("NAME"` under {elixir,api,delivery,combined}/
#           {lib,config,rel}, in .ex and .exs files. A name built at run time
#           is not seen.
#   docs  : README.md, SETUP.md and every .md under docs/ (not docs/attic/) --
#           a `BACKTICKED_NAME`, or a line that starts `NAME=` (example env
#           files). "Documented" means named anywhere there, not that the
#           name is described well.
#
# Prints
#   undocumented : read in code, named in no doc          -- the real finding
#   unread       : named in a doc, read by no Elixir file -- informational: a
#                  shell script, compose file or the bun side may read it
#
# Environment:
#   SUKHI_ROOT        the repo root (default ".")
#   ENV_AUDIT_STRICT  "1" -> exit 1 if anything is undocumented
#
# Needs of the host: env.get, fs.exists, fs.read, fs.files, exit
# (see scripts/emoji_import.jl for the contract).

ROOT = host("env.get", "SUKHI_ROOT", ".")
STRICT = host("env.get", "ENV_AUDIT_STRICT", "") == "1"

APPS = ["elixir", "api", "delivery", "combined"]
PARTS = ["lib", "config", "rel"]
CALLS = ["System.get_env(\"", "System.fetch_env!(\"", "System.fetch_env(\""]
LETTERS = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
           "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]

# NAME_LIKE_THIS: starts with a letter, upper case, no spaces or punctuation
function env_name(s)
    if length(s) < 2 || s != uppercase(s)
        return false
    end
    starts_with_letter = false
    for letter in LETTERS
        if startswith(s, letter)
            starts_with_letter = true
        end
    end
    if !starts_with_letter
        return false
    end
    for bad in [" ", ".", "/", "-", "*", "(", ")", ":", ",", "=", "`", "|", "<", ">", "\"", "'"]
        if occursin(bad, s)
            return false
        end
    end
    return true
end

# name -> the first file that reads it
function names_read(text, path, found)
    for call in CALLS
        pieces = split(text, call)
        for i in 2:length(pieces)
            name = split(pieces[i], "\"")[1]
            if env_name(name) && !haskey(found, name)
                found[name] = path
            end
        end
    end
end

# every name a doc mentions
function names_documented(text, found)
    pieces = split(replace(text, "```" => ""), "`")
    for i in 2:2:length(pieces)
        if env_name(pieces[i])
            found[pieces[i]] = true
        end
    end
    for line in split(text, "\n")
        if occursin("=", line)
            head = split(strip(line), "=")[1]
            if env_name(head)
                found[head] = true
            end
        end
    end
end

used = Dict()
for app in APPS
    for part in PARTS
        dir = ROOT * "/" * app * "/" * part
        if !host("fs.exists", dir)
            continue
        end
        for path in host("fs.files", dir)
            if endswith(path, ".ex") || endswith(path, ".exs")
                names_read(host("fs.read", path), replace(path, ROOT * "/" => ""), used)
            end
        end
    end
end

docs = []
for top in ["README.md", "SETUP.md"]
    if host("fs.exists", ROOT * "/" * top)
        push!(docs, ROOT * "/" * top)
    end
end
if host("fs.exists", ROOT * "/docs")
    for path in host("fs.files", ROOT * "/docs")
        if endswith(path, ".md") && !occursin("/docs/attic/", path)
            push!(docs, path)
        end
    end
end

documented = Dict()
for path in docs
    names_documented(host("fs.read", path), documented)
end

if length(used) == 0
    println("FAIL found no System.get_env calls under ", ROOT, " -- wrong SUKHI_ROOT, or the code changed shape")
    host("exit", 1)
end

undocumented = []
for name in sort(collect(keys(used)))
    if !haskey(documented, name)
        push!(undocumented, name)
    end
end
unread = []
for name in sort(collect(keys(documented)))
    if !haskey(used, name)
        push!(unread, name)
    end
end

println("code reads ", length(used), " variables; ", length(docs), " docs name ", length(documented), ".")

if length(undocumented) > 0
    println("undocumented (", length(undocumented), "): read in code, named in no doc")
    for name in undocumented
        println("  ", name, "   ", used[name])
    end
end
if length(unread) > 0
    println("unread (", length(unread), "): named in a doc, read by no Elixir file (shell / compose / bun may)")
    println("  ", join(unread, " "))
end
if length(undocumented) == 0
    println("every variable the code reads is documented")
end

if STRICT && length(undocumented) > 0
    host("exit", 1)
end
