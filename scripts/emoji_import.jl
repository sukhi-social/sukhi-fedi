# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Custom emoji -> POST /api/admin/emojis. This script reads a source and
# decides WHAT to send; the server decides what is valid and writes it
# (SukhiFedi.CustomEmojis.import_many/3: one transaction, audited). No SQL and
# no database access here.
#
#   tsubakic out.tsb scripts/emoji_import.jl && tsbvm out.tsb
#
# It replaces `mix sukhi.emoji.import` and CustomEmojis.import_from_misskey /
# import_from_json / import_from_zip, and scripts/prepare_volpeon.mjs.
#
# ONE source (the first that is set):
#
#   EMOJI_MISSKEY  a Misskey server: "misskey.io", "https://misskey.io" or the
#                  full ".../api/emojis" URL. Its emoji are posted as they are
#                  served -- image_url is the server's own URL (hotlinked).
#   EMOJI_FILE     a JSON file: a Misskey export / package meta.json
#                  ({"emojis": [{"fileName", "downloadUrl", "emoji": {...}}]}),
#                  /api/emojis output ({"emojis": [{"name", "url", ...}]}) or a
#                  bare array of either.
#   EMOJI_SRC      a directory of packs (default /tmp/volpeon_emojis):
#                  <pack>/meta.json plus the images beside it. Images are NOT
#                  uploaded: they must already be served at
#                  <EMOJI_BASE_URL>/<pack>/<file> (the rsync step). A listed
#                  emoji whose image file is missing is skipped and reported.
#                  A zip package: `unzip pack.zip -d <EMOJI_SRC>/<pack>`.
#
# Options, all sources:
#
#   EMOJI_CATEGORY        set every emoji's category
#   EMOJI_PREFIX          shortcode "cat" becomes "<prefix>_cat"
#   EMOJI_WEAPON_FILTER   "0" turns off the knife/gun/... filter (on by
#                         default, as prepare_volpeon.mjs had it)
#   EMOJI_BASE_URL        pack image URL prefix  (https://sukhi.f3liz.casa/static/emojis)
#   EMOJI_API             the server             (https://sukhi.f3liz.casa)
#   EMOJI_TOKEN           an admin's OAuth bearer with admin:write (required)
#   EMOJI_DRY_RUN         "1" -> the server checks and reports, writes nothing
#   EMOJI_BATCH           emoji per request      (500; the server's cap is 2000)
#
# Exit code 1 if the server refused anything, any emoji came back failed, or
# the source could not be read.
#
# STATUS: folded with tsubakic and run on the Rust VM (tsbvm) with its
# standard host (nyanrus/tsubaki, merged: #7): a scenario per
# source against an in-memory mock host,
#
#   scripts/emoji_import_test/run.sh
#
# Run end to end against a LOCAL gateway + api (`combined`, PGlite, a test
# admin and an admin:write token made for it; 2026-10-15), from a Misskey-shaped
# EMOJI_FILE: a dry run sent 2 and wrote nothing; the real run wrote 2; running
# it again left 2 (the upsert, on the partial unique index); a wrong token gave
# HTTP 401 and exit 1; no token stopped at once with exit 1. Items with a weapon
# word or no url were left out and reported.
#
# NOT yet run against the real server (sukhi.f3liz.casa), nor against a real
# Misskey (EMOJI_MISSKEY). That needs an admin's own bearer; do a dry run first
# (`EMOJI_DRY_RUN=1`). Once it passes there, scripts/prepare_volpeon.mjs and the
# old Makefile steps can go.
#
# What this script asks of its host: `host(name, args...)`, JSON in / JSON
# out, and nothing else leaves the VM (tsbvm's StdHost has all of these).
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
MISSKEY = host("env.get", "EMOJI_MISSKEY", "")
FILE = host("env.get", "EMOJI_FILE", "")
CATEGORY = host("env.get", "EMOJI_CATEGORY", "")
PREFIX = host("env.get", "EMOJI_PREFIX", "")
WEAPON_FILTER = host("env.get", "EMOJI_WEAPON_FILTER", "1") != "0"
BASE = host("env.get", "EMOJI_BASE_URL", "https://sukhi.f3liz.casa/static/emojis")
API = host("env.get", "EMOJI_API", "https://sukhi.f3liz.casa")
TOKEN = host("env.get", "EMOJI_TOKEN", "")
DRY_RUN = host("env.get", "EMOJI_DRY_RUN", "") == "1"
BATCH = parse(Int, host("env.get", "EMOJI_BATCH", "500"))

WEAPON_WORDS = ["knife", "knives", "gun", "guns", "pistol", "rifle", "revolver",
                "shotgun", "sniper", "stab", "stabbed", "blade", "dagger",
                "sword", "weapon", "grenade", "bomb"]

# Scoping is Julia's (nyanrus/tsubaki #11): a function that assigns a name
# makes a local, and `global x` is how it asks for the global. These functions
# still keep their locals' names apart from the globals above and below and
# send results out through return values or by push! onto a list the caller
# passed in, so none of them depends on that rule.

# a field that is missing or null reads as "none"
function listof(x)
    if x === nothing
        return []
    end
    return x
end

# the first present value of any key, looking in each dict in turn --
# Misskey's shapes differ in where a field lives (`name` beside `url`, or
# `emoji.name` beside `downloadUrl`)
function pick(dicts, keys)
    for d in dicts
        if isa(d, Dict)
            for k in keys
                v = get(d, k, nothing)
                if v !== nothing && v != ""
                    return v
                end
            end
        end
    end
    return nothing
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

