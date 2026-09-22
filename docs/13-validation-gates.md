# 13. Validation gates

Three assumptions this design rests on that you must confirm against **your**
Apigee version, in **your** organisation, before you call the gateway a control.

Not because they are unlikely — the implementation is built on them — but because
each is a platform behaviour rather than something the code can guarantee, each
would fail *quietly* rather than loudly, and each has a fallback that costs you
something. Better to know which fallback you are on than to discover it from an
invoice.

**Run all three before enforcing, and again after any Apigee runtime upgrade.**

| # | Assumption | Failure symptom | Cost of the fallback |
|---|---|---|---|
| 1 | The same `Quota` policy at two flow steps shares one counter | budgets appear to allow roughly double | systematic over-charge |
| 2 | `MessageWeight ref` accepts a computed integer flow variable | every call charges 1 | coarse accounting |
| 3 | `EventFlow` runs JS per SSE event without breaking the stream | all streaming charged at ceiling | streaming over-charged, corrected next day |

---

## 13.1 Gate 1 — one policy, two attachments, one counter

### The claim

`QU-BudgetUserDaily` appears twice in `proxies/default.xml`: once in the Request
flow, once in the Response flow. Apigee keys a quota counter on the *policy name
plus the identifier*, so both attachments address the same counter.

The entire split-charge mechanism ([05-enforcement-semantics.md](05-enforcement-semantics.md))
depends on this. If the two attachments produce two independent counters, the
request leg charges the input cost to one counter and the response leg charges
the delta to another — and the user's effective budget is somewhere near double
what you configured, with neither counter ever showing the real total.

### The test

Set a tiny budget so a single call is decisive.

```bash
jq '.tiers.standard.userDaily = 0.02' config/budgets.json > /tmp/b && \
  mv /tmp/b config/budgets.json && make seed && sleep 300
```

Make **one** generation call, then read the budget without spending:

```bash
curl -sS -X POST "$GATEWAY/v1/models/gemini-3.7-flash:generateContent" \
  -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Write two sentences about tides."}]}]}' \
  -D /tmp/h -o /tmp/r

grep -i x-budget /tmp/h

curl -sS "$GATEWAY/v1/budget" -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" \
| jq '.limits[] | select(.scope=="user" and .period=="day") | {used_amount, remaining_amount}'
```

Now compare against the ledger row for that same call:

```sql
SELECT jsonPayload.cost.charged_request_leg_micros  AS leg1,
       jsonPayload.cost.charged_response_leg_micros AS leg2,
       jsonPayload.cost.total_micros                AS total
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
ORDER  BY timestamp DESC LIMIT 1
```

### What you should see

```
used_amount × 1e6  ==  total  ==  leg1 + leg2
```

**Gate passes.** One counter, charged twice, summing correctly.

### What failure looks like

`used_amount × 1e6 == leg2` alone, or `== leg1` alone. The counter reflects only
one leg. That is two counters, and the other one is invisible.

Be careful not to misread rounding: `used_amount` is printed to four decimal
places, so compare in micros, and make the call large enough that `leg2`
is clearly non-zero. A short prompt with a short answer can produce legs so close
that a wrong result looks right.

### If it fails

Charge once, on the request leg, at a conservative estimate:

```
weight = ceil(input_tokens × input_rate)
       + ceil(maxOutputTokens_ceiling × output_rate)
       + ceil(maxOutputTokens_ceiling × thinking_rate)   # if the model reasons
```

Then remove every quota attachment from the response flows and keep
`JS-ReconcileResponseCost` purely for the ledger and the headers — so your
*reporting* stays accurate even though your *enforcement* is conservative.

The cost: users are charged the maximum on every call, so a budget buys perhaps
a third of the work it should. You would compensate by raising the caps, which
means the cap no longer corresponds to real money. Workable, and clearly worse.

---

## 13.2 Gate 2 — `MessageWeight ref` with a computed variable

### The claim

```xml
<MessageWeight ref="cap.weight.micros"/>
```

