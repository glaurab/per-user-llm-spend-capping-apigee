#!/usr/bin/env bash
#
# smoke-test.sh - exercise the deployed gateway end to end.
#
# These are not unit tests. Every assertion here corresponds to a property of
# the system that someone will eventually depend on, and that would otherwise
# only be discovered to be false in production:
#
#   - a call is metered, and the caller can see what it cost
#   - reading your budget does not spend your budget
#   - streaming is metered too, so it is not a free lane
#   - the allowlist actually refuses
#   - the cap actually refuses, with an actionable body
#   - overshoot stays inside the bound the design promises
#
# The 429 test deliberately spends a real budget. Run it against a test tier
# with a small cap, not against production, and read the guard below.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/config/env.sh"

BASE="https://${APIGEE_HOSTNAME}/llm"

# ------------------------------------------------------------------------------
# The caller's token.
#
# This must be a real token from the identity provider configured in
# OIDC_JWKS_URI, with the audience in OIDC_AUDIENCE. There is deliberately no
# fallback and no bypass: a gateway with a test backdoor is a gateway with a
# backdoor. How to mint one for your IdP is in docs/06-deployment.md.
# ------------------------------------------------------------------------------
if [ -z "${GATEWAY_TEST_TOKEN:-}" ]; then
  cat >&2 <<'EOT'
ERROR: GATEWAY_TEST_TOKEN is not set.

  export GATEWAY_TEST_TOKEN="$(...mint a token from your IdP...)"

It must carry the audience configured in OIDC_AUDIENCE and a subject claim.
Whatever tier that subject maps to is the budget these tests will spend.
EOT
  exit 1
fi

AUTH="Authorization: Bearer ${GATEWAY_TEST_TOKEN}"
JSON="Content-Type: application/json"

MODEL="$(jq -r '.allowedModels[0]' "${ROOT_DIR}/config/runtime-config.json")"
CURRENCY="$(jq -r '.currency' "${ROOT_DIR}/config/budgets.json")"

PASS=0
FAIL=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }

remaining() {
  curl -sS -m 30 "${BASE}/v1/budget" -H "${AUTH}" 2>/dev/null \
    | jq -r '.remaining_amount // .limits[0].remaining_amount // "0"'
}

# ==============================================================================
group "Introspection"
# ==============================================================================

CATALOGUE="$(curl -sS -m 30 -w '\n%{http_code}' "${BASE}/v1/models" -H "${AUTH}")"
CODE="$(printf '%s' "${CATALOGUE}" | tail -1)"
BODY="$(printf '%s' "${CATALOGUE}" | sed '$d')"
if [ "${CODE}" = "200" ] && printf '%s' "${BODY}" | jq -e '.models | length > 0' >/dev/null 2>&1; then
  ok "GET /v1/models returns the allowlist"
else
  bad "GET /v1/models returned ${CODE}" "$(printf '%s' "${BODY}" | head -c 200)"
fi

BUDGET="$(curl -sS -m 30 -w '\n%{http_code}' "${BASE}/v1/budget" -H "${AUTH}")"
CODE="$(printf '%s' "${BUDGET}" | tail -1)"
BODY="$(printf '%s' "${BUDGET}" | sed '$d')"
if [ "${CODE}" = "200" ]; then
  ok "GET /v1/budget returns 200"
  printf '        %s\n' "$(printf '%s' "${BODY}" | jq -c '{currency, limits: [.limits[]? | {scope, remaining_amount}]}' 2>/dev/null)"
else
  bad "GET /v1/budget returned ${CODE}" "$(printf '%s' "${BODY}" | head -c 200)"
fi

# Reading the budget must be free. If it is not, every dashboard that polls this
# endpoint becomes a slow drain on the budget it is displaying - a bug that is
# almost impossible to notice by inspection.
BEFORE="$(remaining)"
curl -sS -m 30 -o /dev/null "${BASE}/v1/budget" -H "${AUTH}"
curl -sS -m 30 -o /dev/null "${BASE}/v1/budget" -H "${AUTH}"
AFTER="$(remaining)"
if [ "${BEFORE}" = "${AFTER}" ]; then
  ok "reading the budget costs nothing (${BEFORE} ${CURRENCY} unchanged)"
