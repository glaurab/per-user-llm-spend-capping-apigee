# 9. Observability

The spend ledger, the queries that make it useful, and the one reconciliation
that tells you whether any of the numbers are real.

---

## 9.1 Three layers

| Layer | Answers | Where |
|---|---|---|
| Response headers | "what did *this* call cost me?" | every response |
| Apigee analytics | "what is happening right now, by tier and team?" | Apigee UI |
| BigQuery ledger | "what did we spend, and does it match the invoice?" | log sink |

The third is the one that earns its keep. The first two are derived from the
gateway's own beliefs; the third is what you check those beliefs against.

---

## 9.2 Response headers

```
x-budget-currency:          USD
x-budget-call-cost:         0.0021
x-budget-remaining:         1.4832
x-budget-period-resets-in:  41231
x-budget-enforcement:       on
x-budget-degraded:          true      (only when counters were unreachable)
```

Cheap, and they change how the cap feels. A client application can display a
running balance without asking for one, so users see the cap approaching instead
of hitting it.

`GET /v1/budget` gives the same information without making a model call, and
costs nothing:

```json
{
  "currency": "USD",
  "period": { "day": "2026-08-13", "month": "2026-08", "resets_in_seconds": 41231 },
  "enforcement": "on",
  "limits": [
    { "scope": "user", "period": "day",   "limit_amount": "2.0000",
      "used_amount": "0.5168", "remaining_amount": "1.4832", "used_fraction": 0.258 },
    { "scope": "user", "period": "month", "limit_amount": "30.0000",
      "used_amount": "8.2210", "remaining_amount": "21.7790", "used_fraction": 0.274 },
    { "scope": "team", "period": "day",   "limit_amount": "100.0000",
      "used_amount": "42.9100", "remaining_amount": "57.0900", "used_fraction": 0.429 }
  ],
  "headroom_fraction": 0.571
}
```

`headroom_fraction` comes from the *tightest* of the three, so a client can show
the constraint that will actually bind rather than the most comfortable one.

---

## 9.3 The ledger

`ML-LogSpend` writes one structured record per call to Cloud Logging, in
`PostClientFlow` — after the client has its response, so the write costs no
latency, and including faulted requests, so refusals are recorded too. A 429
that leaves no trace is a 429 nobody can investigate.

A sink routes it to BigQuery.

```
identity   subject, tier, team
request    model requested, model served, method, output ceiling, token source
usage      prompt, candidates, cached, thoughts, total tokens
cost       currency, total micros, request-leg micros, response-leg micros, basis
budget     period day/month, remaining after, all three counter states
outcome    status code, decision, denied, breached limit, degraded flag,
           stream event count, stream usage missing
```

### Why raw token counts are stored alongside the money

Money is derived from a price table you maintain by hand. Tokens are ground
truth reported by the model.

Keeping both means a price correction can be **replayed over history** to
restate past spend. Store only the derived figure and history becomes
unrepairable: you know what you thought it cost, forever, with no way back to
what it actually cost.

### What is deliberately absent

No prompt text, no completion text, no email addresses, no names.

The ledger is a spend record, not a conversation archive. Putting prompt content
in it would silently extend every data-residency, retention and access
obligation you have to a BigQuery dataset and a log bucket — a decision that
should be taken deliberately, not inherited from a logging policy someone wrote
for a different purpose.

If you need conversation logging, build it separately, with its own retention
and its own access controls, and make the decision on its own merits.

---

## 9.4 Queries

Set `PROJECT` and the dataset name from `terraform output spend_dataset`.

### Daily spend by tier

```sql
SELECT DATE(timestamp) AS day,
       jsonPayload.identity.tier AS tier,
       COUNT(*) AS calls,
       ROUND(SUM(CAST(jsonPayload.cost.total_micros AS INT64)) / 1e6, 2) AS spend
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  DATE(timestamp) >= CURRENT_DATE() - 30
GROUP  BY day, tier
ORDER  BY day DESC, spend DESC
```

### Choosing caps from real data

The query to run at the end of observation mode. Set the daily cap somewhere
around p95: everyone normal is unaffected, and the tail gets a conversation
rather than a surprise.

```sql
WITH daily AS (
  SELECT DATE(timestamp) AS day,
         jsonPayload.identity.subject AS subject,
         jsonPayload.identity.tier AS tier,
         SUM(CAST(jsonPayload.cost.total_micros AS INT64)) / 1e6 AS spend
  FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
  WHERE  DATE(timestamp) >= CURRENT_DATE() - 30
  GROUP  BY day, subject, tier
)
SELECT tier,
       COUNT(DISTINCT subject) AS users,
       ROUND(APPROX_QUANTILES(spend, 100)[OFFSET(50)], 4) AS p50,
       ROUND(APPROX_QUANTILES(spend, 100)[OFFSET(90)], 4) AS p90,
       ROUND(APPROX_QUANTILES(spend, 100)[OFFSET(95)], 4) AS p95,
       ROUND(APPROX_QUANTILES(spend, 100)[OFFSET(99)], 4) AS p99,
       ROUND(MAX(spend), 4) AS worst_day
FROM   daily
GROUP  BY tier
```

Look at the gap between p95 and the maximum before deciding. A tight
distribution means a p95 cap is nearly harmless. A long tail means you are about
to have a conversation with a small number of people, and it is better to have
it before you enforce than after.

### Who is being refused, and how often

