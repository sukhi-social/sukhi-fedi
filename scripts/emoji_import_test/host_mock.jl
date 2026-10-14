# SPDX-License-Identifier: AGPL-3.0-or-later
# In-memory stand-in for the host that scripts/emoji_import.jl asks of, with
# a fake Misskey and a fake POST /api/admin/emojis. Everything the script
# sends is PRINTED, so a scenario's expected output is a readable transcript.
#
# Fold it first, then a scenario, then the script:
#   tsubakic out.tsb host_mock.jl scenario_X.jl ../emoji_import.jl

FILES = Dict()      # path -> text
PARSED = Dict()     # text -> parsed JSON
DIRS = Dict()       # path -> [subdirs]
FAKE_MISSKEY = Dict("status" => 404, "body" => Dict())   # what the fake Misskey answers
ENVV = Dict("EMOJI_TOKEN" => "tok", "EMOJI_BATCH" => "2")

# The fake admin API: every emoji ok, except the shortcode "fish", which the
# server would refuse as invalid.
function fake_admin(body)
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
    shown_ok = n_ok
    if body["dry_run"]
        shown_ok = 0
    end
    return Dict("status" => 200,
                "body" => Dict("imported" => shown_ok, "failed" => n_bad,
                               "dry_run" => body["dry_run"], "results" => results))
end

function show_post(url, token, body)
    println("POST ", url, " token=", token, " dry_run=", body["dry_run"])
    for e in body["emojis"]
        println("  ", e["shortcode"], " | ", e["category"], " | ", e["aliases"], " | ", e["image_url"])
    end
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
        if endswith(args[1], "/api/admin/emojis")
            show_post(args[1], args[2], args[3])
            return fake_admin(args[3])
        end
        println("FETCH ", args[1])
        return FAKE_MISSKEY
    elseif name == "exit"
        println("[host exit ", args[1], "]")
        error("host exit")
    else
        error("host: unknown capability " * name)
    end
end
