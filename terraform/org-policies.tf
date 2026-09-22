# ==============================================================================
# Optional organization policy constraints. Off by default (manage_org_policies).
#
# WHY THESE ARE HERE AT ALL
#
# The gateway controls what its callers may do. It cannot control what the
# project may do. Those are different questions, and only the second one is
# answered by policy constraints.
#
# Concretely: the gateway's allowlist stops a user asking for an expensive
# model. It does nothing about a service account in the same project calling the
# inference API directly, or about someone enabling a model the organization has
# not approved. Constraints close that gap from the other side.
#
# WHY THEY ARE OFF BY DEFAULT
#
# Organization policies apply to resources far beyond this project and are
# normally owned by a central platform team. Enabling them from an application
# repository is a good way to break something you cannot see. Treat this file as
# a documented proposal to hand to whoever owns policy, not as something to
# switch on because the plan looked clean.
# ==============================================================================

locals {
  manage_locations = var.manage_org_policies && length(var.allowed_resource_locations) > 0
  manage_models    = var.manage_org_policies && length(var.allowed_vertex_models) > 0
}

# ------------------------------------------------------------------------------
# Where resources in this project may be created.
#
# The gateway can be told which regional endpoint to call, and it will obey. It
# has no way to stop someone creating a bucket, a dataset or a second Agent Platform
# resource somewhere else entirely. If a residency requirement is what motivated
# the gateway, this constraint is doing more of the actual work than the gateway
# is.
#
# Note that it constrains where resources are CREATED. It does not constrain
# where a global or multi-region API endpoint routes a request internally - see
# docs/11-regions-and-residency.md, which is the more subtle half of the same
# problem.
# ------------------------------------------------------------------------------
resource "google_org_policy_policy" "resource_locations" {
  count = local.manage_locations ? 1 : 0

  name   = "projects/${var.inference_project_id}/policies/gcp.resourceLocations"
  parent = "projects/${var.inference_project_id}"

  spec {
    rules {
      values {
        allowed_values = var.allowed_resource_locations
      }
    }
  }
}

# ------------------------------------------------------------------------------
# Which models the project may serve at all.
#
# Defence in depth behind the gateway's own allowedModels list. The two lists
# should agree, and the gateway's should be a subset. If they diverge, the
# symptom is a model that passes the gateway's allowlist and is then refused
# upstream - a confusing 403 from the target rather than a clean 403 from the
# gateway. docs/12-operations-runbook.md covers keeping them in step.
# ------------------------------------------------------------------------------
resource "google_org_policy_policy" "allowed_models" {
  count = local.manage_models ? 1 : 0

  name   = "projects/${var.inference_project_id}/policies/vertexai.allowedModels"
  parent = "projects/${var.inference_project_id}"

  spec {
    rules {
      values {
        allowed_values = var.allowed_vertex_models
      }
    }
  }
}

# ------------------------------------------------------------------------------
# No downloadable service account keys.
#
# A JSON key for the runtime service account is a file that calls the model,
# spends money, and is attributable to nobody. It can be copied to a laptop and
# it does not expire. This is the single most direct way to reduce the gateway
# to a suggestion.
#
# Nothing in this project needs a key: the Apigee runtime impersonates the
# service account, which is short-lived, revocable and logged.
# ------------------------------------------------------------------------------
resource "google_org_policy_policy" "no_sa_keys" {
  count = var.manage_org_policies ? 1 : 0

  name   = "projects/${var.project_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}
