# SPDX-License-Identifier: AGPL-3.0-or-later
# In-memory stand-in for the proposed `host` capability (see ../emoji_import.jl).
# Fold it BEFORE the script: tsubakic out.tsb host_mock.jl ../emoji_import.jl check.jl
FILES = Dict()      # path -> text
PARSED = Dict()     # text -> parsed JSON
DIRS = Dict()       # path -> [subdirs]
WRITTEN = Dict()    # what the script wrote / copied
CALLS = []
ENVV = Dict("EMOJI_SRC" => "/src")

FILES["/src/a/meta.json"] = "meta-a"
PARSED["meta-a"] = Dict("emojis" => [
    Dict("fileName" => "cat.png",   "emoji" => Dict("name" => "cat_it's", "category" => "animals", "aliases" => ["neko", "o'neko"])),
    Dict("fileName" => "knife.png", "emoji" => Dict("name" => "chef", "category" => "tools", "aliases" => [])),
    Dict("fileName" => "x.png",     "emoji" => Dict("name" => "dagger_smile", "aliases" => ["BOMB_face"])),
    Dict("fileName" => "plain.png", "emoji" => Dict("name" => "plain"))
])
FILES["/src/a/cat.png"] = "img"
FILES["/src/a/plain.png"] = "img"
DIRS["/src"] = ["a", "empty"]
FILES["/src/a/knife.png"] = "img"

function host(name, args...)
    push!(CALLS, name)
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
    elseif name == "fs.write"
        WRITTEN[args[1]] = args[2]
        return nothing
    elseif name == "fs.copy"
        WRITTEN[args[2]] = "copied from " * args[1]
        return nothing
    elseif name == "json.stringify"
        return "JSON(" * string(length(args[1])) * " items)"
    else
        return nothing
    end
end
