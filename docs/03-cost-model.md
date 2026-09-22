# 3. The cost model

How a request becomes a number, and why every part of that arithmetic is the way
it is.

Implemented in
[`lib-pricing.js`](../proxy/llm-gateway/apiproxy/resources/jsc/lib-pricing.js).

---

## 3.1 The unit

Counters hold **micro-units of the billing currency**: integers, each one
millionth of a currency unit.

```
  1.00 currency unit  =  1 000 000 micros
  a cap of 20.00      =  20000000
```

**Integers**, because floating-point money accumulated across thousands of
increments drifts, and because the underlying counter primitive is integral
anyway.

**Micro-units specifically**, because of an arithmetic coincidence worth
exploiting. Model prices are published *per million tokens*. Store them in that
form and the conversion becomes a bare multiplication:

```
  cost_micros = tokens × price_per_million
```

No scaling, no division. 1000 tokens at 0.30 per million → 300 micros → 0.0003
currency units. Correct, in one operation, with no intermediate float.

Precision: one micro-unit is 0.000001. The cheapest realistic call is a few
hundred micros. There is no rounding pressure anywhere in the useful range.

---

## 3.2 The price table

```json
{
  "unknownModelPolicy": "deny",
  "thoughtsIncludedInCandidates": false,
  "estimatedCharsPerToken": 4,
  "estimateSafetyFactor": 1.15,
  "estimatedTokensPerNonTextPart": 260,
  "models": {
    "gemini-3.7-flash": {
      "input":       0.75,
      "output":      3.75,
      "cachedInput": 0.075,
      "thinking":    3.75
    }
  }
}
```

Every figure under `models` is **currency units per 1 000 000 tokens**, in the
currency declared in `budgets.json`.

The table lives in a key value map, never in code. A price hardcoded in a
deployed artefact is a silent budget breach the day the vendor changes it: the
meter keeps reporting confidently and is simply wrong. `make seed` updates it in
seconds.

The values shipped in `config/pricing.example.json` are the **published list
prices of 16 August 2026**, standard service tier, global endpoint, USD. They are
a snapshot, not a default you can leave alone. Nothing checks them for you — the
gateway will enforce whatever you tell it, precisely, and reconciling against the
actual invoice ([09-observability.md](09-observability.md)) is how you find out
you were wrong.

Four things make a copied price table wrong, and all four are live in the shipped
example:

| trap | in the shipped table |
|---|---|
| **Introductory rates expire.** | `gemini-3.7-flash` is priced at 0.75 / 3.75 through 31 December 2026 and doubles to 1.50 / 7.50 on 1 January 2027. Diary it — see [12-operations-runbook.md](12-operations-runbook.md) §12.2. |
| **Endpoint locality is priced.** | Since 1 July 2026 the GA Gemini 3 and later families cost roughly 10% more on non-global endpoints. `runtime-config.json` points at a regional host by default, so the shipped table is about 10% low if you keep that default. |
| **Long context is a different rate.** | `gemini-3.1-pro` moves to 4.00 / 18.00 once the input exceeds 200 000 tokens, and the higher rate then applies to *every* token in the call. The table has one rate per model, which is only safe because `limits.maxPromptChars` is 200 000 characters — roughly 50 000 tokens, an order of magnitude clear. Raise that limit past about 800 000 characters and you need a context-tiered lookup instead. |
| **Service tier is priced.** | Batch and Flex are half these rates, Priority is roughly 1.8×, and a tuned endpoint is 1.5× its base model. The table has to match the endpoint you actually call. |

One ratio worth knowing rather than looking up: the cached-input rate is **10% of
the input rate** across all three current models. It was 25% on the retired 2.5
family, so a `cachedInput` figure carried over from that era over-states the cost
of every cache hit by two and a half times. That error is invisible in testing,
because cache hits are exactly the calls nobody checks.

### `unknownModelPolicy`

What to do when a model is requested that has no price entry.

| value | behaviour |
|---|---|
| `deny` *(default)* | refuse the call, `503 MODEL_NOT_PRICED` |
| `mostExpensive` | charge at the highest rate present in the table |

There is no option to serve it free. An unpriced model that is served is an
unmetered path through the gateway, and it appears the moment someone adds a
model to the allowlist and forgets the price. `deny` makes that mistake loud;
`mostExpensive` makes it expensive. Both are recoverable. Free is not.

`scripts/preflight-check.sh` and `scripts/seed-kvm.sh` both refuse a
configuration where an allowed model has no price, so in practice this policy is
a backstop rather than a regular occurrence.

---

## 3.3 What the model reports

Every response carries a `usageMetadata` block:

```json
{
  "promptTokenCount":        1250,
  "candidatesTokenCount":     380,
  "cachedContentTokenCount":  900,
  "thoughtsTokenCount":       410,
  "totalTokenCount":         2040
}
```

Two of these five fields are traps.

