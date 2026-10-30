# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Anubis with the policy + imprints baked in. haloy runs this image as
# the thing standing in front; it gates `/check` and forwards everything
# else to the app behind it. See docs/anubis.md.
#
# **This one image serves sukhi.f3liz.casa, natadeco.com and sukhi.social.** The
# policy is byte-for-byte the same for both — only the imprint (who to
# write to when you can't get through) differs, so both are baked and
# `IMPRINT_FILE` picks one per target. No second image to keep in step:
# a copy left behind stops receiving what the original learns. If the
# policies ever have to diverge, bake a second `botPolicies.*.yaml` the
# same way and point `POLICY_FNAME` at it.
#
# CI builds this on every tag push (same workflow as gateway/api).
# To change policy: edit botPolicies.yaml or imprint.md, push a tag,
# then `haloy deploy -t <target>` to roll the new anubis image.
#
# The base is pinned to a version, not `:latest`. It used to be `:latest`,
# and on 2026-08-28 a rebuild meant to change nothing at all carried us
# from v1.25.0 to v1.27.0 — where the default for an unset
# `REDIRECT_DOMAINS` had flipped from "only the domain the request came
# from" to "any domain". A version jump is fine; a silent one is not.
# Read the release notes, bump this line, then rebuild.
FROM ghcr.io/techarohq/anubis:v1.27.0

# Left over from Kamal, which verified the web role image carried
# `service=sukhi-fedi` before deploying it (anti-misconfig guard). haloy
# doesn't check it; the label is harmless and costs nothing to keep.
LABEL service="sukhi-fedi"

# `POLICY_FNAME` and `IMPRINT_FILE` env vars (set in each deploy repo's
# haloy.yaml) point at these paths.
COPY botPolicies.yaml /data/cfg/botPolicies.yaml
COPY imprint.md /data/cfg/imprint.md
COPY imprint.natadeco.md /data/cfg/imprint.natadeco.md
COPY imprint.sukhi-social.md /data/cfg/imprint.sukhi-social.md
