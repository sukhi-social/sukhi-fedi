#!/usr/bin/env bash
# Pre-deploy verification. Each check corresponds to a past regression
# captured in the commit log; the goal is to catch the same class of
# mistake before the release lands, not to add hypothetical guards.
set -euo pipefail

fail=0

# (1) DOMAIN consistency across compose files.
# Past regression: x64-freetier override silently dropped DOMAIN from the
# delivery service, leaving it minting localhost:4000 keyIds in prod.
if command -v yq >/dev/null 2>&1; then
  for compose_pair in \
    "docker-compose.yml" \
    "docker-compose.yml docker-compose.x64-freetier.yml"; do
    args=()
    for f in $compose_pair; do args+=(-f "$f"); done
    domains=$(docker compose "${args[@]}" config 2>/dev/null \
      | yq '.services | to_entries | map(select(.value.environment.DOMAIN != null)) | .[] | .value.environment.DOMAIN' \
      | sort -u)
    count=$(printf '%s\n' "$domains" | grep -cv '^$' || true)
    if [ "$count" -gt 1 ]; then
      echo "FAIL: DOMAIN mismatch across services in: $compose_pair"
      printf '  values: %s\n' "$domains"
      fail=1
    fi
  done
else
  echo "SKIP: yq not installed; cannot verify compose DOMAIN consistency"
fi

# (2) localhost:4000 literal in prod code.
# Past regression: every callsite carried its own fallback string, so a
# missing DOMAIN env never raised — it just baked localhost into URIs.
# Enforce the central Sukhi*.Config.domain!() path.
if grep -rn '"localhost:4000"' elixir/lib delivery/lib api/lib 2>/dev/null; then
  echo "FAIL: localhost:4000 literal in prod code (use Sukhi*.Config.domain!())"
  fail=1
fi

# (5) Webfinger reverse-lookup smoke test.
# Past regression: the endpoint accepted only acct: form; remote servers
# probing with ?resource=https://... got 404 and dropped the actor.
# Skipped unless DOMAIN+SCHEME are set (gated behind a live deploy).
if [ -n "${DOMAIN:-}" ] && [ -n "${SCHEME:-}" ]; then
  for resource in "acct:watcher@$DOMAIN" "$SCHEME://$DOMAIN/users/watcher"; do
    if ! curl -fsS "$SCHEME://$DOMAIN/.well-known/webfinger?resource=$resource" >/dev/null; then
      echo "FAIL: webfinger lookup failed for resource=$resource"
      fail=1
    fi
  done
else
  echo "SKIP: webfinger smoke (set DOMAIN and SCHEME to enable)"
fi

if [ "$fail" -eq 0 ]; then
  echo "preflight: all checks passed"
fi
exit "$fail"
