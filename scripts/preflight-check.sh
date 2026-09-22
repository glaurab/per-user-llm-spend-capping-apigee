#!/usr/bin/env bash
#
# preflight-check.sh - assert that everything this gateway depends on actually
# exists, BEFORE a bundle is deployed and traffic is pointed at it.
#
# Every check here corresponds to a failure that is cheap to catch now and
# expensive to diagnose later, because the symptom appears at request time, in
# a proxy, as a 500 with no useful body.
#
# Exit code 0 means deploy. Anything else means fix something first.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/config/env.sh"

PASS=0
FAIL=0
WARN=0

ok()    { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
warn()  { printf '  \033[33mwarn\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; WARN=$((WARN + 1)); }
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ==============================================================================
group "Tooling"
# ==============================================================================

for tool in gcloud curl jq apigeecli; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool is on PATH"
  else
    bad "$tool is not on PATH" "apigeecli: https://github.com/apigee/apigeecli"
  fi
done

TOKEN="$(gcloud auth print-access-token 2>/dev/null)"
if [ -n "${TOKEN}" ]; then
  ok "gcloud has a usable access token"
else
  bad "gcloud could not mint an access token" "run: gcloud auth login"
  echo; echo "Cannot continue without credentials."; exit 1
fi

# ==============================================================================
group "Configuration files"
# ==============================================================================

for f in runtime-config.json pricing.json budgets.json; do
  path="${ROOT_DIR}/config/${f}"
  if [ ! -f "${path}" ]; then
    bad "config/${f} is missing" "copy the matching .example.json and edit it"
  elif jq empty "${path}" >/dev/null 2>&1; then
    ok "config/${f} is valid JSON"
  else
    bad "config/${f} is not valid JSON" "$(jq empty "${path}" 2>&1 | head -1)"
  fi
done

# The single most common configuration mistake: a model is allowed but has no
# price. The gateway refuses those calls at runtime (MODEL_NOT_PRICED) rather
# than serving them free, which is correct but looks like an outage to the user
# who happened to pick that model.
if [ -f "${ROOT_DIR}/config/runtime-config.json" ] && [ -f "${ROOT_DIR}/config/pricing.json" ]; then
  UNPRICED="$(jq -r --slurpfile p "${ROOT_DIR}/config/pricing.json" \
    '.allowedModels[] | select(. as $m | ($p[0].models | has($m)) | not)' \
    "${ROOT_DIR}/config/runtime-config.json" 2>/dev/null | tr '\n' ' ')"
  if [ -z "${UNPRICED// /}" ]; then
    ok "every allowed model has a price"
  else
    bad "allowed models with no price entry: ${UNPRICED}" \
        "add them to config/pricing.json, or remove them from allowedModels"
  fi

  # The reverse is harmless but worth surfacing: a priced model nobody may use
  # is usually a leftover from an allowlist change.
  ORPHANS="$(jq -r --slurpfile r "${ROOT_DIR}/config/runtime-config.json" \
    '.models | keys[] | select(. as $m | ($r[0].allowedModels | index($m)) == null)' \
    "${ROOT_DIR}/config/pricing.json" 2>/dev/null | tr '\n' ' ')"
  [ -n "${ORPHANS// /}" ] && warn "priced but not allowed: ${ORPHANS}" "harmless; probably a stale entry"
fi

# A budget of zero is not a cap, it is an outage. Catch it here rather than in
# a support ticket from every user in that tier.
if [ -f "${ROOT_DIR}/config/budgets.json" ]; then
  ZERO="$(jq -r '.tiers | to_entries[] | select((.value.userDaily // 0) <= 0) | .key' \
    "${ROOT_DIR}/config/budgets.json" 2>/dev/null | tr '\n' ' ')"
  if [ -z "${ZERO// /}" ]; then
    ok "no tier has a zero or negative daily budget"
  else
    bad "tiers with no usable daily budget: ${ZERO}" "every call from these tiers will be refused"
  fi
fi

# ==============================================================================
group "Apigee"
# ==============================================================================

if gcloud apigee organizations describe "${APIGEE_ORG}" >/dev/null 2>&1; then
  ok "organization ${APIGEE_ORG} exists"
else
  bad "organization ${APIGEE_ORG} not found or not visible" \
      "org creation is a manual step - see docs/06-deployment.md"
fi

if apigeecli environments get -e "${APIGEE_ENV}" -o "${APIGEE_ORG}" -t "${TOKEN}" >/dev/null 2>&1; then
  ok "environment ${APIGEE_ENV} exists"
else
  bad "environment ${APIGEE_ENV} not found" "run terraform apply first"
fi

if apigeecli kvms list -e "${APIGEE_ENV}" -o "${APIGEE_ORG}" -t "${TOKEN}" 2>/dev/null | grep -q "\"${KVM_NAME}\""; then
  ok "key value map ${KVM_NAME} exists"
else
  bad "key value map ${KVM_NAME} not found in ${APIGEE_ENV}" "run terraform apply first"
fi

# ==============================================================================
group "Runtime identity"
# ==============================================================================

if gcloud iam service-accounts describe "${RUNTIME_SA_EMAIL}" >/dev/null 2>&1; then
  ok "runtime service account exists"
else
  bad "runtime service account ${RUNTIME_SA_EMAIL} not found" "run terraform apply first"
fi

# The binding whose absence produces a 500 at request time and nothing at all
# at deploy time. See terraform/iam.tf.
PROJECT_NUMBER="$(gcloud projects describe "${APIGEE_ORG}" --format='value(projectNumber)' 2>/dev/null)"
AGENT="service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"
if [ -n "${PROJECT_NUMBER}" ] && gcloud iam service-accounts get-iam-policy "${RUNTIME_SA_EMAIL}" \
     --format=json 2>/dev/null | jq -e --arg a "serviceAccount:${AGENT}" \
     '.bindings[]? | select(.role=="roles/iam.serviceAccountUser") | .members[]? | select(. == $a)' >/dev/null; then
  ok "Apigee service agent may impersonate the runtime account"
else
  bad "Apigee service agent lacks roles/iam.serviceAccountUser on ${RUNTIME_SA_EMAIL}" \
      "without this the proxy deploys cleanly and then fails every call with a target auth error"
fi

# ==============================================================================
group "Inference endpoint"
# ==============================================================================

# The trap this check exists for: the regional form is REGION-aiplatform.
# googleapis.com but the multi-region form is aiplatform.JURISDICTION.rep.
# googleapis.com - inverted. Deriving one from the other by analogy produces a
# hostname that does not resolve, and the failure surfaces as an opaque 503
# from the proxy at request time.
VERTEX_FQDN="${VERTEX_HOST#https://}"
VERTEX_FQDN="${VERTEX_FQDN%%/*}"

if getent hosts "${VERTEX_FQDN}" >/dev/null 2>&1 || host "${VERTEX_FQDN}" >/dev/null 2>&1; then
  ok "${VERTEX_FQDN} resolves"
else
  bad "${VERTEX_FQDN} does not resolve" \
      "check the endpoint form - see docs/11-regions-and-residency.md"
fi

# End to end: can this project actually generate content with the first allowed
# model, and does the response carry usageMetadata? If it does not, the entire
# cost model has nothing to reconcile against and the gateway will fall back to
# ceiling charging on every call.
FIRST_MODEL="$(jq -r '.allowedModels[0] // empty' "${ROOT_DIR}/config/runtime-config.json" 2>/dev/null)"
if [ -n "${FIRST_MODEL}" ]; then
  URL="${VERTEX_HOST}/v1/projects/${INFERENCE_PROJECT_ID}/locations/${INFERENCE_LOCATION}/publishers/google/models/${FIRST_MODEL}:generateContent"
  BODY='{"contents":[{"role":"user","parts":[{"text":"ping"}]}],"generationConfig":{"maxOutputTokens":8}}'
  RESP="$(curl -sS -m 60 -X POST "${URL}" \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${BODY}" 2>&1)"

  if printf '%s' "${RESP}" | jq -e '.usageMetadata.totalTokenCount' >/dev/null 2>&1; then
    ok "${FIRST_MODEL} responds and reports usageMetadata"
    printf '        %s\n' "$(printf '%s' "${RESP}" | jq -c '.usageMetadata')"
  else
    bad "no usable response from ${FIRST_MODEL}" "$(printf '%s' "${RESP}" | head -c 300)"
  fi

  # countTokens is what makes the request-leg charge exact rather than
  # estimated. It is free, so there is no reason not to use it - but the
  # gateway degrades to a character-based estimate if it is unavailable, and
  # you should know which of the two you are running on.
  CT_URL="${VERTEX_HOST}/v1/projects/${INFERENCE_PROJECT_ID}/locations/${INFERENCE_LOCATION}/publishers/google/models/${FIRST_MODEL}:countTokens"
  if curl -sS -m 30 -X POST "${CT_URL}" \
       -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
       -d '{"contents":[{"role":"user","parts":[{"text":"ping"}]}]}' 2>/dev/null \
       | jq -e '.totalTokens' >/dev/null 2>&1; then
    ok "countTokens is available (request-leg charges will be exact)"
  else
    warn "countTokens did not respond" "the gateway will fall back to estimating input size from character count"
  fi
fi

# ==============================================================================
group "Identity provider"
# ==============================================================================

JWKS="$(curl -sS -m 15 "${OIDC_JWKS_URI}" 2>&1)"
if printf '%s' "${JWKS}" | jq -e '.keys | length > 0' >/dev/null 2>&1; then
  ok "JWKS endpoint returns $(printf '%s' "${JWKS}" | jq -r '.keys | length') key(s)"
else
  bad "JWKS endpoint returned nothing usable" "${OIDC_JWKS_URI}"
fi

if [ -z "${OIDC_AUDIENCE:-}" ]; then
  bad "OIDC_AUDIENCE is empty" \
      "without an audience check, any token your IdP ever issued is accepted here"
else
  ok "audience is set (${OIDC_AUDIENCE})"
fi

# ==============================================================================
printf '\n\033[1mResult\033[0m  %d passed, %d warnings, %d failed\n\n' "${PASS}" "${WARN}" "${FAIL}"

if [ "${FAIL}" -gt 0 ]; then
  echo "Not ready to deploy."
  exit 1
fi
echo "Ready to deploy."
