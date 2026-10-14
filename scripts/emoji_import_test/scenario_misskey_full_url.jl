# SPDX-License-Identifier: AGPL-3.0-or-later
# the full /api/emojis URL is used as it is

FAKE_MISSKEY = Dict("status" => 200, "body" => Dict("emojis" => [
    Dict("id" => "1", "name" => "blobcat", "category" => "Cats", "aliases" => ["cat", "neko"], "url" => "https://misskey.example/e/blobcat.png"),
    Dict("id" => "2", "name" => "gun_cat", "category" => "Cats", "aliases" => [], "url" => "https://misskey.example/e/gun_cat.png"),
    Dict("id" => "3", "name" => "nourl", "category" => "Cats"),
    Dict("id" => "4", "category" => "Cats", "url" => "https://misskey.example/e/anon.png"),
    Dict("id" => "5", "name" => "party", "category" => nothing, "aliases" => nothing, "url" => "https://misskey.example/e/party.gif"),
    "junk"
]))
ENVV["EMOJI_MISSKEY"] = "https://other.example/api/emojis"
