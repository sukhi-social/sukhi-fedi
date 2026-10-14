# SPDX-License-Identifier: AGPL-3.0-or-later
# Same packs as a dry run: the server is told, and reports it wrote nothing.

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
FILES["/src/a/x.png"] = "img"
FILES["/src/a/plain.png"] = "img"
FILES["/src/a/fish.png"] = "img"
DIRS["/src"] = ["a", "empty"]
ENVV["EMOJI_SRC"] = "/src"
ENVV["EMOJI_DRY_RUN"] = "1"
