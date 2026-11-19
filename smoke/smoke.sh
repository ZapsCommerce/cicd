#!/usr/bin/env bash
# Post-deploy health check; run by the smoke action (smoke/action.yml).
#
#   scripts/smoke.sh <site-url> [apex-domain]
#
# Passes when every page in SMOKE_PAGES returns 200, the security headers are present (when
# SMOKE_REQUIRE_CSP=1), the optional API probe answers with the expected code and, with an apex
# domain, the apex redirects (301) to the site URL. Retries for a while: the CloudFront
# invalidation that the upload starts takes a minute or two.
#
#   SMOKE_PAGES        space-separated paths (default "/")       TODO(project): list your key pages
#   SMOKE_REQUIRE_CSP  1 = fail when / has no Content-Security-Policy header (default 0)
#   SMOKE_API_PATH     e.g. /api/health; probed with SMOKE_API_METHOD (GET) and SMOKE_API_BODY
#   SMOKE_API_EXPECT   expected status code for the probe (default 200)
#   SMOKE_TRIES / SMOKE_WAIT   attempts (10) and seconds between them (15)
set -uo pipefail

SITE="${1:?usage: $0 <site-url> [apex-domain]}"; SITE="${SITE%/}"
APEX="${2:-}"
TRIES="${SMOKE_TRIES:-10}"
WAIT="${SMOKE_WAIT:-15}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
PAGES="${SMOKE_PAGES:-/}"
API_PATH="${SMOKE_API_PATH:-}"
API_METHOD="${SMOKE_API_METHOD:-GET}"
API_BODY="${SMOKE_API_BODY:-}"
API_EXPECT="${SMOKE_API_EXPECT:-200}"

check() {
  local ok=0 code p
  for p in $PAGES; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$SITE$p")
    [ "$code" = 200 ] || { echo "  $p -> $code"; ok=1; }
  done
  if [ "${SMOKE_REQUIRE_CSP:-0}" = 1 ]; then
    curl -sI "$SITE/" | grep -qi '^content-security-policy:' || { echo "  / has no Content-Security-Policy"; ok=1; }
  fi
  if [ -n "$API_PATH" ]; then
    local args=(-s -o /dev/null -w '%{http_code}' -X "$API_METHOD")
    [ -n "$API_BODY" ] && args+=(-H 'Content-Type: application/json' -d "$API_BODY")
    code=$(curl "${args[@]}" "$SITE$API_PATH")
    [ "$code" = "$API_EXPECT" ] || { echo "  $API_METHOD $API_PATH -> $code, expected $API_EXPECT"; ok=1; }
  fi
  if [ -n "$APEX" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "https://$APEX/")
    [ "${code%% *}" = 301 ] && [ "${code#* }" = "$SITE/" ] \
      || { echo "  https://$APEX/ -> $code, expected 301 $SITE/"; ok=1; }
  fi
  return $ok
}

for i in $(seq 1 "$TRIES"); do
  echo "Smoke test $SITE (try $i of $TRIES)"
  if check; then
    echo "Health check passed: $SITE" | tee -a "$SUMMARY"
    exit 0
  fi
  [ "$i" -lt "$TRIES" ] && sleep "$WAIT"
done
echo "::error::Health check failed for $SITE"
echo "Health check FAILED: $SITE" >> "$SUMMARY"
exit 1