else
  bad "budget changed from reading it: ${BEFORE} -> ${AFTER}" \
      "AM-SetZeroWeight is not taking effect on the /v1/budget flow"
fi

# ==============================================================================
group "Unary generation"
# ==============================================================================

BEFORE="$(remaining)"
RESP="$(curl -sS -m 120 -D /tmp/smoke-headers.$$ \
  -X POST "${BASE}/v1/models/${MODEL}:generateContent" \
  -H "${AUTH}" -H "${JSON}" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Name three primary colours."}]}]}')"

if printf '%s' "${RESP}" | jq -e '.candidates[0].content' >/dev/null 2>&1; then
  ok "generateContent returns a completion"
else
  bad "generateContent did not return a completion" "$(printf '%s' "${RESP}" | head -c 300)"
fi

COST_HDR="$(grep -i '^X-Budget-Call-Cost:' /tmp/smoke-headers.$$ | tr -d '\r' | cut -d' ' -f2-)"
REM_HDR="$(grep -i '^X-Budget-Remaining:' /tmp/smoke-headers.$$ | tr -d '\r' | cut -d' ' -f2-)"
if [ -n "${COST_HDR}" ] && [ -n "${REM_HDR}" ]; then
  ok "response carries cost headers (cost ${COST_HDR}, remaining ${REM_HDR} ${CURRENCY})"
else
  bad "cost headers missing" "AM-AddBudgetHeaders did not run, or the variables it reads were never set"
fi

AFTER="$(remaining)"
if awk -v a="${BEFORE}" -v b="${AFTER}" 'BEGIN { exit !(b < a) }'; then
  ok "budget decreased: ${BEFORE} -> ${AFTER} ${CURRENCY}"
else
  bad "budget did not decrease after a completed call (${BEFORE} -> ${AFTER})" \
      "the response leg is not charging - see docs/13-validation-gates.md gate 1"
fi

# The response leg exists to charge output tokens. If the total charged equals
# the input-only estimate, the split-charge mechanism is half-broken in the
# expensive direction: output is 3-5x the input rate and is going unbilled.
if [ -n "${COST_HDR}" ] && awk -v c="${COST_HDR}" 'BEGIN { exit !(c > 0) }'; then
  ok "charge is non-zero"
else
  bad "call cost reported as ${COST_HDR:-empty}"
fi

# ==============================================================================
group "Streaming"
# ==============================================================================

BEFORE="$(remaining)"
STREAM="$(curl -sS -m 120 -N \
  -X POST "${BASE}/v1/models/${MODEL}:streamGenerateContent?alt=sse" \
  -H "${AUTH}" -H "${JSON}" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Count from one to ten."}]}]}')"

if printf '%s' "${STREAM}" | grep -q '^data:'; then
  ok "streamGenerateContent returns server-sent events"
else
  bad "no SSE events received" "$(printf '%s' "${STREAM}" | head -c 300)"
fi

# Give the response flow a moment: the final charge happens after the stream
# closes, and the counter write is asynchronous from the client's point of view.
sleep 3
AFTER="$(remaining)"
if awk -v a="${BEFORE}" -v b="${AFTER}" 'BEGIN { exit !(b < a) }'; then
  ok "streaming call was charged: ${BEFORE} -> ${AFTER} ${CURRENCY}"
else
  bad "streaming call was not charged (${BEFORE} -> ${AFTER})" \
      "streaming would be a free lane around the cap - see docs/08-streaming.md"
fi

# ==============================================================================
group "Refusals"
# ==============================================================================

CODE="$(curl -sS -m 60 -o /tmp/smoke-403.$$ -w '%{http_code}' \
  -X POST "${BASE}/v1/models/definitely-not-a-real-model:generateContent" \
  -H "${AUTH}" -H "${JSON}" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}')"
if [ "${CODE}" = "403" ]; then
  ok "disallowed model refused with 403"
else
  bad "disallowed model returned ${CODE}, expected 403" "$(head -c 200 /tmp/smoke-403.$$)"
