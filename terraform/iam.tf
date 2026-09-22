# ==============================================================================
# The runtime identity.
#
# THIS FILE IS WHAT MAKES THE GATEWAY MEAN ANYTHING.
#
# A metering proxy is not a control. It is a control only if it is the sole path
# to the thing being metered. If an end user can obtain credentials that reach
# aiplatform.googleapis.com directly, the gateway is a courtesy, and the first
# person to read the API documentation stops using it.
#
# So there are two halves to the security model, and only one of them lives
# here:
#
#   1. The gateway holds a narrow, dedicated identity that can call the model.
#      That is this file.
#
#   2. Nobody else holds any identity that can. That is an audit of your
#      existing IAM bindings, and Terraform cannot do it for you because it
#      cannot see grants it did not create. docs/10-security.md contains the
#      query to run and the list of principals to look for.
#
# Step 2 is the one teams skip.
# ==============================================================================

resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = var.runtime_sa_id
  display_name = "LLM gateway runtime"
  description  = "Used by the Apigee proxy to call the inference API. Should be the only identity permitted to do so."
}

# ------------------------------------------------------------------------------
# Least privilege for inference.
#
# roles/aiplatform.user is the obvious choice and it is much too broad: it also
# allows creating tuning jobs, deploying endpoints, and reading datasets. This
# proxy makes exactly three kinds of call - countTokens, generateContent and
# streamGenerateContent - and all three are covered by the predict permissions
# below.
#
# If you later add a feature that needs more, add the specific permission here
# rather than reaching for the predefined role. The narrow role is also the
# reason the "revoke and confirm calls fail" test in docs/06-deployment.md is
# meaningful: there is exactly one binding to revoke.
# ------------------------------------------------------------------------------
resource "google_project_iam_custom_role" "inference_only" {
  count = var.grant_predict_via_custom_role ? 1 : 0

  project     = var.inference_project_id
  role_id     = "llmGatewayInference"
  title       = "LLM gateway inference"
  description = "Predict-only access to the model API, for the metered gateway."

  permissions = [
    "aiplatform.endpoints.predict",
    "aiplatform.endpoints.computeTokens",
  ]
}

resource "google_project_iam_member" "runtime_inference" {
  project = var.inference_project_id
  role = var.grant_predict_via_custom_role ? (
    "projects/${var.inference_project_id}/roles/${google_project_iam_custom_role.inference_only[0].role_id}"
  ) : "roles/aiplatform.user"
  member = "serviceAccount:${google_service_account.runtime.email}"
}

# ------------------------------------------------------------------------------
# Let the Apigee runtime act as this service account.
#
# The proxy authenticates upstream with <GoogleAccessToken> in targets/vertex.xml
# and the bundle is deployed with this account attached. For that to work the
# Apigee service agent needs to be able to impersonate it.
#
# This binding is easy to miss because its absence produces a 500 at request
# time with an authentication error from the target, not a deployment failure.
# scripts/preflight-check.sh asserts it explicitly.
# ------------------------------------------------------------------------------
resource "google_service_account_iam_member" "apigee_can_use_runtime_sa" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:service-${data.google_project.host.number}@gcp-sa-apigee.iam.gserviceaccount.com"
}

# ------------------------------------------------------------------------------
# Writing the spend ledger.
#
# ML-LogSpend writes to Cloud Logging under the organization's own project, so
# the runtime account needs to be able to write log entries there.
# ------------------------------------------------------------------------------
resource "google_project_iam_member" "runtime_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# ------------------------------------------------------------------------------
# Content screening, only when it is switched on.
#
# The binding is created unconditionally because IAM grants are cheap and
# toggling features.modelArmorEnabled in the KVM should not require a
# `terraform apply`. If your policy is to grant nothing unused, delete this and
# accept that enabling screening becomes a two-step change.
# ------------------------------------------------------------------------------
resource "google_project_iam_member" "runtime_model_armor" {
  project = var.inference_project_id
  role    = "roles/modelarmor.user"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}
