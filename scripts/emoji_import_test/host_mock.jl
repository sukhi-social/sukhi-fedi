# SPDX-License-Identifier: AGPL-3.0-or-later
# In-memory stand-in for the proposed `host` capability (see ../emoji_import.jl),
# including a fake server for POST /api/admin/emojis.
# Fold it BEFORE the script: tsubakic out.tsb host_mock.jl ../emoji_import.jl check.jl

FILES = Dict()      # path -> text
PARSED = Dict()     # text -> parsed JSON
DIRS = Dict()       # path -> [subdirs]
REQUESTS = []       # every http.post_json the script made
EXITS = []          # every host("exit", code)
ENVV = Dict("EMOJI_SRC" => "/src", "EMOJI_TOKEN" => "tok", "EMOJI_BATCH" => "2")

FILES["/src/a/meta.json"] = "meta-a"
PARSED["meta-a"] = Dict("emojis" => [
    Dict("fileName" => "cat.png",   "emoji" => Dict("name" => "cat_it's", "category" => "animals", "aliases" => ["neko", "o'neko"])),
    Dict("fileName" => "knife.png", "emoji" => Dict("name" => "chef", "category" => "tools", "aliases" => [])),
    Dict("fileName" => "x.png",     "emoji" => Dict("name" => "dagger_smile", "aliases" => ["BOMB_face"])),
    Dict("fileName" => "plain.png", "emoji" => Dict("name" => "plain")),
    Dict("fileName" => "gone.png",  "emoji" => Dict("name" => "gone")),
    Dict("fileName" => "fish.png",  "emoji" => Dict("name" => "fish", "category" => "animals"))
])
FILES["/src/a/cat.png"] = "img"
FILES["/src/a/knife.png"] = "img"
FILES["/src/a/plain.png"] = "img"
FILES["/src/a/fish.png"] = "img"
DIRS["/src"] = ["a", "empty"]

# What the server answers: every item ok, except a shortcode called "fish".
function fake_server(body)
    results = []
    n_ok = 0
    n_bad = 0
    i = 0
    for e in body["emojis"]
        if e["shortcode"] == "fish"
            push!(results, Dict("index" => i, "shortcode" => "fish", "status" => "error", "error" => "invalid_emoji_attributes"))
            n_bad = n_bad + 1
        else
            push!(results, Dict("index" => i, "shortcode" => e["shortcode"], "status" => "ok"))
            n_ok = n_ok + 1
        end
        i = i + 1
    end
    return Dict("status" => 200,
                "body" => Dict("imported" => n_ok, "failed" => n_bad,
                               "dry_run" => body["dry_run"], "results" => results))
end

function host(name, args...)
    if name == "env.get"
        return get(ENVV, args[1], args[2])
    elseif name == "fs.dirs"
        return DIRS[args[1]]
    elseif name == "fs.exists"
        return haskey(FILES, args[1])
    elseif name == "fs.read"
        return FILES[args[1]]
    elseif name == "json.parse"
        return PARSED[args[1]]
    elseif name == "http.post_json"
        push!(REQUESTS, Dict("url" => args[1], "token" => args[2], "body" => args[3]))
        return fake_server(args[3])
    elseif name == "exit"
        push!(EXITS, args[1])
        return nothing
    else
        error("host: unknown capability " * name)
    end
end
