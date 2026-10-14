# SPDX-License-Identifier: AGPL-3.0-or-later
# The Misskey server answers 500: say so and stop, send nothing.
FAKE_MISSKEY = Dict("status" => 500, "body" => Dict())
ENVV["EMOJI_MISSKEY"] = "misskey.example"
