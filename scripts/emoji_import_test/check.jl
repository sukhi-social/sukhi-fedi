# SPDX-License-Identifier: AGPL-3.0-or-later
# Runs after emoji_import.jl against host_mock.jl; error() on the first miss.

function expect(cond, what)
    if !cond
        error("emoji_import check failed: " * what)
    end
end

# everything the script sent, in order
sent = []
for r in REQUESTS
    for e in r["body"]["emojis"]
        push!(sent, e)
    end
end
names = [e["shortcode"] for e in sent]

# kept: the harmless ones; sent to the right place with the token
expect(names == ["cat_it's", "plain", "fish"], "sent exactly the kept emoji, in order: " * join(names, ","))
expect(REQUESTS[1]["url"] == "https://sukhi.f3liz.casa/api/admin/emojis", "posts to /api/admin/emojis")
expect(REQUESTS[1]["token"] == "tok", "sends the bearer token")

# EMOJI_BATCH=2: three emoji -> two requests of 2 and 1
expect(length(REQUESTS) == 2, "batched by EMOJI_BATCH")
expect(length(REQUESTS[1]["body"]["emojis"]) == 2 && length(REQUESTS[2]["body"]["emojis"]) == 1, "batch sizes 2 and 1")
expect(REQUESTS[1]["body"]["dry_run"] == false, "not a dry run by default")

# dropped: a weapon word in the FILE name, the name, an alias (any case); and a missing image
expect(!("chef" in names), "knife.png (file name) dropped")
expect(!("dagger_smile" in names), "dagger_smile (name) dropped")
expect(!("gone" in names), "an emoji whose image is missing is not sent")

# the payload carries what the server needs, untouched (quotes are the server's business now)
first = sent[1]
expect(first["image_url"] == "https://sukhi.f3liz.casa/static/emojis/a/cat.png", "image_url from EMOJI_BASE_URL")
expect(first["category"] == "animals", "category kept")
expect(first["aliases"] == ["neko", "o'neko"], "aliases kept as they are")

# a missing category falls back to the pack name; missing aliases is an empty list
plain = sent[2]
expect(plain["category"] == "a", "category defaults to the pack")
expect(plain["aliases"] == [], "aliases default to empty")

# the server reported one failure -> the script exits 1, once
expect(EXITS == [1], "exits 1 when the server reported a failed emoji")

# the script's own tallies (its globals) agree with what happened: 2 ok, 1 failed,
# 2 excluded, 1 image missing, 0 refused. Catches state leaking between functions.
expect(imported == 2, "imported tally is 2, got " * string(imported))
expect(failed == 1, "failed tally is 1, got " * string(failed))
expect(length(excluded) == 2, "excluded tally is 2, got " * string(length(excluded)))
expect(length(missing) == 1, "missing tally is 1, got " * string(length(missing)))
expect(refused == 0, "nothing was refused")

println("emoji_import: all checks passed")
