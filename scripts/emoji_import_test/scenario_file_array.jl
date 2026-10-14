# SPDX-License-Identifier: AGPL-3.0-or-later
# A bare array of flat /api/emojis items.

FILES["/export/list.json"] = "list"
PARSED["list"] = [
    Dict("name" => "one", "url" => "https://example.com/1.png", "category" => "A"),
    Dict("name" => "two", "originUrl" => "https://example.com/2.png")
]
ENVV["EMOJI_FILE"] = "/export/list.json"
