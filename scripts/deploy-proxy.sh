#!/usr/bin/env bash
#
# deploy-proxy.sh - build the proxy bundle and deploy it.
#
# THREE STEPS, AND THE FIRST ONE NEEDS EXPLAINING
#
#   1. Substitute build-time placeholders into a copy of the bundle.
#   2. Ensure the analytics data collectors exist.
#   3. Import the bundle and deploy the new revision with the runtime identity.
#
# Why step 1 exists at all: Apigee resolves flow variables at request time, but
# a handful of policy fields are read when the policy is compiled, not when it
# runs - a JWKS URI, a ServiceCallout hostname, a SpikeArrest rate. Those cannot
# come from a key value map, so they are written into the bundle as @@TOKEN@@
# and replaced here.
#
# Everything the KVM CAN hold is in the KVM. If you find yourself adding a
# placeholder, check first whether the setting could be a flow variable instead:
# placeholders require a redeploy, KVM entries do not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/config/env.sh"

BUILD_DIR="${ROOT_DIR}/${BUILD_DIR:-.build}"
SRC="${ROOT_DIR}/proxy/${PROXY_NAME}/apiproxy"
DEST="${BUILD_DIR}/${PROXY_NAME}/apiproxy"

TOKEN="$(gcloud auth print-access-token)"

# ------------------------------------------------------------------------------
# 1. Build
# ------------------------------------------------------------------------------

echo "==> Building bundle"

rm -rf "${BUILD_DIR:?}/${PROXY_NAME}"
mkdir -p "$(dirname "${DEST}")"
cp -R "${SRC}" "${DEST}"

# sed treats & and the delimiter specially in a replacement. URLs contain both
# often enough that not escaping them produces a corrupt bundle that deploys
# successfully and then behaves strangely - the worst kind of failure.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

substitute() {
  local token="$1" value="$2"
  if [ -z "${value}" ]; then
    echo "    ERROR: ${token} is empty. Set it in config/env.sh." >&2
    exit 1
  fi
  local escaped
  escaped="$(sed_escape "${value}")"
  find "${DEST}" -type f -name '*.xml' -exec sed -i.bak "s|@@${token}@@|${escaped}|g" {} +
  find "${DEST}" -name '*.bak' -delete
  echo "    ${token} -> ${value}"
}

substitute OIDC_JWKS_URI      "${OIDC_JWKS_URI}"
substitute OIDC_ISSUER        "${OIDC_ISSUER}"
substitute OIDC_AUDIENCE      "${OIDC_AUDIENCE}"
substitute VERTEX_HOST        "${VERTEX_HOST}"
substitute MODEL_ARMOR_HOST   "${MODEL_ARMOR_HOST}"
substitute SPIKE_ARREST_RATE  "${SPIKE_ARREST_RATE}"
substitute ESCALATION_CONTACT "${ESCALATION_CONTACT}"

# A placeholder that survives the build becomes a literal @@TOKEN@@ inside a
# policy. Some of those fail at deploy; others - a JWKS URI, for instance - fail
# only when the first request arrives. Refuse to ship either.
if grep -rq '@@[A-Z_]*@@' "${DEST}"; then
  echo "    ERROR: unsubstituted placeholders remain:" >&2
  grep -rlo '@@[A-Z_]*@@' "${DEST}" >&2
  exit 1
fi
echo "    no placeholders remain"

# ------------------------------------------------------------------------------
# 2. Analytics data collectors
#
# Created here rather than in Terraform because the Google provider has no
# resource for them. Idempotent: a collector that already exists reports an
# error we deliberately ignore, since there is nothing to change.
# ------------------------------------------------------------------------------

echo "==> Ensuring data collectors"

ensure_collector() {
  local name="$1" type="$2" desc="$3"
  if apigeecli datacollectors create -n "${name}" -p "${type}" -d "${desc}" \
       -o "${APIGEE_ORG}" -t "${TOKEN}" >/dev/null 2>&1; then
    echo "    created ${name}"
  else
    echo "    ${name} already present"
  fi
}

ensure_collector dc_tier            STRING  "Budget tier of the caller"
ensure_collector dc_team            STRING  "Team the caller is charged to"
ensure_collector dc_subject         STRING  "Opaque caller identifier"
ensure_collector dc_model           STRING  "Model that served the request"
ensure_collector dc_cost_micros     INTEGER "Call cost in micro-units of the billing currency"
ensure_collector dc_tokens_in       INTEGER "Prompt tokens"
ensure_collector dc_tokens_out      INTEGER "Candidate tokens"
ensure_collector dc_tokens_thoughts INTEGER "Reasoning tokens"
ensure_collector dc_tokens_cached   INTEGER "Cached prompt tokens"
ensure_collector dc_decision        STRING  "Enforcement outcome"

# ------------------------------------------------------------------------------
# 3. Import and deploy
# ------------------------------------------------------------------------------

echo "==> Importing bundle"

REVISION="$(apigeecli apis create bundle \
  -f "${DEST}" \
  -n "${PROXY_NAME}" \
  -o "${APIGEE_ORG}" \
  -t "${TOKEN}" | jq -r '.revision')"

if [ -z "${REVISION}" ] || [ "${REVISION}" = "null" ]; then
  echo "    ERROR: import did not return a revision." >&2
  exit 1
fi
echo "    imported revision ${REVISION}"

echo "==> Deploying revision ${REVISION} to ${APIGEE_ENV}"

# --ovr replaces the currently deployed revision. --wait blocks until the
# deployment is actually serving, so a failure here is a failure of this script
# rather than a surprise discovered by the first user.
#
# -s attaches the runtime service account. Without it the proxy deploys and then
# cannot authenticate to the model, because <GoogleAccessToken> in
# targets/vertex.xml has no identity to mint a token for.
apigeecli apis deploy \
  -n "${PROXY_NAME}" \
  -v "${REVISION}" \
  -e "${APIGEE_ENV}" \
  -o "${APIGEE_ORG}" \
  -s "${RUNTIME_SA_EMAIL}" \
  --ovr --wait \
  -t "${TOKEN}"

echo
echo "Deployed ${PROXY_NAME} revision ${REVISION} to ${APIGEE_ENV}."
echo "Base URL: https://${APIGEE_HOSTNAME}/llm"
echo
echo "Next: make smoke"