# An item as any of the sources serves it -> (emoji to send, nothing) or
# (nothing, why it cannot be sent).
function normalize(item, pack, file)
    if !isa(item, Dict)
        return (nothing, "not an object")
    end
    spots = [get(item, "emoji", nothing), item]
    name = pick(spots, ["name", "shortcode"])
    if name === nothing
        return (nothing, "no name")
    end

    url = nothing
    if pack !== nothing
        url = BASE * "/" * pack * "/" * file
    else
        url = pick(spots, ["url", "downloadUrl", "originUrl"])
        if url === nothing
            return (nothing, "no url")
        end
    end

    shown = name
    if PREFIX != ""
        shown = PREFIX * "_" * name
    end
    shown_category = pick(spots, ["category"])
    if shown_category === nothing && pack !== nothing
        shown_category = pack
    end
    if CATEGORY != ""
        shown_category = CATEGORY
    end

    return (Dict("shortcode" => shown, "image_url" => url,
                 "category" => shown_category,
                 "aliases" => listof(pick(spots, ["aliases"]))), nothing)
end

# the weapon word an item trips on, or nothing (also when the filter is off)
function tripped(item, file)
    if !WEAPON_FILTER
        return nothing
    end
    spots = [get(item, "emoji", nothing), item]
    words = []
    named = pick(spots, ["name", "shortcode"])
    if named !== nothing
        push!(words, named)
    end
    if file !== nothing
        push!(words, file)
    end
    for a in listof(pick(spots, ["aliases"]))
        push!(words, a)
    end
    return weapon_word(words)
end

# What to call an item when saying why it was left out.
function label_of(item, file, pack)
    shown = "item"
    if file !== nothing
        shown = file
    elseif isa(item, Dict)
        named = pick([get(item, "emoji", nothing), item], ["name", "shortcode"])
        if named !== nothing
            shown = named
        end
    end
    if pack !== nothing
        shown = pack * "/" * shown
    end
    return shown
end

# items -> what to send. The reason each left-out item was left out is pushed
# onto `dropped` as "label (why)". `pack` and `dir` are nothing outside a pack.
function sift(items, pack, dir, dropped)
    sends = []
    for item in items
        file = nothing
        if isa(item, Dict)
            file = get(item, "fileName", nothing)
        end
        label = label_of(item, file, pack)

        hit = nothing
        if isa(item, Dict)
            hit = tripped(item, file)
        end
        if hit !== nothing
            push!(dropped, label * " (" * hit * ")")
            continue
        end
        if pack !== nothing && file !== nothing && !host("fs.exists", dir * "/" * file)
            push!(dropped, label * " (missing image)")
            continue
        end
        made = normalize(item, pack, file)
        if made[1] === nothing
            push!(dropped, label * " (" * made[2] * ")")
            continue
        end
        push!(sends, made[1])
    end
    return sends
end

# a source's JSON -> its list of items
function items_of(data)
    if isa(data, Dict)
        return listof(get(data, "emojis", nothing))
    end
    return listof(data)
end

# --- the three sources --------------------------------------------------------

function misskey_endpoint(spec)
    if occursin("/api/emojis", spec)
        return spec
    end
    if startswith(spec, "http://") || startswith(spec, "https://")
        # drop trailing slashes (split and rejoin)
        parts = split(spec, "/")
        while length(parts) > 0 && parts[length(parts)] == ""
            pop!(parts)
        end
        return join(parts, "/") * "/api/emojis"
    end
    return "https://" * spec * "/api/emojis"
end

function from_misskey(spec, dropped)
    endpoint = misskey_endpoint(spec)
    reply = host("http.post_json", endpoint, "", Dict())
    if reply["status"] != 200
        println("could not read ", endpoint, ": HTTP ", reply["status"])
        host("exit", 1)
    end
    return sift(items_of(reply["body"]), nothing, nothing, dropped)
end

function from_file(path, dropped)
    if !host("fs.exists", path)
        println("no such file: ", path)
        host("exit", 1)
    end
    return sift(items_of(host("json.parse", host("fs.read", path))), nothing, nothing, dropped)
end

function from_packs(dir, dropped)
    sends = []
    for pack in host("fs.dirs", dir)
        meta_path = dir * "/" * pack * "/meta.json"
        if host("fs.exists", meta_path)
            meta = host("json.parse", host("fs.read", meta_path))
            for e in sift(items_of(meta), pack, dir * "/" * pack, dropped)
                push!(sends, e)
            end
        end
    end
    return sends
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
if MISSKEY != "" && FILE != ""
    println("EMOJI_MISSKEY and EMOJI_FILE are both set: give one source")
    host("exit", 1)
end

dropped = []
to_send = []
if MISSKEY != ""
    to_send = from_misskey(MISSKEY, dropped)
elseif FILE != ""
    to_send = from_file(FILE, dropped)
else
    to_send = from_packs(SRC, dropped)
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

for x in dropped
    println("left out: $x")
end
mode = DRY_RUN ? " (dry run)" : ""
println("Sent $(length(to_send)) emoji in $(length(batches)) request(s)$mode.")
println("Imported $imported, failed $failed, left out $(length(dropped)).")

if refused > 0 || failed > 0
    host("exit", 1)
end
