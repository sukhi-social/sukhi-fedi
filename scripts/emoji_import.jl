# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Emoji pack -> files + SQL. The same job as scripts/prepare_volpeon.mjs
# (and SukhiFedi.CustomEmojis.import_from_*), written in Tsubaki so the
# language gets a real ops script to be tried on.
#
#   tsbvm emoji_import.tsb       # folded by `tsubakic scripts/emoji_import.jl`
#
# Input : <src>/<pack>/meta.json  + the image files beside it
#         meta.json = {"emojis": [{"fileName": "...",
#                                  "emoji": {"name", "category", "aliases"}}]}
# Output: <out>/emojis/<pack>/<file>   the kept images
#         <out>/import.sql             one transaction of upserts
#         <out>/excluded.json          what the filter dropped, and why
#
# STATUS: a draft that has NOT been folded or run. tsubakic (OCaml) could not
# be built where it was written, so nothing here is tested -- including the
# parts that lean on `*` as string concatenation, `===`, tuples returned from
# a function and indexed with result[1], and `get(dict, key, default)`.
# Expect the first run to turn up what the language does not do yet.
#
# What this script asks of its host. `host` is a proposal, not a tsbvm
# builtin yet: `host(name, args...)`, JSON in / JSON out, and nothing else
# leaves the VM. The embedder chooses which names exist.
#
#   env.get(name, default)   -> string
#   fs.dirs(path)            -> [string]      sub-directories, sorted
#   fs.exists(path)          -> bool
#   fs.read(path)            -> string
#   fs.write(path, text)     -> nothing
#   fs.mkdirp(path)          -> nothing
#   fs.copy(from, to)        -> nothing
#   fs.rmrf(path)            -> nothing
#   json.parse(text)         -> value  (objects become Dict, arrays Vector)
#   json.stringify(value)    -> string
#
# Known to be missing from tsbvm's builtins (from reading vm.rs, not from
# running): regex, JSON, files, env, time. The weapon filter therefore is
# a word list + occursin instead of prepare_volpeon.mjs's regex; same
# substring semantics, case-insensitive via lowercase.

SRC = host("env.get", "EMOJI_SRC", "/tmp/volpeon_emojis")
OUT = host("env.get", "EMOJI_OUT", "/tmp/volpeon_static")
BASE = host("env.get", "EMOJI_BASE_URL", "https://sukhi.f3liz.casa/static/emojis")

# prepare_volpeon.mjs: /(knife|knives|gun|guns|pistol|...)/i, a substring test
WEAPON_WORDS = ["knife", "knives", "gun", "guns", "pistol", "rifle", "revolver",
                "shotgun", "sniper", "stab", "stabbed", "blade", "dagger",
                "sword", "weapon", "grenade", "bomb"]

# a field that is missing, null or not a list reads as "none"
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

# SQL string literal: ' -> ''
function sql_quote(s)
    return "'" * replace(s, "'" => "''") * "'"
end

function sql_array(items)
    if length(items) == 0
        return "ARRAY[]::varchar[]"
    end
    quoted = [sql_quote(a) for a in items]
    return "ARRAY[" * join(quoted, ",") * "]::varchar[]"
end

struct Emoji
    shortcode
    category
    aliases
    image_url
    pack
    file_name
end

function upsert(e)
    return "INSERT INTO custom_emojis (shortcode, domain, image_url, static_url, category, aliases, visible_in_picker, created_at, last_fetched_at)\n" *
           "VALUES (" * sql_quote(e.shortcode) * ", NULL, " * sql_quote(e.image_url) * ", " *
           sql_quote(e.image_url) * ", " * sql_quote(e.category) * ", " * sql_array(e.aliases) *
           ", true, NOW(), NOW())\n" *
           "ON CONFLICT (shortcode, domain) DO UPDATE SET\n" *
           "  image_url = EXCLUDED.image_url,\n" *
           "  static_url = EXCLUDED.static_url,\n" *
           "  category = EXCLUDED.category,\n" *
           "  aliases = EXCLUDED.aliases,\n" *
           "  visible_in_picker = EXCLUDED.visible_in_picker,\n" *
           "  last_fetched_at = EXCLUDED.last_fetched_at;"
end

function import_pack(pack)
    meta_path = SRC * "/" * pack * "/meta.json"
    if !host("fs.exists", meta_path)
        return ([], [], 0)
    end
    meta = host("json.parse", host("fs.read", meta_path))
    host("fs.mkdirp", OUT * "/emojis/" * pack)

    kept = []
    excluded = []
    copied = 0
    for item in listof(get(meta, "emojis", nothing))
        info = item["emoji"]
        aliases = listof(get(info, "aliases", nothing))
        file = item["fileName"]

        hit = weapon_word(vcat([info["name"], file], aliases))
        if hit !== nothing
            push!(excluded, Dict("pack" => pack, "name" => info["name"],
                                 "fileName" => file, "matched" => hit))
            continue
        end

        from = SRC * "/" * pack * "/" * file
        if host("fs.exists", from)
            host("fs.copy", from, OUT * "/emojis/" * pack * "/" * file)
            copied = copied + 1
        end
        push!(kept, Emoji(info["name"], get(info, "category", pack), aliases,
                          BASE * "/" * pack * "/" * file, pack, file))
    end
    return (kept, excluded, copied)
end

# --- main ------------------------------------------------------------------

host("fs.rmrf", OUT)
host("fs.mkdirp", OUT)

all_kept = []
all_excluded = []
copied_total = 0
for pack in host("fs.dirs", SRC)
    result = import_pack(pack)
    for e in result[1]
        push!(all_kept, e)
    end
    for x in result[2]
        push!(all_excluded, x)
    end
    copied_total = copied_total + result[3]
end

statements = [upsert(e) for e in all_kept]
host("fs.write", OUT * "/import.sql", "BEGIN;\n" * join(statements, "\n") * "\nCOMMIT;\n")
host("fs.write", OUT * "/excluded.json", host("json.stringify", all_excluded))

println("Copied $copied_total emoji image files.")
println("Excluded $(length(all_excluded)) weapon emojis.")
println("Generated $(length(statements)) SQL statements.")