### `cachedContentTokenCount` is a subset, not an addition

Those 900 tokens are *part of* the 1250 prompt tokens, served from a context
cache at a discount. Adding them to the prompt count double-counts. The correct
handling is to subtract them out before applying the full input rate:

```
  billable_input = promptTokenCount − cachedContentTokenCount
  input_cost     = billable_input × input_rate
                 + cachedContentTokenCount × cachedInput_rate
```

Get this wrong and you overcharge every user of context caching — which is to
say, every user of your best-optimised application.

### `thoughtsTokenCount` is billed and invisible

Reasoning models generate internal tokens before answering. The user never sees
them. They are billed. On a hard question they can exceed the visible answer.

A meter that counts "what was sent plus what came back" misses them entirely and
can be wrong by a factor of two, always in the direction that costs money.

Whether they are *also* counted inside `candidatesTokenCount` has varied between
model families, so it is a configuration flag rather than an assumption:

```json
"thoughtsIncludedInCandidates": false
```

`false` — they are separate, add them. `true` — they are already inside
`candidatesTokenCount`, subtract before adding, or you charge them twice.

Verify it once per model family, empirically: send a prompt that forces
reasoning and check whether `promptTokenCount + candidatesTokenCount +
thoughtsTokenCount` equals `totalTokenCount` or overshoots it. Getting it
backwards is a silent 2× error on exactly the calls that cost the most.

---

## 3.4 The full formula

```
  billable_input = promptTokenCount − cachedContentTokenCount
  candidates     = candidatesTokenCount
                     − (thoughtsIncludedInCandidates ? thoughtsTokenCount : 0)

  total_micros = ceil(
        billable_input           × rate.input
      + cachedContentTokenCount  × rate.cachedInput
      + candidates               × rate.output
      + thoughtsTokenCount       × (rate.thinking ?? rate.output)
  )
```

`ceil`, not `round`. Rounding down means a systematic under-charge on every
single call — small individually, unbounded in aggregate, and always in the
direction that loses money. Round-half-even would be more "correct" and is the
wrong choice here: this is a spending control, and the error should point
towards the conservative side.

`rate.thinking ?? rate.output` — if the table has no separate thinking rate,
reasoning tokens are charged at the output rate. That is the right default; they
are output-side tokens that happen not to be shown.

---

## 3.5 The two legs

### Request leg — exact, and it can refuse

Before generation, only the input side exists. But it exists *completely*: the
text is right there. The Gemini Enterprise Agent Platform (formerly Vertex AI)
provides a free `countTokens` endpoint that
returns the exact token count for a given prompt and model.

```
  request_charge = ceil( promptTokens × rate.input )
```

Called by `SC-CountTokens`, priced by `JS-EstimateRequestCost`. It is a
synchronous round trip on every request, which is a real latency cost, and it
buys exactness on the only leg where a mistake can wrongly refuse a user. It can
be switched off (`features.preflightCountTokens`), which drops back to the
estimate below.

Note that at this stage there is no `cachedContentTokenCount` to work with —
whether a cache hit occurs is not known until generation. So the request leg
charges the full input rate, and the response leg corrects it downward if the
cache was used. Erring high on the leg that can refuse, and correcting on the
leg that cannot, is the right way round.

### The fallback estimate

Without `countTokens`:

```
  tokens ≈ ceil( characters / estimatedCharsPerToken × estimateSafetyFactor )
         + nonTextParts × estimatedTokensPerNonTextPart
```

Four characters per token is a reasonable English average and gets worse for
other languages, code, and heavy punctuation — hence the 1.15 safety factor,
which biases towards over-estimating.

Non-text parts (images, audio, documents) are counted at a flat rate because
their true cost depends on dimensions the gateway would have to decode the
attachment to learn. `estimatedTokensPerNonTextPart` is a blunt instrument; if
your traffic is multimodal, calibrate it from the ledger rather than accepting
the default. This is the weakest number in the model, and it only matters when
`countTokens` is off.

Whatever the estimate gets wrong is corrected on the response leg. The estimate
determines *who gets refused*, never *what gets charged*.

### Response leg — reconciliation

```
  total_micros = (the full formula, from real usageMetadata)
  delta        = max(0, total_micros − charged_on_request_leg)
```

`max(0, …)` handles the one case where the total comes in below what was already
charged: a cache hit that the request leg could not have known about. The excess
is not refunded. Refunding would mean decrementing a distributed counter — an
operation these counters do not support cleanly — for an amount that is, by
construction, a small fraction of one call's input cost. It is a rounding error
in favour of the budget, and it is written down here rather than hidden.

The response leg **never refuses**, whatever the delta. The response exists; it
was billed upstream the moment it was generated. Discarding it would mean paying
for it and delivering nothing.

The delta is also **always ≥ 0**, which is the property that lets this design
avoid negative counter adjustments entirely. That is not an accident of the
arithmetic — it follows from only ever charging the input side up front.