```sql
SELECT jsonPayload.identity.tier AS tier,
       jsonPayload.outcome.decision AS decision,
       COUNT(*) AS n,
       COUNT(DISTINCT jsonPayload.identity.subject) AS distinct_users
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  DATE(timestamp) >= CURRENT_DATE() - 7
GROUP  BY tier, decision
ORDER  BY n DESC
```

A high refusal count concentrated on **one** subject is a stuck client. Spread
across many is a budget that is too low for the work.

### Reasoning tokens as a share of spend

Worth running once, because the answer often surprises people and it validates
that `thoughtsIncludedInCandidates` is set correctly.

```sql
SELECT jsonPayload.request.model_served AS model,
       SUM(CAST(jsonPayload.usage.thoughts_tokens AS INT64)) AS thought_tokens,
       SUM(CAST(jsonPayload.usage.candidates_tokens AS INT64)) AS answer_tokens,
       ROUND(SAFE_DIVIDE(SUM(CAST(jsonPayload.usage.thoughts_tokens AS INT64)),
             SUM(CAST(jsonPayload.usage.candidates_tokens AS INT64))), 2) AS ratio
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  DATE(timestamp) >= CURRENT_DATE() - 7
GROUP  BY model
```

If the ratio is above 1, reasoning costs more than the visible answers — and a
meter that ignored those tokens would be under-reporting by more than half.

### Calls served without a budget check

```sql
SELECT DATE(timestamp) AS day, COUNT(*) AS degraded_calls,
       ROUND(SUM(CAST(jsonPayload.cost.total_micros AS INT64)) / 1e6, 2) AS unchecked_spend
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  jsonPayload.outcome.counter_degraded = 'true'
  AND  DATE(timestamp) >= CURRENT_DATE() - 30
GROUP  BY day ORDER BY day DESC
```

Every row is spend that was recorded but not capped. Under the default fail mode
that is a deliberate choice, and this is what it cost.

---

## 9.5 Reconciliation against the invoice

**The most important thing in this document.**

The gateway's cost figure is computed from a price table maintained by hand. The
Cloud Billing invoice is authority. Until you have compared the two over a real period,
you have a meter of unknown accuracy — and every budget, every refusal and every
chargeback report derived from it inherits that uncertainty.

```sql
SELECT FORMAT_DATE('%Y-%m', DATE(timestamp)) AS month,
       jsonPayload.request.model_served AS model,
       SUM(CAST(jsonPayload.usage.prompt_tokens     AS INT64)) AS input_tokens,
       SUM(CAST(jsonPayload.usage.candidates_tokens AS INT64)) AS output_tokens,
       SUM(CAST(jsonPayload.usage.thoughts_tokens   AS INT64)) AS thought_tokens,
       SUM(CAST(jsonPayload.usage.cached_tokens     AS INT64)) AS cached_tokens,
       ROUND(SUM(CAST(jsonPayload.cost.total_micros AS INT64)) / 1e6, 2) AS gateway_says
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  DATE(timestamp) >= DATE_TRUNC(CURRENT_DATE(), MONTH)
GROUP  BY month, model
```

Compare `gateway_says` against the inference project's actual billing export for
the same period and models.

Do this **monthly**, and treat a divergence as a bug in the price table rather
than an accounting curiosity.

| Symptom | Likely cause |
|---|---|
| Gateway under-reports on reasoning models | `thoughtsIncludedInCandidates` is wrong, or `thinking` rate is missing |
| Gateway over-reports where caching is used | `cachedInput` rate too high, or cached tokens not being subtracted |
| Uniform percentage gap | a price changed and the table did not |
| Invoice much higher, gateway sees nothing | **traffic is bypassing the gateway** — go to [10-security.md](10-security.md) immediately |

That last row is why this query is worth running even when you trust your price
table. It is the only routine check that detects a bypass.

Separating the inference project from the Apigee project makes the comparison
readable — the inference project's bill is almost entirely model usage, so the
totals line up directly.

---

## 9.6 Alerts

Two, created by Terraform. Deliberately few: an alert that fires routinely
trains people to ignore the channel it fires into.

**Serving without a budget check** — any call with `counter_degraded` in five
minutes. Spend is being recorded but not capped.

**Budget refusals spiking** — more than the configured threshold in thirty
minutes. Note that three different situations produce this signal and they need
opposite responses: a stuck client (fix the client), budgets set too low (fix
the budgets), or a price table above real prices (fix the prices — and your
reporting is also wrong).

Worth adding once you have traffic history, but not shipped because the
thresholds are entirely deployment-specific:

- daily spend above N× the trailing 7-day median
- a single subject above N% of the tier's total daily spend
- `MODEL_NOT_PRICED` occurring at all — it means the allowlist and price table
  have drifted apart in production

---

## 9.7 Apigee analytics

`DC-CaptureUsage` publishes ten dimensions — tier, team, subject, model, cost,
the four token counts, and the decision — for interactive slicing in the Apigee
UI. Faster than BigQuery for "what is happening right now"; not a substitute for
the ledger, because analytics retention is bounded and the store is not
exportable in the way the sink is.

Two operational notes.

The data collectors must exist before the policy can resolve them.
`scripts/deploy-proxy.sh` creates them; the `dc_` prefix is mandatory. A missing
collector is silently dropped — **empty charts with healthy traffic** is the
symptom.

Analytics has its own storage location, fixed when the organisation was created
and unchangeable afterwards. That is a further reason the subject dimension
carries an opaque identifier rather than an email address; see
[04-identity.md](04-identity.md) §4.4.
