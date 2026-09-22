# ==============================================================================
# Outputs.
#
# These exist to be consumed, not just read: `make deploy` sources them so the
# scripts and the Terraform state cannot disagree about which environment or
# service account is in play. If you change a name here, the deployment follows.
# ==============================================================================

output "apigee_environment" {
  value       = google_apigee_environment.gateway.name
  description = "Environment to deploy the proxy bundle into."
}

output "apigee_envgroup" {
  value       = google_apigee_envgroup.gateway.name
  description = "Environment group carrying the gateway hostnames."
}

output "gateway_base_url" {
  value       = "https://${var.gateway_hostnames[0]}/llm"
  description = <<-EOT
    Base URL clients call. The /llm suffix is the BasePath declared in
    proxy/llm-gateway/apiproxy/proxies/default.xml; change one and change both.
  EOT
}

output "kvm_name" {
  value       = google_apigee_environment_keyvaluemaps.config.name
  description = "Key value map that scripts/seed-kvm.sh writes configuration into."
}

output "runtime_service_account" {
  value       = google_service_account.runtime.email
  description = <<-EOT
    Attach this to the proxy at deployment time. It is also the account whose
    inference binding you revoke to prove the gateway is the only path to the
    model - see docs/06-deployment.md, final verification step.
  EOT
}

output "spend_dataset" {
  value       = "${var.project_id}.${google_bigquery_dataset.spend.dataset_id}"
  description = "BigQuery dataset holding the spend ledger."
}

output "spend_table_hint" {
  value       = "${var.project_id}.${google_bigquery_dataset.spend.dataset_id}.llm_gateway_spend"
  description = <<-EOT
    Expected table name once the sink has written its first row. The table is
    created by the sink, not by Terraform, so it will not exist until traffic
    flows. An empty dataset after a successful smoke test usually means the log
    filter and the ML-LogSpend log name have drifted apart.
  EOT
}

output "next_steps" {
  value = <<-EOT

    Infrastructure is in place. The gateway is not yet serving.

      1. make seed      push pricing, budgets and runtime-config into the KVM
      2. make deploy    build and deploy the proxy bundle
      3. make smoke     exercise the gateway end to end

    Before enforcing, run in observation mode for a period long enough to see
    real usage: set features.enforce to false in runtime-config.json and seed.
    The gateway will meter, log and report everything while refusing nothing.
    Use the resulting spend distribution to choose budgets. Setting caps first
    and discovering them second is how a rollout turns into an incident.

  EOT
  description = "What to do after apply."
}