---

## 3.6 Worked example

`gemini-3.7-flash` at 0.75 / 3.75 / 0.075 / 3.75 per million.

A call with a 1250-token prompt (900 of it cached), 380 tokens of answer, and
410 tokens of reasoning:

```
request leg
  countTokens returns 1250
  charge  ceil(1250 × 0.75)                         =   938 micros

response leg
  billable input   1250 − 900 = 350  × 0.75         =   262.5
  cached                        900  × 0.075        =    67.5
  candidates                    380  × 3.75         =  1425
  thoughts                      410  × 3.75         =  1537.5
                                             ceil → =  3293 micros

  delta = 3293 − 938                                =  2355 micros

total charged  3293 micros  =  0.003293 currency units
```

Three things to notice.

The reasoning tokens cost **more than the visible answer** — 1537.5 against
1425. A meter that ignored them would report 1755 micros and be wrong by 47%.

The request leg took 938 of the eventual 3293 — about 28%. That is typical for a
mostly-cached prompt, and it is why the request leg alone cannot be the cap: the
decision is made on somewhere between a sixth and a third of the eventual cost.

The cache discount is worth less than it looks. 900 of the 1250 prompt tokens
were served from cache, but at 10% of the input rate they save only 607.5 micros
against a total of 3293 — under a fifth of the call. Output dominates, because
output is five times the input rate and reasoning tokens are output.

---

## 3.7 Overshoot, and why it is bounded

Because the decision is made on the input side, a call allowed with 100 micros
remaining can still cost 3293. The user ends the period over their cap.

The bound comes from the gateway overwriting `generationConfig.maxOutputTokens`
in every request. The client's value is read and discarded; the effective value
is `min(requested, ceiling)`.

```
  maximum overshoot = output_ceiling × max(rate.output over allowed models)
```

At a 2048-token ceiling and a most-expensive output rate of 12.00 per million —
`gemini-3.1-pro`, the dearest model in the shipped allowlist:

```
  2048 × 12.00 = 24576 micros = 0.0246 currency units
```

Against the 2.00 standard daily cap, that is 1.2% — the most a caller can end
the day past their budget, whatever they do.

`make seed` prints this figure, computed from your live configuration, every
time you change the ceiling or the price table.

Notes on the bound.

It is per *call*, not per period — but since only one call can be in flight past
the cap for a given counter, and the next one is refused, per-call is the
meaningful figure.

It **ignores reasoning tokens**, which are not covered by `maxOutputTokens` on
all model families. If you allow reasoning models, treat the published bound as
approximate unless you have verified that the ceiling constrains thinking too.
That is an honest caveat, not a flaw in the arithmetic.

It is also the one the current model generation makes sharpest. On Gemini 3.x
the depth of reasoning is a *request parameter* — a discrete thinking level,
`low` / `medium` / `high` on `gemini-3.7-flash` — so a client can multiply its
own thinking-token bill by changing one field, exactly as it could once do with
`candidateCount`. The gateway clamps `candidateCount` and does not yet pin the
thinking level. If you need the bound tight rather than indicative, pin it in
`AM-BuildVertexRequest` the same way, and confirm the field name against the API
surface you actually call: it is spelled differently on `generateContent` than
on the Interactions API.

And it assumes the ceiling is actually applied. `scripts/smoke-test.sh` asserts
the resulting balance never falls further below zero than the bound, which
catches the case where the overwrite silently stops working.

---

## 3.8 Getting the budgets right

Caps are set in whole currency units per tier:

```json
{
  "currency": "USD",
  "tiers": {
    "standard": { "userDaily": 2.00, "userMonthly": 30.00 },
    "elevated": { "userDaily": 10.00, "userMonthly": 150.00 }
  },
  "teams": {
    "_default": { "daily": 100.00 }
  }
}
```

Choosing the numbers is the part no documentation can do for you, and guessing
badly is the most common way a rollout fails. A cap set too low arrives as an
outage for the people least equipped to explain what happened.

So: **run in observation mode first** (`make observe`). The gateway meters,
logs, and reports everything while refusing nothing. Let it run long enough to
see a real distribution — a few weeks, including whatever your month-end looks
like — then set caps from the ledger.
[09-observability.md](09-observability.md) has the percentile query.

A reasonable starting rule, once you have data: set the daily cap around the
95th percentile of daily spend. Everyone normal is unaffected; the tail gets a
conversation rather than a surprise.

Monthly is not simply 30× daily. Nobody works 30 days, and a monthly cap at 30×
the daily one never binds — it is decoration. Around 15× is a monthly limit that
does something.

And note that a tier called `unmetered` in the example config still has a
number, a large one. There is deliberately no way to disable a counter. A
genuinely uncapped user is a user whose runaway script has no upper bound and
produces no signal — you find out from the invoice.
