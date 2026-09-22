# 12. Operations runbook

Specific procedures for the things that actually happen.

**The two levers to remember under pressure:**

```bash
make observe    # stop enforcing, keep metering        ≤ 300 s
make seed       # push any config change               ≤ 300 s
```

Both take effect within the KVM cache TTL. Neither needs a redeploy. Both are
reversible. Most incidents are configuration, not code.

---

## 12.1 A user needs more budget

**Temporary, one person.** Move them to a higher tier in your identity provider.
It takes effect on their next token refresh, and the tier change also starts
them a fresh counter for the remainder of the period (tier is part of the
counter key — [04-identity.md](04-identity.md) §4.5). Reversible the same way.

**Permanent, a whole tier.**

```bash
$EDITOR config/budgets.json     # raise userDaily / userMonthly
make seed
```

Before you raise it, check whether the cap is actually the problem:

```sql
SELECT DATE(timestamp) AS day,
       COUNT(*) AS calls,
       COUNTIF(jsonPayload.outcome.decision = 'BUDGET_EXCEEDED') AS refused,
       ROUND(SUM(CAST(jsonPayload.cost.total_micros AS INT64))/1e6, 4) AS spend
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  jsonPayload.identity.subject = 'SUBJECT'
  AND  DATE(timestamp) >= CURRENT_DATE() - 14
GROUP  BY day ORDER BY day DESC
```

A user hitting the cap every day at a similar spend is doing their job and needs
a bigger allowance. A user who hit it once, in one hour, after two weeks of
nothing, has a stuck client — raising the cap just moves the wall.

**A new tier.** Add it to `budgets.json`, `make seed`, then map the identity
provider group to the claim. Do it in that order: a claim value with no matching
tier silently demotes the caller to `defaultTier`.

---

## 12.2 A price changed

```bash
$EDITOR config/pricing.json
make seed
```

`make seed` validates, refuses configurations where an allowed model has no
price, and prints the new worst-case overshoot.

**Then re-check your caps.** A price rise means the same budget buys less work,
and users will experience it as the cap tightening. If prices rose 20% and you
want the same effective allowance, budgets need to rise too — nothing does that
for you.

Historical rows in the ledger are **not** restated, and that is intentional: they
record what was charged at the time. Because raw token counts are stored
alongside the money, you can recompute history at new prices if you need to.

**Not every price change is a surprise.** Introductory rates carry an end date
from the day the model ships. `gemini-3.7-flash`, the mid-tier model in the
shipped allowlist, is the live example: it launched on 13 August 2026 at a
promotional 0.75 / 3.75 per million and reverts to the standard 1.50 / 7.50 on
1 January 2027 — an exact doubling of every call on that model, on a date that
is already known (verify the current terms before you rely on this; these things
move). A scheduled increase you have not diarised is
indistinguishable, on the morning it lands, from a runaway client: refusals
climb, the invoice climbs, and nothing in the gateway changed. Put the revert
date in the same calendar that carries your certificate expiries, and treat it
as a normal price change on the day.

---

## 12.3 Adding a model

Three places, and missing any one produces a different confusing symptom:

```bash
$EDITOR config/pricing.json          # 1. the price  — else 503 MODEL_NOT_PRICED
$EDITOR config/runtime-config.json   # 2. allowedModels — else 403
make seed
# 3. if you use the vertexai.allowedModels org policy, add it there too
#    — else a confusing 403 from the target instead of a clean one from the gateway
```

Then verify the reported usage shape, because this is where meters go wrong:

```bash
curl -sS -X POST "$VERTEX_HOST/v1/projects/$P/locations/$L/publishers/google/models/NEW:generateContent" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Prove that 2+2=4 rigorously."}]}]}' \
| jq '.usageMetadata'
```

Check whether `promptTokenCount + candidatesTokenCount + thoughtsTokenCount`
equals `totalTokenCount` (thoughts are separate → `thoughtsIncludedInCandidates:
false`) or overshoots it (thoughts are inside candidates → `true`). Getting this
backwards is a silent 2× error, in either direction, on your most expensive
calls.

---

## 12.4 Refusal spike

**Alert: "budget refusals spiking".** Three quite different causes, same signal.

```sql
SELECT jsonPayload.identity.subject AS subject,
       jsonPayload.identity.tier AS tier,
       COUNT(*) AS refusals
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  jsonPayload.outcome.decision = 'BUDGET_EXCEEDED'
  AND  timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR)
GROUP  BY subject, tier ORDER BY refusals DESC LIMIT 20
```

| Shape | Cause | Action |
|---|---|---|
| One subject, hundreds of refusals | stuck client retrying a 429 | contact the owner; the gateway is working. Consider tightening `SPIKE_ARREST_RATE` |
| Many subjects, one tier | budgets too low for the work | §12.1 |
| Many subjects, all tiers, sudden | price table above real prices, or a price entry mistyped | check §12.7 reconciliation — **your spend reporting is also wrong** |

Retrying a 429 is worth calling out to client authors. The budget does not
refill for hours; retry loops burn the client's own quota and yours, and
generate exactly this alert.

---

## 12.5 Counters unavailable

