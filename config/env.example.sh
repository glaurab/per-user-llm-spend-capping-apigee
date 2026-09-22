#!/usr/bin/env bash
#
# Deployment environment for the LLM spend gateway.
#
#   cp config/env.example.sh config/env.sh   &&   edit   &&   make deploy
#
# config/env.sh is gitignored. Nothing secret belongs in it - these are all
# identifiers and endpoints - but it is environment-specific, so keeping it out
# of version control avoids the classic accident of deploying a development
# configuration into production because someone committed their own copy.
#
# TWO KINDS OF SETTING LIVE IN THIS PROJECT, AND THEY ARE NOT INTERCHANGEABLE
# ---------------------------------------------------------------------------
# The variables in THIS file are baked into the proxy bundle at build time. They
# are the settings Apigee cannot resolve from a flow variable: a JWKS URI, a
# ServiceCallout hostname, a SpikeArrest rate. Changing any of them requires a
# rebuild and redeploy of the proxy.
#
# Everything else - prices, budgets, allowed models, the output ceiling, the
# fail mode - lives in the three JSON files next to this one and is served from
# a key value map at runtime. Those change with `make seed` and take effect
# within the cache TTL, with no redeploy and no revision bump.
#
# When you are deciding where a new setting belongs, prefer the KVM. The only
# things that should ever end up in this file are the ones Apigee's policy
# schema refuses to template.

# =============================================================================
# Apigee
# =============================================================================

# The Apigee organization. This project assumes it already exists: its control
# plane location and analytics region are fixed at creation and cannot be
# changed afterwards, so provisioning it is a deliberate manual step documented
# in docs/06-deployment.md rather than something Terraform does for you.
export APIGEE_ORG="your-apigee-org"

# Environment and environment group. Terraform creates these.
export APIGEE_ENV="llm-gateway"
export APIGEE_ENVGROUP="llm-gateway-group"

# The hostname clients will call. Must be covered by the environment group's
# TLS certificate.
export APIGEE_HOSTNAME="llm.example.internal"

# Proxy bundle name. Must match the directory under proxy/ and the name
# attribute in llm-gateway.xml.
export PROXY_NAME="llm-gateway"

# Key value map holding pricing, budgets and runtime-config. Environment-scoped.
export KVM_NAME="llm-gateway-config"

# =============================================================================
# Inference target
# =============================================================================

# Project that will be billed for model usage, and the region it runs in.
export INFERENCE_PROJECT_ID="your-inference-project-id"
export INFERENCE_LOCATION="REGION"

# Scheme + host of the inference endpoint. Substituted into the ServiceCallout
# policies at build time as @@VERTEX_HOST@@.
#
# There are three forms and they are not variations on a theme:
#
#   regional      https://REGION-aiplatform.googleapis.com
#   multi-region  https://aiplatform.JURISDICTION.rep.googleapis.com
#   global        https://aiplatform.googleapis.com
#
# Note that the multi-region form is inverted relative to the regional one.
# Guessing by analogy produces a hostname that does not exist, and the failure
# arrives as a DNS error at request time rather than at deploy time.
# scripts/preflight-check.sh resolves this value before you deploy, precisely
# so that mistake is caught early. See docs/11-regions-and-residency.md.
export VERTEX_HOST="https://REGION-aiplatform.googleapis.com"

# The service account the Apigee runtime uses to call the model. Terraform
# creates it and grants it the narrowest role that works - prediction only, on
# the inference project alone. See terraform/iam.tf and docs/10-security.md.
export RUNTIME_SA_EMAIL="llm-gateway-runtime@your-apigee-org.iam.gserviceaccount.com"

# =============================================================================
# Caller identity
# =============================================================================

# Where VerifyJWT fetches signing keys, and what it demands of the token.
# Substituted at build time as @@OIDC_JWKS_URI@@ / @@OIDC_ISSUER@@ /
# @@OIDC_AUDIENCE@@.
#
# The audience check is not decoration. Without it, any token your identity
# provider ever issued - including one minted for an unrelated application -
# is accepted here, and the caller's spend is charged to whoever that token's
# subject happens to be. See docs/04-identity.md.
export OIDC_JWKS_URI="https://your-idp.example.com/.well-known/jwks.json"
export OIDC_ISSUER="https://your-idp.example.com/"
export OIDC_AUDIENCE="llm-gateway"

# =============================================================================
# Protection and operations
# =============================================================================

# SpikeArrest rate per caller token, as Apigee expresses it ("Npm" or "Nps").
# This is burst protection, not access control: it is keyed on the presented
# token, which an attacker can rotate. Its job is to stop one runaway loop from
# emptying a budget in seconds, which it does well.
export SPIKE_ARREST_RATE="30pm"

# Shown to users in the 429 body so a blocked caller knows who to ask for more
# budget. A refusal with no route to resolution generates a support ticket
# against the platform team instead of against the budget owner.
export ESCALATION_CONTACT="platform-team@example.com"

# Model Armor endpoint, only used when features.modelArmorEnabled is true in
# runtime-config.json. Substituted as @@MODEL_ARMOR_HOST@@.
export MODEL_ARMOR_HOST="https://modelarmor.REGION.rep.googleapis.com"

# =============================================================================
# Local paths
# =============================================================================

export CONFIG_DIR="${CONFIG_DIR:-config}"
export BUILD_DIR="${BUILD_DIR:-.build}"
