#!/usr/bin/env bash
#
# seed-kvm.sh - push pricing, budgets and runtime configuration into the KVM.
#
# This is the fast path. Everything that changes under time pressure - a price
# correction, an emergency budget increase, flipping the fail mode, turning
# enforcement off during an incident - is a file edit and one run of this
# script. No proxy revision, no Terraform plan, no state lock.
#
# Changes take effect within the KVM cache TTL, which the KVM-Load* policies set
# to 300 seconds. That is a deliberate compromise: shorter means more reads on
# the hot path, longer means a budget change that appears not to work. If you
# need an immediate effect, redeploying the proxy clears the cache.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/config/env.sh"

TOKEN="$(gcloud auth print-access-token)"

# ------------------------------------------------------------------------------
# Validate before writing.
#
# A malformed entry does not fail here - it fails at request time, in
# JS-BuildIdentityKeys, as CONFIG_UNAVAILABLE, which is fail-closed. Every call
# stops. Pushing unparseable JSON into this map is therefore an outage, and it
# is trivially preventable.
# ------------------------------------------------------------------------------

for f in pricing budgets runtime-config; do
  path="${ROOT_DIR}/config/${f}.json"
  [ -f "${path}" ] || { echo "ERROR: ${path} is missing." >&2; exit 1; }
  jq empty "${path}" >/dev/null 2>&1 || { echo "ERROR: ${path} is not valid JSON." >&2; exit 1; }
done

# Refuse to seed a configuration that would refuse every call. The runtime
# already handles an unpriced model correctly, but it handles it by returning
# 503 to the user, and finding out that way is worse than finding out here.
UNPRICED="$(jq -r --slurpfile p "${ROOT_DIR}/config/pricing.json" \
  '.allowedModels[] | select(. as $m | ($p[0].models | has($m)) | not)' \
  "${ROOT_DIR}/config/runtime-config.json" | tr '\n' ' ')"
if [ -n "${UNPRICED// /}" ]; then
  echo "ERROR: allowed models with no price: ${UNPRICED}" >&2
  echo "       Add prices, or remove them from allowedModels." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Write.
#
# Delete-then-create rather than update, because the entry may not exist yet and
# apigeecli distinguishes the two. jq -c compacts the JSON: the value is stored
# as a single string, and whitespace in it is stored bytes with no benefit.
# ------------------------------------------------------------------------------

put() {
  local key="$1" file="$2"
  local value
  value="$(jq -c '.' "${ROOT_DIR}/config/${file}")"

  apigeecli kvms entries delete \
    -m "${KVM_NAME}" -k "${key}" \
    -e "${APIGEE_ENV}" -o "${APIGEE_ORG}" -t "${TOKEN}" >/dev/null 2>&1 || true

  apigeecli kvms entries create \
    -m "${KVM_NAME}" -k "${key}" -l "${value}" \
    -e "${APIGEE_ENV}" -o "${APIGEE_ORG}" -t "${TOKEN}" >/dev/null

  echo "    ${key} (${#value} bytes)"
}

echo "==> Seeding ${KVM_NAME} in ${APIGEE_ENV}"
put pricing        pricing.json
put budgets        budgets.json
put runtime-config runtime-config.json

# ------------------------------------------------------------------------------
# Report what was actually just made true, in the terms an operator cares about.
# ------------------------------------------------------------------------------

ENFORCE="$(jq -r '.features.enforce' "${ROOT_DIR}/config/runtime-config.json")"
FAILMODE="$(jq -r '.failMode' "${ROOT_DIR}/config/runtime-config.json")"
CEILING="$(jq -r '.limits.maxOutputTokens' "${ROOT_DIR}/config/runtime-config.json")"
CURRENCY="$(jq -r '.currency' "${ROOT_DIR}/config/budgets.json")"

echo
echo "Configuration now live (within the 300s cache TTL):"
echo "    enforcement      ${ENFORCE}"
echo "    fail mode        ${FAILMODE}"
echo "    output ceiling   ${CEILING} tokens"
echo "    currency         ${CURRENCY}"
echo
jq -r --arg c "${CURRENCY}" \
  '"    tiers            " + ([.tiers | to_entries[] | "\(.key)=\(.value.userDaily)/day"] | join(", ")) + " " + $c' \
  "${ROOT_DIR}/config/budgets.json"

if [ "${ENFORCE}" = "false" ]; then
  echo
  echo "NOTE: enforcement is OFF. The gateway is metering, logging and reporting"
  echo "      budgets, but refusing nothing. This is the correct setting while you"
  echo "      calibrate caps against real usage - and the wrong one to leave in"
  echo "      place afterwards."
fi

# Worst-case overshoot, computed rather than asserted. This is the number to put
# in a governance document, and the reason the gateway overwrites the client's
# maxOutputTokens instead of trusting it.
MAXOUT="$(jq -r '[.models[].output] | max' "${ROOT_DIR}/config/pricing.json")"
echo
awk -v c="${CEILING}" -v p="${MAXOUT}" -v cur="${CURRENCY}" \
  'BEGIN { printf "    Worst-case overshoot past a cap: %.4f %s\n", (c * p) / 1000000, cur }'
echo "    (output ceiling x the highest output price in the table - one call"
echo "     that starts under the cap and finishes over it)"
