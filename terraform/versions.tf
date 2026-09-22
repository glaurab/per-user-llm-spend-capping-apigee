terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.30.0"
    }
  }
}

# ==============================================================================
# WHAT THIS TERRAFORM DOES AND DELIBERATELY DOES NOT DO
# ==============================================================================
#
# It manages everything BELOW the Apigee organization: the environment, the
# environment group and its attachments, the key value map, the runtime service
# account and its permissions, and the observability plumbing.
#
# It does not create the Apigee organization, and that is not an oversight.
#
# Creating an organization fixes two properties permanently: the control plane
# location and the analytics data region. Neither can be changed afterwards -
# not by editing Terraform, not by support ticket. The only remedy is to delete
# the organization and start again, which means deleting every proxy,
# environment, key value map and historical analytics record inside it.
#
# An irreversible decision with residency implications should be taken by a
# person reading a checklist, not by a plan output that scrolled past. So org
# creation is a documented manual runbook: docs/06-deployment.md, step 1.
#
# It also does not seed the key value map. Prices and budgets change routinely,
# often urgently, and often by someone who is not the person who owns this
# Terraform state. Putting them in state would mean every budget adjustment is a
# `terraform apply` with a diff over unrelated infrastructure. `make seed`
# handles content; Terraform handles the container. See scripts/seed-kvm.sh.
#
# Nor does it deploy the proxy bundle. Bundle build and deployment run through
# apigeecli (scripts/deploy-proxy.sh) so that proxy revisions - which are
# versioned and independently rollback-able inside Apigee already - are not
# duplicated as Terraform state.
# ==============================================================================

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