`cap.weight.micros` is set by JavaScript immediately before the policy runs, as
an integer, and Apigee decrements the counter by that amount.

Two things can go wrong. The reference may not resolve at all, in which case the
policy falls back to a weight of 1 and every call — a one-token ping and a
50,000-token document analysis alike — costs the same trivial amount. Or the
variable may be resolvable but of the wrong *type*: JavaScript's `Number` is a
double, and a policy expecting a `Long` may coerce it to 1, or to 0, or reject
it.

`JS-EstimateRequestCost` therefore sets the variable with an explicit
`String(Math.ceil(x))`. Confirm that this is what Apigee actually receives.

### The test

Two calls of very different size against the same counter.

```bash
before=$(curl -sS "$GATEWAY/v1/budget" -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" \
         | jq -r '.limits[0].used_amount')

# small
curl -sS -X POST "$GATEWAY/v1/models/gemini-3.7-flash:generateContent" \
  -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Hi."}]}]}' > /dev/null

mid=$(curl -sS "$GATEWAY/v1/budget" -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" \
      | jq -r '.limits[0].used_amount')

# large — roughly 4000 tokens of input
python3 -c "print('The quick brown fox. ' * 800)" | jq -Rs \
  '{contents:[{role:"user",parts:[{text:.}]}]}' > /tmp/big.json

curl -sS -X POST "$GATEWAY/v1/models/gemini-3.7-flash:generateContent" \
  -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" -H "Content-Type: application/json" \
  -d @/tmp/big.json > /dev/null

after=$(curl -sS "$GATEWAY/v1/budget" -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" \
        | jq -r '.limits[0].used_amount')

echo "small charge: $(echo "$mid - $before" | bc)"
echo "large charge: $(echo "$after - $mid" | bc)"
```

### What you should see

The large call charges substantially more than the small one, and each charge
matches `total_micros` in the ledger for that call.

**Gate passes.**

### What failure looks like

Both charges identical — almost certainly `0.000001`, which is a weight of 1.
Or both zero, which means the counter is not moving at all and you have no cap.

Enable Apigee trace on one call and read the value of `cap.weight.micros` at the
step immediately before the quota policy. If the variable holds a sensible
integer there but the counter moved by 1, the reference is not being honoured.
If the variable is empty, the fault is in the JavaScript and not in the platform
— check the ledger for a `MODEL_NOT_PRICED` decision, which is the usual cause.

### If it fails

Bucketise. Map the computed cost onto a small set of fixed-weight quota policies
and route to one of them by condition:

| Cost | Policy | Weight |
|---|---|---|
| < 0.001 | `QU-BudgetTiny` | 1000 |
| < 0.01 | `QU-BudgetSmall` | 10000 |
| < 0.1 | `QU-BudgetMedium` | 100000 |
| otherwise | `QU-BudgetLarge` | 1000000 |

Set each bucket's weight to the **top** of its range, so the error is always in
the safe direction.

Note that this breaks gate 1 as a side effect: the request and response legs may
land in different buckets, so they no longer share a counter. Under this fallback
you charge once, on the request leg, on the conservative estimate from §13.1.

The cost: charges are rounded up to the next bucket, so accounting is coarse and
small calls are over-charged proportionally the most. Still a real cap.

---

## 13.3 Gate 3 — `EventFlow` over SSE

### The claim

```xml
<EventFlow name="SSE" content-type="text/event-stream">
  <Request/>
  <Response>
    <Step><Name>JS-CaptureStreamUsage</Name></Step>
  </Response>
</EventFlow>
```

Apigee runs `JS-CaptureStreamUsage` once per server-sent event, as the event
passes through, without buffering the stream — and the client still receives the
events promptly and unmodified.

Three distinct things to confirm, and it is worth confirming them separately:
the events arrive, they arrive *incrementally*, and the policy actually ran.

### The test

