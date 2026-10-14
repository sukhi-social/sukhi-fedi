# SPDX-License-Identifier: AGPL-3.0-or-later
# Runs after emoji_import.jl against host_mock.jl; error() on the first miss.

function expect(cond, what)
    if !cond
        error("emoji_import check failed: " * what)
    end
end

sql = WRITTEN["/tmp/volpeon_static/import.sql"]

# kept: the two harmless ones; copied beside them
expect(haskey(WRITTEN, "/tmp/volpeon_static/emojis/a/cat.png"), "cat.png copied")
expect(haskey(WRITTEN, "/tmp/volpeon_static/emojis/a/plain.png"), "plain.png copied")

# dropped: a weapon word in the FILE name, in the name, and in an alias (any case)
expect(!haskey(WRITTEN, "/tmp/volpeon_static/emojis/a/knife.png"), "knife.png (file name) dropped")
expect(!occursin("dagger_smile", sql), "dagger_smile (name) dropped")
expect(!occursin("BOMB_face", sql), "BOMB_face (alias) dropped")

# quotes are doubled, in names and in aliases
expect(occursin("'cat_it''s'", sql), "shortcode quote doubled")
expect(occursin("'o''neko'", sql), "alias quote doubled")

# a missing category falls back to the pack name; no aliases is an empty array
expect(occursin("'a', ARRAY[]::varchar[]", sql), "category defaults to the pack")

# one transaction, two statements
expect(startswith(sql, "BEGIN;"), "starts a transaction")
expect(occursin("COMMIT;", sql), "ends the transaction")

println("emoji_import: all checks passed")
