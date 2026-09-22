# ==============================================================================
# Inputs.
#
# No geography is hardcoded anywhere in this project. Every region, hostname and
# jurisdiction is a variable with no default, so the configuration cannot
# silently inherit someone else's assumptions about where data may live.
# ==============================================================================

# ------------------------------------------------------------------------------
# Projects
# ------------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Project hosting the Apigee organization."
}

variable "inference_project_id" {
  type        = string
  description = <<-EOT
    Project billed for model usage. May be the same as project_id, but keeping
    them separate is worth the small extra effort: it makes the cloud invoice
    for inference readable on its own, which is what you reconcile the
    gateway's own spend ledger against. See docs/09-observability.md.
  EOT
}

variable "region" {
  type        = string
  description = "Default region for provider-level resources created here."
}

# ------------------------------------------------------------------------------
# Apigee
# ------------------------------------------------------------------------------

variable "apigee_org" {
  type        = string
  description = <<-EOT
    Existing Apigee organization id. Almost always identical to project_id;
    it is a separate variable because they are conceptually different things
    and conflating them makes multi-project setups confusing.
  EOT
}

variable "apigee_instance_id" {
  type        = string
  description = <<-EOT
    Existing Apigee runtime instance to attach the new environment to. Find it
    with: gcloud apigee instances list --organization=ORG
  EOT
}

variable "environment_name" {
  type        = string
  default     = "llm-gateway"
  description = "Apigee environment created by this configuration."
}

variable "environment_type" {
  type        = string
  default     = "COMPREHENSIVE"
  description = <<-EOT
    Apigee environment type. COMPREHENSIVE is required for the analytics and
    data-collector features this gateway relies on for spend reporting.
    Downgrading to INTERMEDIATE or BASE will not break enforcement - the quota
    counters are unaffected - but DC-CaptureUsage becomes a no-op and you lose
    the ability to slice spend by tier and team inside Apigee. The structured
    log sink in observability.tf still works, so this is a reporting trade-off
    rather than a control one.
  EOT
}

variable "envgroup_name" {
  type        = string
  default     = "llm-gateway-group"
  description = "Apigee environment group created by this configuration."
}

variable "gateway_hostnames" {
  type        = list(string)
  description = <<-EOT
    Hostnames clients use to reach the gateway. Must be covered by the TLS
    certificate on the environment group.
  EOT
}

variable "kvm_name" {
  type        = string
  default     = "llm-gateway-config"
  description = <<-EOT
    Environment-scoped key value map holding pricing, budgets and
    runtime-config. Must match the mapIdentifier in the KVM-Load* policies,
    which is baked into the bundle - change one and you must change both.
  EOT
}

# ------------------------------------------------------------------------------
# Runtime identity
# ------------------------------------------------------------------------------

variable "runtime_sa_id" {
  type        = string
  default     = "llm-gateway-runtime"
  description = <<-EOT
    Account id of the service account the proxy uses to call the model. This is
    the ONLY identity that should be able to reach the inference API; see
    docs/10-security.md for why the gateway is worthless if callers can also
    reach it directly.
  EOT
}

variable "grant_predict_via_custom_role" {
  type        = bool
  default     = true
  description = <<-EOT
    When true, create a custom role containing only the prediction permissions
    and grant that. When false, grant the predefined roles/aiplatform.user.

    The predefined role is convenient and far too broad: it also permits
    creating tuning jobs, deploying endpoints and reading datasets. A gateway
    whose only job is to forward one API call should not be able to start a
    training run. Prefer true unless a specific feature forces otherwise.
  EOT
}

# ------------------------------------------------------------------------------
# Observability
# ------------------------------------------------------------------------------

variable "spend_dataset_id" {
  type        = string
  default     = "llm_gateway_spend"
  description = "BigQuery dataset receiving the spend log sink."
}

variable "spend_dataset_location" {
  type        = string
  description = <<-EOT
    BigQuery location for the spend dataset. Set explicitly: the default would
    be multi-region US, which is very unlikely to be what a project that cares
    about data residency wants.
  EOT
}

variable "spend_table_expiration_days" {
  type        = number
  default     = 400
  description = <<-EOT
    Retention for partitions in the spend ledger. 400 days keeps just over a
    year, which lets you compare a period against the same period last year -
    the comparison that actually matters when arguing about budgets.
  EOT
}

variable "alert_notification_channels" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Existing Cloud Monitoring notification channel ids for the alert policies.
    An empty list still creates the policies; they simply notify nobody, which
    is worth knowing before you rely on them.
  EOT
}

variable "budget_exceeded_alert_threshold" {
  type        = number
  default     = 25
  description = <<-EOT
    Number of budget refusals in a 30-minute window before alerting. A steady
    trickle of 429s is the system working. A spike is a signal: either a
    misconfigured client in a retry loop, or a budget that is genuinely too low
    for the work people are being asked to do.
  EOT
}

# ------------------------------------------------------------------------------
# Optional organization policy constraints
# ------------------------------------------------------------------------------

variable "manage_org_policies" {
  type        = bool
  default     = false
  description = <<-EOT
    Off by default because organization policies have effects far outside this
    project and are usually owned by a central platform team. When you do turn
    them on, read docs/10-security.md first: these constraints are what stop the
    gateway from being an optional detour rather than the only road.
  EOT
}

variable "allowed_resource_locations" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Values for gcp.resourceLocations, e.g. ["in:europe-locations"]. Empty
    disables that constraint even when manage_org_policies is true.
  EOT
}

variable "allowed_vertex_models" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Values for constraints/vertexai.allowedModels. This is defence in depth
    behind the gateway's own allowlist: the gateway controls what its callers
    may ask for, this controls what the project may serve at all. Empty
    disables the constraint.
  EOT
}
