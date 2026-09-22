# ==============================================================================
# Apigee environment, environment group and configuration store.
#
# The organization is assumed to exist - see the note in versions.tf for why
# this configuration refuses to create it.
# ==============================================================================

data "google_project" "host" {
  project_id = var.project_id
}

# ------------------------------------------------------------------------------
# Environment.
#
# A dedicated environment rather than a shared one. Two reasons that are worth
# stating rather than assuming:
#
#   Quota counters are environment-scoped. Deploying this proxy into an
#   environment shared with unrelated traffic means unrelated traffic shares the
#   counter store, and a noisy neighbour's incident becomes your budget outage.
#
#   The runtime service account is attached at deployment and can call the
#   inference API. Confining that capability to one environment keeps the
#   blast radius of a misconfigured proxy to proxies you reviewed.
# ------------------------------------------------------------------------------
resource "google_apigee_environment" "gateway" {
  org_id       = "organizations/${var.apigee_org}"
  name         = var.environment_name
  display_name = "LLM spend gateway"
  description  = "Metered egress to the model API. Managed by Terraform."
  type         = var.environment_type

  # Apigee refuses to delete an environment that still has deployed proxies, so
  # a destroy will fail loudly rather than quietly taking the gateway offline
  # while something still depends on it. That is the desired behaviour; undeploy
  # first with `make undeploy` if you genuinely mean it.
}

resource "google_apigee_envgroup" "gateway" {
  org_id    = "organizations/${var.apigee_org}"
  name      = var.envgroup_name
  hostnames = var.gateway_hostnames
}

resource "google_apigee_envgroup_attachment" "gateway" {
  envgroup_id = google_apigee_envgroup.gateway.id
  environment = google_apigee_environment.gateway.name
}

resource "google_apigee_instance_attachment" "gateway" {
  instance_id = "organizations/${var.apigee_org}/instances/${var.apigee_instance_id}"
  environment = google_apigee_environment.gateway.name
}

# ------------------------------------------------------------------------------
# Configuration store.
#
# Terraform creates the map; scripts/seed-kvm.sh writes the three entries
# (pricing, budgets, runtime-config). The split is deliberate and explained in
# versions.tf: container here, content there.
#
# Note what this means operationally. A price change or an emergency budget
# increase is a `make seed` - seconds, no plan review, no proxy revision, no
# state lock. That is the right ergonomics for the settings that change under
# time pressure.
# ------------------------------------------------------------------------------
resource "google_apigee_environment_keyvaluemaps" "config" {
  env_id = google_apigee_environment.gateway.id
  name   = var.kvm_name
}

# ------------------------------------------------------------------------------
# NOTE ON DATA COLLECTORS
#
# DC-CaptureUsage publishes ten custom dimensions into analytics, and each one
# needs a matching data collector to exist in the organization first. The Google
# Terraform provider has no resource for those, so they are created by
# scripts/deploy-proxy.sh via apigeecli, which is idempotent and safe to re-run.
#
# A missing collector does not fail a request - DC-CaptureUsage carries
# continueOnError - it just silently drops that dimension. If a chart in your
# spend dashboard is inexplicably empty, this is the first thing to check.
# ------------------------------------------------------------------------------
