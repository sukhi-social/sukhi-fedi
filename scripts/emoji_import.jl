# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Emoji packs -> POST /api/admin/emojis. Replaces scripts/prepare_volpeon.mjs:
# this script reads packs and decides WHAT to send; the server decides what
# is valid and writes it (SukhiFedi.CustomEmojis.import_many/3, one
# transaction, audited). No SQL is built here.
#
#   tsubakic out.tsb scripts/emoji_import.jl && tsbvm out.tsb
#
# Input : <EMOJI_SRC>/<pack>/meta.json, plus the images beside it
#         meta.json = {"emojis": [{"fileName": "...",
#                                  "emoji": {"name", "category", "aliases"}}]}
#         Images are NOT uploaded: they must already be served at
#         <EMOJI_BASE_URL>/<pack>/<file> (the rsync step, as before).
#         A listed emoji whose image file is missing is skipped and reported.
#
# Environment:
#   EMOJI_SRC       packs directory            (/tmp/volpeon_emojis)
#   EMOJI_BASE_URL  where the images are served (https://sukhi.f3liz.casa/static/emojis)
#   EMOJI_API       the server                 (https://sukhi.f3liz.casa)
#   EMOJI_TOKEN     OAuth bearer with admin:write, an admin's   (required)
#   EMOJI_DRY_RUN   "1" -> the server checks and reports, writes nothing
#   EMOJI_BATCH     emojis per request         (500; the server's cap is 2000)
#
# Exit code 1 if the server refused anything or any emoji came back failed.
#
# STATUS: run for real on the Rust VM (tsbvm) with its standard host
# (needs the branch `host-capabilities` of nyanrus/tsubaki and
# `cargo build --release --features http`): real files, real HTTP against a
# fake server that answers the way POST /api/admin/emojis is documented to.
# NOT yet run against the real server. Checks against an in-memory mock:
#
#   tsubakic out.tsb scripts/emoji_import_test/host_mock.jl \
#                    scripts/emoji_import.jl scripts/emoji_import_test/check.jl
#   tsbvm out.tsb
#
# What this script asks of its host: `host(name, args...)`, JSON in / JSON
# out, and nothing else leaves the VM. The embedder chooses which names exist
# (tsbvm's StdHost has all of these).
#
#   env.get(name, default)           -> string
#   fs.dirs(path)                    -> [string]    sub-directories, sorted
#   fs.exists(path)                  -> bool
#   fs.read(path)                    -> string
#   json.parse(text)                 -> value  (objects become Dict, arrays Vector)
#   http.post_json(url, token, body) -> Dict("status" => Int, "body" => value)
#   exit(code)                       -> never returns
#
# Known to be missing from tsbvm's builtins (from reading vm.rs): regex,
# JSON, files, env, HTTP, time. The weapon filter is therefore a word list +
# occursin (case-insensitive via lowercase), the same substring test as
# prepare_volpeon.mjs's regex.

SRC = host("env.get", "EMOJI_SRC", "/tmp/volpeon_emojis")
BASE = host("env.get", "EMOJI_BASE_URL", "https://sukhi.f3liz.casa/static/emojis")
API = host("env.get", "EMOJI_API", "https://sukhi.f3liz.casa")
TOKEN = host("env.get", "EMOJI_TOKEN", "")
DRY_RUN = host("env.get", "EMOJI_DRY_RUN", "") == "1"
BATCH = parse(Int, host("env.get", "EMOJI_BATCH", "500"))

WEAPON_WORDS = ["knife", "knives", "gun", "guns", "pistol", "rifle", "revolver",
                "shotgun", "sniper", "stab", "stabbed", "blade", "dagger",
                "sword", "weapon", "grenade", "bomb"]

# a field that is missing or null reads as "none"
function listof(x)
    if x === nothing
        return []
    end
    return x
end

function weapon_word(texts)
    for t in texts
        low = lowercase(t)
        for w in WEAPON_WORDS
            if occursin(w, low)
                return w
            end
        end
    end
    return nothing
end

# One pack -> (what to send, what the filter dropped, files that were missing)
#
# The locals here are named apart from the script's globals below (excluded,
# missing, ...) on purpose: in tsbvm and the OCaml runtime, assigning a name
# inside a function overwrites a global of the same name, where Julia would
# make a local. (Reproduction in the commit message of this file.)
function read_pack(pack)
    meta_path = SRC * "/" * pack * "/meta.json"
    if !host("fs.exists", meta_path)
        return ([], [], [])
    end
    meta = host("json.parse", host("fs.read", meta_path))

    kept_here = []
    dropped_here = []
    absent_here = []
    for item in listof(get(meta, "emojis", nothing))
        info = item["emoji"]
        aliases = listof(get(info, "aliases", nothing))
        file = item["fileName"]

        hit = weapon_word(vcat([info["name"], file], aliases))
        if hit !== nothing
            push!(dropped_here, pack * "/" * file * " (" * hit * ")")
            continue
        end
        if !host("fs.exists", SRC * "/" * pack * "/" * file)
            push!(absent_here, pack * "/" * file)
            continue
        end

        push!(kept_here, Dict("shortcode" => info["name"],
                              "image_url" => BASE * "/" * pack * "/" * file,
                              "category" => get(info, "category", pack),
                              "aliases" => aliases))
    end
    return (kept_here, dropped_here, absent_here)
end

# [a, b, c, d, e] with n = 2 -> [[a, b], [c, d], [e]]
function chunks(items, n)
    out = []
    i = 1
    while i <= length(items)
        push!(out, items[i:min(i + n - 1, length(items))])
        i = i + n
    end
    return out
end

# --- main ------------------------------------------------------------------

if TOKEN == ""
    println("EMOJI_TOKEN is not set: an admin:write bearer token is required")
    host("exit", 1)
end

to_send = []
excluded = []
missing = []
for pack in host("fs.dirs", SRC)
    result = read_pack(pack)
    for e in result[1]
        push!(to_send, e)
    end
    for x in result[2]
        push!(excluded, x)
    end
    for m in result[3]
        push!(missing, m)
    end
end

batches = chunks(to_send, BATCH)
imported = 0
failed = 0
refused = 0
for batch in batches
    response = host("http.post_json", API * "/api/admin/emojis", TOKEN,
                    Dict("emojis" => batch, "dry_run" => DRY_RUN))
    if response["status"] != 200
        refused = refused + 1
        println("server refused a batch of $(length(batch)): HTTP $(response["status"]) $(response["body"])")
        continue
    end
    body = response["body"]
    imported = imported + body["imported"]
    failed = failed + body["failed"]
    for r in body["results"]
        if r["status"] != "ok"
            println("failed: $(r["shortcode"]) -> $(r["error"])")
        end
    end
end

for x in excluded
    println("excluded: $x")
end
for m in missing
    println("missing image: $m")
end
mode = DRY_RUN ? " (dry run)" : ""
println("Sent $(length(to_send)) emoji in $(length(batches)) request(s)$mode.")
println("Imported $imported, failed $failed, excluded $(length(excluded)), missing image $(length(missing)).")

if refused > 0 || failed > 0
    host("exit", 1)
end