**Alert: "serving without a budget check".** The gateway could not read the
quota counters and, per `failMode`, served the request anyway on the degraded
model and ceiling.

Spend is still recorded. It is not capped.

```sql
SELECT COUNT(*) AS degraded_calls,
       ROUND(SUM(CAST(jsonPayload.cost.total_micros AS INT64))/1e6, 2) AS unchecked_spend
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  jsonPayload.outcome.counter_degraded = 'true'
  AND  timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
```

1. Check Apigee runtime health and any platform incident feed.
2. Decide, from `unchecked_spend`, whether the exposure is acceptable.
3. If it is not:
   ```bash
   jq '.failMode = "closed"' config/runtime-config.json > /tmp/rc && \
     mv /tmp/rc config/runtime-config.json && make seed
   ```
   The gateway now refuses everything while the counters are unreachable. Set it
   back afterwards — leaving it at `closed` means the next brief counter blip
   becomes a full outage.

---

## 12.6 Config unavailable — total outage

Every call returns 503 `CONFIG_UNAVAILABLE`. This is fail-closed by design and
is not affected by `failMode`.

Almost always one of three things:

```bash
# 1. Is the KVM readable and do the three entries exist?
apigeecli kvms entries list -m "$KVM_NAME" -e "$APIGEE_ENV" -o "$APIGEE_ORG" \
  -t "$(gcloud auth print-access-token)"

# 2. Is each entry valid JSON? (a malformed entry is indistinguishable from a
#    missing one, from the gateway's point of view)
apigeecli kvms entries get -m "$KVM_NAME" -k pricing -e "$APIGEE_ENV" \
  -o "$APIGEE_ORG" -t "$(gcloud auth print-access-token)" | jq -r '.value' | jq empty

# 3. Does the KVM name in env.sh match mapIdentifier in the KVM-Load* policies?
grep -h mapIdentifier proxy/llm-gateway/apiproxy/policies/KVM-Load*.xml
```

Recovery is `make seed`, which validates before writing — which is why the third
cause is far more common than the second.

If it was a bad seed, roll back the config files and re-seed. If the cache is
holding a stale bad value, redeploying the proxy clears it immediately rather
than waiting out the TTL.

---

## 12.7 Monthly reconciliation

Owned by someone, scheduled, and not skipped. Run the query in
[09-observability.md](09-observability.md) §9.5 and compare against the
inference project's billing export.

| Divergence | Meaning |
|---|---|
| < 2% | fine — rounding and timing |
| Gateway under-reports, reasoning models | `thoughtsIncludedInCandidates` or missing `thinking` rate |
| Gateway over-reports, cached traffic | `cachedInput` rate wrong |
| Uniform gap | a price changed and the table did not |
| **Invoice much higher, gateway saw nothing** | **traffic is bypassing the gateway** → [10-security.md](10-security.md) now |

---

## 12.8 Rotating identity provider settings

JWKS URI, issuer and audience are build-time values, so this needs a redeploy:

```bash
$EDITOR config/env.sh
make deploy
```

Key rotation *within* the same JWKS URI needs nothing — keys are fetched and
cached, and a new `kid` is picked up automatically.

Changing the issuer or audience **invalidates every token in flight**. Every
client gets 401 until they re-authenticate. Do it in a maintenance window, or
run a second environment on the new settings and move clients across.

---

## 12.9 Emergency stop

In increasing order of severity:

```bash
make observe      # stop enforcing, keep serving and metering        ≤ 300 s
```

```bash
# refuse everything at the gateway while leaving it deployed
jq '.allowedModels = []' config/runtime-config.json > /tmp/rc && \
  mv /tmp/rc config/runtime-config.json && make seed
# every call now gets 403 with an empty allowlist                    ≤ 300 s
```

```bash
make undeploy     # gateway stops serving entirely                   immediate
```

```bash
# hard stop: revoke the gateway's ability to call the model
gcloud projects remove-iam-policy-binding "$INFERENCE_PROJECT_ID" \
  --member="serviceAccount:$RUNTIME_SA_EMAIL" \
  --role="projects/$INFERENCE_PROJECT_ID/roles/llmGatewayInference"
# calls fail at the target. Also the test that proves the gateway is the
# only path to the model — see docs/06-deployment.md
```

Note the ordering. `make undeploy` stops the gateway; it does not stop anyone
who can reach the model directly. If the emergency is "spend is out of control
and we do not know where from", the IAM revocation is the one that actually
stops it — and if it does not, you have learned something important.

---

## 12.10 Periodic checks

| When | Check |
|---|---|
| Monthly | Invoice reconciliation (§12.7) |
| Monthly | Refusal rates by tier — are caps still right for the work? |
| Quarterly | The IAM audit in [10-security.md](10-security.md) §10.2. Grants accumulate |
| Quarterly | Price table against published prices |
| Quarterly | `cap.period.strategy` still reports the configured zone, not `utc` |
| After any Apigee upgrade | The three [validation gates](13-validation-gates.md) |
| Annually | Whether the tier structure still matches how people work |

The quarterly IAM audit is the one that decays fastest. A gateway that was the
only path to the model in January is frequently not in July, because someone
needed access for a prototype and the grant was never removed.
