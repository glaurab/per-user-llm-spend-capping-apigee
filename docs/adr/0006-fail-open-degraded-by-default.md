# ADR 0006 — Fail-open-degraded by default, fail-closed on configuration

**Status:** Accepted
**Related:** [0003](0003-generic-quota-with-computed-weight.md), [0005](0005-identity-from-verified-oidc-token.md)

---

## Context

The gateway sits in the path of every model call. When part of it cannot do its
job, something has to happen, and the choice is a genuine trade between two
things nobody wants:

- **Fail closed** — refuse. The cap holds, and an internal fault in the metering
  layer becomes a full outage of a service people depend on to work.
- **Fail open** — serve. The service stays up, and spend is uncapped for the
  duration, with no upper bound on the exposure.

Neither is right in general, and — importantly — the answer is not the same for
every kind of failure. Treating "the quota counter timed out" and "the price
table is unreadable" as one case produces a bad answer to at least one of them.

## Decision

**Separate the failure causes and give them different, deliberate behaviour.**

### Counter unavailable → configurable, default `open-degraded`

The quota policies carry `continueOnError="true"`, so `JS-EvaluateQuota` can tell
"the counter says you are over budget" apart from "the counter did not answer".
For the second case, `failMode` decides:

| `failMode` | Behaviour when counters are unreachable |
|---|---|
| `open` | serve normally, uncapped, record the spend |
| **`open-degraded`** (default) | serve, but force the cheapest configured model and a reduced output ceiling; mark the call `counter_degraded`; alert |
| `closed` | refuse with 503 |

### Configuration unavailable → always closed, not configurable

If the price table, the budget table or the runtime configuration cannot be read,
every request gets 503 `CONFIG_UNAVAILABLE` regardless of `failMode`.

### Identity unverifiable → always closed

401. Not a fail mode; there is no user to charge.

### Response leg → never refuses

Under any setting. The tokens are generated and billed; refusing costs the user
their answer and costs you the money anyway.

## Consequences

**The default keeps the service up while bounding the damage.** `open-degraded` is
not a compromise between the two bad options so much as a third position: traffic
that would otherwise have gone to an expensive model at a high ceiling goes to
the cheapest one at a low ceiling, so uncapped spend accrues at a small fraction
of the normal rate. Quality drops, visibly, and users notice — which is
appropriate, because the system is degraded.

**Fail-open is a decision someone made, not one that happened.** Every degraded
call is marked in the ledger, the Terraform ships an alert that fires on the
first one within five minutes, and
[09-observability.md](../09-observability.md) has the query that totals the
unchecked spend. If you serve uncapped for an hour, you can say exactly what it
cost. That number, not an argument in the abstract, is what should drive a
decision to switch to `closed`.

**Switching is a configuration change, ~300 seconds, no redeploy.** During an
incident you can move to `closed` once the exposure is known, and move back
afterwards. Leaving it at `closed` permanently means the next brief counter blip
becomes a full outage — [12-operations-runbook.md](../12-operations-runbook.md)
§12.5 says so at the point where someone would be tempted.

**Config-unavailable is fail-closed because the alternative is indefensible.** A
missing price table means the gateway cannot compute a cost for anything. Serving
under those conditions is not degraded metering, it is *no* metering, with no way
to reconstruct what was spent afterwards — the token counts would be recorded but
the prices would be unknown. And unlike a counter outage, this failure is almost
always self-inflicted and immediately fixable: a bad seed, a wrong KVM name, a
malformed JSON entry. §12.6 covers all three.

**Two different 503s exist and mean different things.** `CONFIG_UNAVAILABLE` (the
gateway cannot read its own configuration) and `MODEL_NOT_PRICED` (the
configuration is fine but this model has no entry). Both are the gateway
declining to guess. Keeping them distinct is what makes the alert on the second
one useful — it means the allowlist and the price table have drifted apart in
production.

**Observation mode is the same lever, used deliberately.** `features.enforce =
false` meters everything and refuses nothing, which is how you gather the data to
choose caps in the first place ([09-observability.md](../09-observability.md)
§9.4) and is also a legitimate emergency response. It is distinct from `failMode:
open`: enforcement is off by intent, not because something broke, and the
response headers say `x-budget-enforcement: off` so nobody is misled about
whether the cap is live.

## Alternatives considered

**Always fail closed.** Defensible if the spend risk genuinely outweighs
availability — a public-facing endpoint funded by a fixed grant, say. Rejected as
the *default* because for most internal deployments the LLM service is something
people work with all day, and an outage caused by the cost-control layer is a
poor advertisement for cost control. It remains one setting away.

**Always fail open.** Rejected because the exposure is unbounded and invisible.
Without the degraded-model behaviour and the alert, a counter outage over a
weekend is discovered on the invoice.

**Queue requests until the counters recover.** Attractive in theory. In practice
it converts a metering fault into unbounded latency and memory pressure in the
gateway, and the client timeouts that follow look identical to an outage while
being harder to diagnose.

**One `failMode` covering every failure cause.** Simpler to document and wrong for
at least one case whichever value you pick. The distinction between "the counter
is unreachable" and "I do not know what anything costs" is exactly the
distinction that matters here.
