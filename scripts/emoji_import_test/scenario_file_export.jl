# SPDX-License-Identifier: AGPL-3.0-or-later
# A Misskey export / package meta.json: nested `emoji`, `downloadUrl`.

FILES["/export/meta.json"] = "export"
PARSED["export"] = Dict("metaVersion" => 1, "emojis" => [
    Dict("downloadUrl" => "https://misskey.example/e/blobcat.png", "fileName" => "blobcat.png",
         "emoji" => Dict("name" => "blobcat", "category" => "Cats", "aliases" => ["cat"])),
    Dict("fileName" => "bare.png", "emoji" => Dict("name" => "bare"))
])
ENVV["EMOJI_FILE"] = "/export/meta.json"
