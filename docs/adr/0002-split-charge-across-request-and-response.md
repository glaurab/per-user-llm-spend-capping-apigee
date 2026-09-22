# ADR 0002 — Split the charge across the request and response legs

**Status:** Accepted
**Related:** [0001](0001-cap-in-currency-not-tokens.md), [0003](0003-generic-quota-with-computed-weight.md), [0006](0006-fail-open-degraded-by-default.md)

---

## Context

A cap has to decide *before* the work happens. The cost of an LLM call is not
known *until* the work has happened, because the number of output tokens is a
property of the generation.

This is not an implementation gap that a cleverer design closes. It is structural,
and every possible gateway has to pick one of four responses:

| | Behaviour | Problem |
|---|---|---|
| Worst-case | charge `input + ceiling × output_rate` up front | over-charges every call, often by 5–10× |
| Charge-after | serve, then charge what it actually cost | the cap can be blown arbitrarily far in one call |
| Split | charge the known part before, the remainder after | overshoot bounded by one response |
| Dishonest | check the counter, serve, never reconcile | not a cap |

Input cost, by contrast, *is* exactly knowable before the call: `countTokens` is
a free Gemini Enterprise Agent Platform API that returns the prompt token count
for a given model.

## Decision

**Charge in two legs, against the same counter.**

**Request leg.** `SC-CountTokens` obtains the exact input token count.
`JS-EstimateRequestCost` prices it. The quota policies are charged that amount,
and this is the point at which an over-budget caller is refused.

**Response leg.** `JS-ReconcileResponseCost` prices the real `usageMetadata` and
charges

```
delta = max(0, actual_total_micros − already_charged_micros)
```

The response leg **never refuses**. The tokens have already been generated and
billed upstream; refusing at that point would cost the user their answer and cost
you the money anyway.

The same `Quota` policy object is attached at both steps so both address one
counter — [validation gate 1](../13-validation-gates.md).

To make the residual exposure a number rather than a hope,
`AM-BuildVertexRequest` **overwrites** `generationConfig.maxOutputTokens` with the
configured ceiling and clamps `candidateCount` to 1, giving

```
max overshoot per call = ceiling × highest_output_price
```

## Consequences

**Overshoot is bounded and publishable.** With a 2048-token ceiling and a typical
large-model output rate, a user can end a period at most a fraction of a currency
unit over their cap. That figure is printed by `make seed`, and it belongs in
whatever document promises the cap.

**No negative weights are ever needed.** Because only the *input* side is charged
up front, and the actual total always includes at least that input, the delta is
non-negative by construction. A design that charged a worst-case estimate up
front would need to refund on the response leg, and quota counters do not
decrease.

**Users are charged accurately, not conservatively.** The final charge is the real
cost from `usageMetadata`, not an estimate. This matters more than it sounds: a
worst-case-only gateway makes a 2.00-unit budget behave like a 0.30-unit one, and
users respond by asking for larger budgets, which defeats the exercise.

**Refusals are honest about what they cost.** The request leg has already charged
the input cost when it refuses, so a caller who spams over-budget requests still
pays for the prompts they submitted. Denying for free would make the refusal path
cheaper than the success path.

**The mechanism depends on a platform behaviour.** If two attachments of one
policy do not share a counter, budgets silently allow roughly double. Hence gate
1, its test, and its documented fallback (single-leg worst-case charging).

**Two extra round trips of latency, optionally.** `countTokens` adds one call to
the model endpoint per request. It is free in money and not free in time, so
`features.preflightCountTokens` can disable it, at which point
`JS-EstimateRequestCost` falls back to a character-based estimate with a safety
factor. Less accurate on the request leg; the response leg still reconciles to
truth, so the final charge is unaffected.

## Alternatives considered

**Worst-case charging only.** Simpler, single-leg, and the documented fallback if
gate 1 fails. Rejected as the default because the systematic over-charge is
large enough to make the cap value meaningless.

**Charge only after the fact.** One call can exceed the remaining budget by any
amount — a single large-context request against an expensive model could consume a
month's allowance in one go, and the cap would refuse only the *next* one.

**Reserve, then settle.** Take a hold for the worst case, release the unused part
after. This is the right pattern in a payments system and requires a counter that
can decrease. Apigee quota counters cannot, so it would mean abandoning the quota
primitive for external state — see [0003](0003-generic-quota-with-computed-weight.md).