```bash
time curl -sS -N -X POST \
  "$GATEWAY/v1/models/gemini-3.7-flash:streamGenerateContent?alt=sse" \
  -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Count slowly from 1 to 40, one number per line."}]}]}' \
| while IFS= read -r line; do printf '%s  %s\n' "$(date +%T.%3N)" "${line:0:60}"; done
```

Then, after a few seconds for the response leg to settle:

```sql
SELECT jsonPayload.outcome.stream_events        AS events,
       jsonPayload.outcome.stream_usage_missing AS usage_missing,
       jsonPayload.cost.basis                   AS basis,
       jsonPayload.cost.total_micros            AS total
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  jsonPayload.request.method = 'streamGenerateContent'
ORDER  BY timestamp DESC LIMIT 1
```

### What you should see

Timestamps spread across seconds — not all identical. `events` well above 1.
`usage_missing` false. `basis` **not** `ceiling_fallback`.

**Gate passes.**

### What failure looks like

Three different failures, distinguishable from the output above:

**All timestamps identical, arriving together at the end.** The stream is being
buffered. Metering is correct but streaming has lost its point — the user waits
for the whole generation before seeing anything.

**`events` is 0 and `basis` is `ceiling_fallback`.** The policy never ran, or ran
and saw nothing. Every streaming call is being charged the maximum. Users
experience this as streaming being mysteriously expensive, and it will not
produce an error anywhere.

**Malformed or truncated events at the client.** The policy is interfering with
the stream. Stop and take streaming out of service until it is understood —
`JS-CaptureStreamUsage` is written to be read-only and to swallow every
exception precisely so this cannot happen, so this result means something more
fundamental is wrong.

### If it fails

Remove the `EventFlow` block, and in `JS-EstimateRequestCost` charge streaming
requests the full ceiling up front:

```
weight = ceil(input_tokens × input_rate) + ceil(ceiling × output_rate)
```

Then reconcile nightly from the ledger. You have the real token counts in
BigQuery — the response body passes through Apigee either way — so you can credit
the difference to the following day's budget with a scheduled job, or simply
publish streaming as a conservatively-priced mode and let users choose.

The cost: streaming users are over-charged during the day and corrected later, or
not at all. Acceptable. **Leaving streaming unmetered is not one of the options**
— see [08-streaming.md](08-streaming.md) §8.1.

---

## 13.4 A fourth thing, not a gate

Apigee also ships LLM-specific policies, including a token quota with
`EnforceOnly` and `CountOnly` modes that understands model responses natively.

They are not used here, and the reason is a unit mismatch rather than a defect:
their counter is **tokens**, and this design caps **currency**. A token cap
cannot express "two units a day" across a model range where prices differ by more
than an order of magnitude — see [01-concepts.md](01-concepts.md) §1.6. Per-model
price weighting on top of a token counter is not clearly controllable.

If your governance requirement is genuinely expressed in tokens, or you serve
exactly one model at one price, those policies are the shorter path and you
should take it: you would keep the identity, config, streaming and observability
layers in this repo and replace only the three `QU-*` policies and
`JS-EvaluateQuota`.

`adr/0003` records the decision. This note exists so that if a future Apigee
release adds currency weighting to those policies, whoever finds this document
knows the choice was deliberate and knows what to revisit.

---

## 13.5 Recording the result

Write the outcome down somewhere durable — the gates are cheap to run and
expensive to *assume*. A row per gate, per Apigee version:

```
gate  version                  date        result   notes
1     apigee-x 1-14-0-…        2026-08-13  pass     leg1+leg2 == counter, to the micro
2     apigee-x 1-14-0-…        2026-08-13  pass     4000-token call charged 61× the small one
3     apigee-x 1-14-0-…        2026-08-13  pass     37 events over 4.2 s, usage captured
```

If any gate fails and you adopt its fallback, record that too — including in
[07-configuration.md](07-configuration.md) or wherever your team looks first.
The failure modes above are all silent, and the person debugging a strange
invoice in eight months will not otherwise know that the meter was deliberately
conservative.