fi

CODE="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' "${BASE}/v1/nonexistent" -H "${AUTH}")"
if [ "${CODE}" = "404" ]; then
  ok "unknown path refused with 404"
else
  bad "unknown path returned ${CODE}, expected 404" \
      "an unmatched path that reaches the target is an unmetered proxy"
fi

CODE="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' \
  -X POST "${BASE}/v1/models/${MODEL}:generateContent" -H "${JSON}" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}')"
if [ "${CODE}" = "401" ]; then
  ok "unauthenticated call refused with 401"
else
  bad "unauthenticated call returned ${CODE}, expected 401"
fi

# ==============================================================================
group "Cap enforcement"
# ==============================================================================

if [ "${SMOKE_TEST_EXHAUST_BUDGET:-false}" != "true" ]; then
  printf '  \033[33mskip\033[0m  cap exhaustion test\n'
  printf '        This test spends a real budget down to zero. To run it:\n'
  printf '        SMOKE_TEST_EXHAUST_BUDGET=true make smoke\n'
  printf '        Use a test subject on a tier with a small cap.\n'
else
  echo "  spending down to the cap (this takes a while by design)..."
  HIT=0
  for i in $(seq 1 200); do
    CODE="$(curl -sS -m 120 -o /tmp/smoke-429.$$ -w '%{http_code}' \
      -X POST "${BASE}/v1/models/${MODEL}:generateContent" \
      -H "${AUTH}" -H "${JSON}" \
      -d '{"contents":[{"role":"user","parts":[{"text":"Write a detailed paragraph about the sea."}]}]}')"
    if [ "${CODE}" = "429" ]; then HIT=${i}; break; fi
    if [ "${CODE}" != "200" ]; then
      bad "unexpected ${CODE} while spending down" "$(head -c 200 /tmp/smoke-429.$$)"
      break
    fi
  done

  if [ "${HIT}" -gt 0 ]; then
    ok "cap enforced after ${HIT} calls"

    BODY="$(cat /tmp/smoke-429.$$)"
    for field in error.reason error.breached_limit error.resets_in_seconds; do
      if printf '%s' "${BODY}" | jq -e ".${field}" >/dev/null 2>&1; then
        ok "429 body carries ${field}"
      else
        bad "429 body is missing ${field}" "a refusal the caller cannot act on generates a support ticket"
      fi
    done

    if grep -qi '^Retry-After:' /tmp/smoke-headers.$$ 2>/dev/null || \
       printf '%s' "${BODY}" | jq -e '.error.resets_in_seconds > 0' >/dev/null 2>&1; then
      ok "caller is told when the budget resets"
    else
      bad "no reset time offered"
    fi

    # The overshoot bound is the promise this design makes: a caller can end a
    # period at most one forced-maxOutputTokens response past their cap. If the
    # final balance is further past zero than that, the ceiling is not being
    # enforced on the request the model actually received.
    CEILING="$(jq -r '.limits.maxOutputTokens' "${ROOT_DIR}/config/runtime-config.json")"
    MAXOUT="$(jq -r '[.models[].output] | max' "${ROOT_DIR}/config/pricing.json")"
    BOUND="$(awk -v c="${CEILING}" -v p="${MAXOUT}" 'BEGIN { printf "%.6f", (c * p) / 1000000 }')"
    FINAL="$(remaining)"
    if awk -v f="${FINAL}" -v b="${BOUND}" 'BEGIN { exit !(f >= -b) }'; then
      ok "overshoot within the stated bound (final ${FINAL}, bound ${BOUND} ${CURRENCY})"
    else
      bad "overshoot exceeded the bound (final ${FINAL}, bound ${BOUND} ${CURRENCY})" \
          "the gateway is not overwriting generationConfig.maxOutputTokens"
    fi
  else
    bad "never hit the cap in 200 calls" "either the budget is very large, or enforcement is off"
  fi
fi

rm -f /tmp/smoke-headers.$$ /tmp/smoke-403.$$ /tmp/smoke-429.$$

printf '\n\033[1mResult\033[0m  %d passed, %d failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
