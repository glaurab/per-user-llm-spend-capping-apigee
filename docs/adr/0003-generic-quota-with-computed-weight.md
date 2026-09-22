# ADR 0003 — Generic `Quota` with a computed weight, not the LLM token quota

**Status:** Accepted
**Related:** [0001](0001-cap-in-currency-not-tokens.md), [0002](0002-split-charge-across-request-and-response.md)

---

## Context

Given a currency cap ([0001](0001-cap-in-currency-not-tokens.md)) and a split
charge ([0002](0002-split-charge-across-request-and-response.md)), something has
to hold the running total. Three candidates were available.

**The generic `Quota` policy.** Counts arbitrary units, distributed across message
processors, with the increment supplied per call via `MessageWeight`.

**Apigee's LLM-specific token quota policies** (`EnforceOnly` / `CountOnly`).
Purpose-built for this shape of problem: they understand model responses, extract
token counts natively, and require no JavaScript to do so.

**External state** — Firestore, Redis, Spanner, or similar — read and written by
`ServiceCallout` or JavaScript.

## Decision

**Use three generic `Quota` policies with `MessageWeight ref` carrying an integer
number of currency micro-units.**

```xml
<Quota continueOnError="true" name="QU-BudgetUserDaily" type="flexi">
  <Identifier ref="cap.key.user.daily"/>
  <Allow countRef="cap.budget.user.daily.micros" count="0"/>
  <MessageWeight ref="cap.weight.micros"/>
  <Distributed>true</Distributed>
  <Synchronous>true</Synchronous>
</Quota>
```

`continueOnError="true"` is part of the decision, not an incidental setting: the
policies never fault, and the allow/deny decision is made explicitly by
`JS-EvaluateQuota`.

## Consequences

**The counter is denominated in money.** `MessageWeight` accepts any integer, so
what the counter holds is entirely up to the JavaScript that runs before it. This
is the property that makes a currency cap possible at all on this primitive.

**Distributed and synchronous counting comes for free.** These are the two
settings that separate a cap from a suggestion. Without `Distributed`, N message
processors means N times the intended budget. Without `Synchronous`, concurrent
requests read a stale count and all pass. Both are one line each; both are
genuinely hard to get right in a hand-built counter.

**No external datastore, and no operational surface that goes with one.** No
extra service to provision, secure, back up, region-pin, or debug at 3am. The
counters live where the enforcement lives.

**JavaScript owns the decision, which is a feature.** Because the quotas
`continueOnError`, `JS-EvaluateQuota` sees all three counter results at once. It
can distinguish "over budget" from "counter unreachable" — a distinction the
policy's own fault cannot express — pick the most constraining limit, and build a
429 that names the limit breached and when it resets. A stock quota fault would
also abort the *response* leg, where there is nothing left to prevent.

**Two platform assumptions are inherited.** That `MessageWeight ref` honours a
computed integer ([gate 2](../13-validation-gates.md)), and that one policy at two
attachments shares a counter ([gate 1](../13-validation-gates.md)). Both are
tested, both have fallbacks.

**Counters are not readable as a first-class API.** `/v1/budget` works by invoking
the same quota policies with a weight of zero (`AM-SetZeroWeight`) and reading
the `*.used.count` and `*.available.count` variables they publish. It works, and
it is slightly oblique — worth knowing when reading that flow.

## Alternatives considered

**The LLM-specific token quota policies.** Genuinely the more elegant path for the
problem they solve, and rejected only on the unit. Their counter is tokens; this
design caps currency; and per-model price weighting on top of a token counter is
not clearly controllable. Everything in [0001](0001-cap-in-currency-not-tokens.md)
about why a token cap is not budget-meaningful applies.

They remain the better choice in two situations: your governance requirement is
genuinely written in tokens, or you serve exactly one model at one price. Under
either, keep the identity, configuration, streaming and observability layers here
and replace only the three `QU-*` policies and `JS-EvaluateQuota`.
[13-validation-gates.md](../13-validation-gates.md) §13.4 says how.

**External state.** Maximum flexibility — arbitrary counter semantics, refunds,
reservations, real-time dashboards, retention beyond the quota interval. Rejected
because it adds a stateful dependency in the hot path of every request. Latency
becomes yours to manage, availability becomes yours to manage, and the failure
mode of "the counter store is down" now needs the same fail-mode reasoning as the
quota policies but with more ways to go wrong. It is the right answer if you
outgrow this design; it is the wrong place to start.

**One quota policy with a composite identifier.** Encode scope and period into a
single key and use one policy. Rejected because the three counters have different
`Allow` counts and different intervals, and because separate policies make the
`JS-EvaluateQuota` logic — most constraining wins — legible.
