# ==============================================================================
# Turning the spend ledger into something you can query and be woken by.
#
# Three layers, each answering a different question:
#
#   BigQuery sink     "what did we actually spend, and does it match the bill?"
#   log-based metrics "is the gateway behaving right now?"
#   alert policies    "should someone be told?"
#
# The first is the one that earns its keep. The gateway's cost figure is derived
# from a price table maintained by hand, and the cloud invoice is the authority.
# Until you have compared the two over a real week, you have a meter of unknown
# accuracy. docs/09-observability.md contains the reconciliation query.
# ==============================================================================

resource "google_bigquery_dataset" "spend" {
  project    = var.project_id
  dataset_id = var.spend_dataset_id
  location   = var.spend_dataset_location

  friendly_name = "LLM gateway spend ledger"
  description   = "One row per metered model call, written by the Apigee gateway via a logging sink."

  default_partition_expiration_ms = var.spend_table_expiration_days * 24 * 60 * 60 * 1000

  # Do not silently discard a spend history because someone ran destroy on a
  # Friday. Removing this line is a deliberate act.
  delete_contents_on_destroy = false
}

resource "google_logging_project_sink" "spend" {
  project     = var.project_id
  name        = "llm-gateway-spend"
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.spend.dataset_id}"

  # Matches exactly what ML-LogSpend emits. The event field is checked as well
  # as the log name so that anything else that ever writes to this log - a
  # future policy, a debugging experiment - does not silently pollute the
  # ledger with rows of a different shape.
  filter = <<-EOT
    logName = "projects/${var.project_id}/logs/llm-gateway-spend"
    AND jsonPayload.event = "llm_call"
  EOT

  unique_writer_identity = true

  bigquery_options {
    # One table with a schema that grows, rather than a new table per day.
    # Date-sharded tables make the reconciliation query - which spans weeks -
    # tedious to write and expensive to run.
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "sink_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.spend.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.spend.writer_identity
}

# ------------------------------------------------------------------------------
# Metrics.
#
# ML-LogSpend writes numeric fields as JSON strings, because the policy renders
# flow variables into a template and Apigee has no typed interpolation. Cloud
# Logging value extractors parse numeric strings, so this works - but it is the
# sort of thing that breaks quietly if the log template is ever reformatted.
# If a metric goes flat while the logs still look right, check that the field
# still holds something that parses as a number.
# ------------------------------------------------------------------------------

resource "google_logging_metric" "spend_micros" {
  project = var.project_id
  name    = "llm_gateway/spend_micros"

  description = "Cost of each metered call, in micro-units of the billing currency."

  filter = <<-EOT
    logName = "projects/${var.project_id}/logs/llm-gateway-spend"
    AND jsonPayload.event = "llm_call"
  EOT

  value_extractor = "EXTRACT(jsonPayload.cost.total_micros)"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"

    labels {
      key         = "tier"
      value_type  = "STRING"
      description = "Budget tier of the caller."
    }
    labels {
      key         = "model"
      value_type  = "STRING"
      description = "Model that actually served the request."
    }
  }

  label_extractors = {
    "tier"  = "EXTRACT(jsonPayload.identity.tier)"
    "model" = "EXTRACT(jsonPayload.request.model_served)"
  }

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 24
      growth_factor      = 2
      scale              = 100
    }
  }
}

resource "google_logging_metric" "decisions" {
  project = var.project_id
  name    = "llm_gateway/decisions"

  description = "Count of calls by outcome. The denominator for every refusal rate you will want to compute."

  filter = <<-EOT
    logName = "projects/${var.project_id}/logs/llm-gateway-spend"
    AND jsonPayload.event = "llm_call"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "decision"
      value_type  = "STRING"
      description = "cap.decision.reason, or 'allowed'."
    }
    labels {
      key         = "tier"
      value_type  = "STRING"
      description = "Budget tier of the caller."
    }
  }

  label_extractors = {
    "decision" = "EXTRACT(jsonPayload.outcome.decision)"
    "tier"     = "EXTRACT(jsonPayload.identity.tier)"
  }
}

resource "google_logging_metric" "counter_degraded" {
  project = var.project_id
  name    = "llm_gateway/counter_degraded"

  description = <<-EOT
    Calls served while the quota counters were unreachable. Every one of these
    is spend that was NOT checked against a budget. Under the default
    fail-open-degraded mode this is a deliberate choice, not a bug - but it is a
    choice with a running cost, and it must be visible.
  EOT

  filter = <<-EOT
    logName = "projects/${var.project_id}/logs/llm-gateway-spend"
    AND jsonPayload.event = "llm_call"
    AND jsonPayload.outcome.counter_degraded = "true"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# ------------------------------------------------------------------------------
# Alerts.
#
# Deliberately few. An alert that fires routinely is training people to ignore
# the channel it fires into, and the two conditions below are the ones where
# ignoring it is expensive.
# ------------------------------------------------------------------------------

resource "google_monitoring_alert_policy" "counter_degraded" {
  project      = var.project_id
  display_name = "LLM gateway: serving without a budget check"
  combiner     = "OR"

  documentation {
    content = <<-EOT
      The gateway could not read its quota counters and, per the configured fail
      mode, served the request anyway on a reduced model and output ceiling.

      Spend is still being recorded, but it is NOT being capped. The overshoot
      is bounded by the degraded ceiling rather than by anyone's budget.

      First checks: is the Apigee runtime healthy, and is the environment's
      quota store reachable? If this persists and the exposure is unacceptable,
      set failMode to "closed" in the runtime-config KVM entry and run
      `make seed` - it takes effect within the cache TTL without a redeploy.

      See docs/12-operations-runbook.md, "Counters unavailable".
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Any degraded call in 5 minutes"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.counter_degraded.name}\" AND resource.type=\"apigee.googleapis.com/Environment\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.alert_notification_channels
}

resource "google_monitoring_alert_policy" "refusal_spike" {
  project      = var.project_id
  display_name = "LLM gateway: budget refusals spiking"
  combiner     = "OR"

  documentation {
    content = <<-EOT
      Callers are being refused for exceeding budget at an unusual rate.

      This is not automatically a fault. Three quite different situations
      produce the same signal, and they need opposite responses:

        - a client stuck in a retry loop, burning one user's budget and then
          hammering the 429. Fix the client; the gateway is working.
        - budgets set below what the work actually costs. Fix the budgets;
          `make seed` applies within the cache TTL.
        - a price table that has drifted above real prices, so the meter
          over-charges. Fix the prices - and check the BigQuery reconciliation
          query, because this one also means your spend reporting is wrong.

      See docs/12-operations-runbook.md, "Refusal spike".
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Budget refusals above threshold over 30 minutes"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.decisions.name}\" AND resource.type=\"apigee.googleapis.com/Environment\" AND metric.label.decision=\"BUDGET_EXCEEDED\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.budget_exceeded_alert_threshold
      duration        = "0s"

      aggregations {
        alignment_period   = "1800s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.alert_notification_channels
}
