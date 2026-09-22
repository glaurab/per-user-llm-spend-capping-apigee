# ADR 0001 — Cap in currency, not tokens

**Status:** Accepted
**Related:** [0002](0002-split-charge-across-request-and-response.md), [0003](0003-generic-quota-with-computed-weight.md)

---

## Context

The unit of the cap has to be chosen before anything else, because every other
decision follows from it — what the counters hold, what the quota policies count,
what the configuration files express, and what a governance document can promise.

There are two candidates.

**Tokens** are what the model reports. They arrive in `usageMetadata` on every
response, they need no external reference data, and they cannot go stale.

**Currency** is what anyone actually cares about, and what a budget is expressed
in everywhere else in the organisation.

The complication is that the relationship between the two is not fixed. Across a
typical model range:

- output tokens cost roughly 3–5× input tokens
- a large model's tokens cost 10–20× a small model's
- cached input is discounted, often by 75% or more
- reasoning tokens are billed at the output rate and are frequently more numerous
  than the visible answer

So the price of a token varies by well over an order of magnitude depending on
which model was called and where the tokens sat in the request.

## Decision

**Counters hold integer micro-units of the billing currency** (1e-6 of one unit).

Prices are stored as *currency per 1,000,000 tokens*, in a key value map, which
makes the conversion a bare multiplication with no scaling factor:

```
cost_micros = tokens × price_per_million
```

A 2.00-unit daily cap is `Allow count = 2000000`. Token counts are still recorded
in the ledger, but they are not what is enforced.

## Consequences

**A cap means something.** "Two units a day" is the same amount of money whichever
model the user picks. "Fifty thousand tokens a day" is a budget that silently
varies by 20× with model choice, which makes it unusable for governance and
perverse in operation — it rewards nobody for choosing a cheaper model.

**A price table becomes a required, maintained input.** This is the real cost of
the decision. The table lives in a KVM, not in code, so it can be corrected in
under five minutes; but if it drifts from reality every number the system
produces is wrong, in a way that nothing inside the system can detect. This is
why [09-observability.md](../09-observability.md) §9.5 makes monthly invoice
reconciliation a scheduled, owned task rather than a suggestion, and why
[10-security.md](../10-security.md) §10.9 treats write access to the price table
as a security boundary.

**The meter must model billing correctly, not approximately.** Cached tokens are a
subset of the prompt count and must be subtracted before pricing; reasoning
tokens are billable and may or may not already be inside the candidate count
depending on the model family. Both traps are documented in
[03-cost-model.md](../03-cost-model.md), and both are worth 2× errors.

**Integer arithmetic throughout, with `ceil` on every charge.** Floating-point
currency in a counter that is decremented millions of times accumulates drift;
micro-units make every value an integer. Rounding up rather than to nearest means
the accumulated error is always in the safe direction.

**Unpriced models cannot be served.** `unknownModelPolicy: "deny"` returns 503
`MODEL_NOT_PRICED` rather than serving something the gateway cannot meter. A
"free" default would be a hole that opens itself every time a new model appears.

## Alternatives considered

**Cap in tokens.** Rejected for the reason above: the resulting cap is not
budget-meaningful. It would have removed the price table and the reconciliation
burden entirely, which is genuinely attractive — and if you serve exactly one
model at one price, it is the better choice. See
[13-validation-gates.md](../13-validation-gates.md) §13.4.

**Cap in tokens, normalised to a reference model.** Multiply each model's tokens
by a fixed factor so everything is expressed in "Flash-equivalent tokens". This
is currency with extra steps and a worse unit: you still maintain a table of
factors, and now nobody can tell you what a cap costs without doing arithmetic.

**Cap in requests.** Trivial to implement and unrelated to spend. A hundred
one-line questions and a hundred document analyses differ in cost by three orders
of magnitude.
