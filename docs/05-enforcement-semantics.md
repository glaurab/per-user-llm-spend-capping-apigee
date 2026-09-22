# 5. Enforcement semantics

The precise rules: what is charged, when, against what, and what happens at each
edge. This is the contract the rest of the implementation delivers.

---

## 5.1 The counter primitive

Apigee's `Quota` policy maintains a distributed counter. Each invocation:

- resolves an **identifier** — which counter,
- compares its value against an **allowance**,
- adds a **message weight** to it.

This project uses that primitive in a way it was not primarily designed for, and
the mapping is:

| Quota concept | Used here as |
|---|---|
| identifier | `user + tier + period`, or `team + period` |
| allowance | the budget, in micro-units |
| message weight | the cost of this call, in micro-units |
| `type="flexi"` | counter starts on first use of that identifier |
| `Interval` | how long a counter key *lives*, not the budget period |

The last row is the one that surprises people reading the policy files. The
budget period is not expressed by the interval — it is expressed by the
identifier. See §5.4.

---

## 5.2 Split-charge

```
  ┌─ request leg ───────────────────────────────────────────┐
  │  weight = exact input cost                              │
  │  charge all three counters                              │
  │  read the results and DECIDE                            │
  │      over budget  →  429, stop here                     │
  │      otherwise    →  continue                           │
  └─────────────────────────────────────────────────────────┘
                          │
                   [ model generates ]
                          │
  ┌─ response leg ──────────────────────────────────────────┐
  │  weight = max(0, actual_total − charged_on_request_leg)  │
  │  charge all three counters                              │
  │  NEVER decide                                           │
  └─────────────────────────────────────────────────────────┘
```

Both legs attach **the same three policy objects**. That is the mechanism: one
policy object attached at two flow points shares one counter, so the response
leg tops up the same total the request leg started.

This is [validation gate 1](13-validation-gates.md). Confirm it on your Apigee
version before relying on it; there is a documented fallback if it does not
hold.

### Why the request leg can refuse and the response leg cannot

The request leg is deciding whether to *incur* a cost. Refusing is free.

The response leg is looking at a cost that has already been incurred — the model
generated the answer, and you are billed for it regardless of what the gateway
does next. Refusing at that point means paying for a response and throwing it
away. Strictly worse than delivering it and recording the spend.

### Why the delta is never negative

The response-leg weight is `max(0, total − already_charged)`, and in practice
the clamp almost never fires, because the request leg only ever charges the
input side and the total always includes it.

The one case that does trigger it: a context-cache hit that the request leg
could not have anticipated. The request leg charged the full input rate; the
response leg discovers part of the input was discounted. The total comes in
below what was taken.

The excess is **not refunded**. Decrementing a distributed counter is an
operation these counters do not support cleanly, and the amount is bounded by
one call's input cost — a rounding error in the budget's favour. It is written
down here rather than hidden.

---

## 5.3 The three counters

| Counter | Identifier | Catches |
|---|---|---|
| user / day | `u\|{sub}\|{tier}\|D\|2026-08-13` | runaway scripts, one enthusiastic afternoon |
| user / month | `u\|{sub}\|{tier}\|M\|2026-08` | sustained daily-maximum usage |
| team / day | `t\|{team}\|D\|2026-08-13` | aggregate group cost with no individual at fault |

All three are charged on both legs, always. The **most constraining wins**: the
request is refused if any one of them is over.

`JS-EvaluateQuota` reads all three rather than letting the first breach fault,
which is why the 429 body can say *which* limit was hit. "You have exceeded your
daily budget" and "your team has exhausted its daily budget" call for completely
different responses from the person reading them.

`GET /v1/budget` reports all three separately, plus a `headroom_fraction`
derived from the tightest — so a client can display the constraint that will
actually bind.

---

## 5.4 Period boundaries

### The problem with a shared reset instant

The natural implementation resets every counter at a fixed UTC time. Two
consequences.

**Local days get bisected.** At UTC+9, midnight UTC is 09:00 — the start of the
working day. A user who exhausts their allowance on Tuesday gets a fresh one at
09:00 Wednesday local, having already had one for Tuesday-morning-local. Two
allowances during one felt "day", and the second arrives exactly when it is most
useful.

**Everything resets at once.** Every counter in the system zeroes at the same
instant, producing a synchronised spike of demand against the model.

### The approach used here

Put the period into the identifier and let the counter be per-period by
construction:

```
u|user-123|standard|D|2026-08-13     ← Tuesday's counter
u|user-123|standard|D|2026-08-14     ← Wednesday's, which does not exist yet
```

At local midnight the date string changes, the identifier changes, and the
lookup finds a counter that has never existed — which starts at zero. There is
no reset event, nothing scheduled, no spike. Old identifiers stop being
referenced and their keys expire.

`type="flexi"` is what makes this work: the counter's window begins on the first
request that uses that identifier, rather than being aligned to a shared
calendar boundary.

`Interval` then becomes a key **lifetime**, not a budget period — 2 days for
daily counters, 40 for monthly. Comfortably longer than the period they serve,
so the key never expires while still in use, and short enough that abandoned
keys clear out.

### Daylight saving

Handled by the same mechanism, and this is the elegant part.

The local date is recomputed **per request** from the current instant and a
timezone definition. On the day the clocks change, that day is 23 or 25 hours
long, and the date string changes exactly once during it, at the correct moment.
No offset arithmetic, no special case, no annual bug.

Three strategies, tried in order
([`lib-time.js`](../proxy/llm-gateway/apiproxy/resources/jsc/lib-time.js)):

1. `Intl.DateTimeFormat` with the configured IANA zone — correct, if the
   runtime's JavaScript engine has full timezone data.
2. A fixed base offset plus an explicit table of DST windows — correct, if you
   maintain the table.
3. UTC — always available, and wrong for anyone not in UTC.

Which one was used is published in `cap.period.strategy`. **Check it once after
deploying.** Silently falling back to UTC reintroduces exactly the problem this
section exists to solve, and nothing else will tell you.

`cap.period.resetSeconds` — the seconds until the next local midnight — is
computed by walking forward hour by hour and then binary-searching to the
minute, re-evaluating the local date at each step. It is correct across a DST
transition for the same reason: it never assumes a day is 24 hours.

---

## 5.5 Bounded overshoot

A call allowed with 100 micros remaining can still cost 2000. The last call of a
period exceeds the cap. That is inherent to deciding before generation — the
question is only *by how much*, and whether you can state it.

The gateway makes it stateable by overwriting `generationConfig.maxOutputTokens`
with the configured ceiling. The client's value is read and discarded.

```
  maximum overshoot = output_ceiling × max(output rate over allowed models)
```

`make seed` prints the figure from your live configuration.
`scripts/smoke-test.sh` asserts that a real spend-down never ends further below
zero than the bound.

`candidateCount` is clamped to 1 for the same reason. Requesting eight
candidates multiplies the output cost by eight while leaving the input-side
charge — and therefore the decision — identical.

Two honest caveats:

**Reasoning tokens may not be covered.** `maxOutputTokens` does not constrain
thinking on all model families. If you allow reasoning models, treat the
published bound as approximate unless you have verified otherwise. On Gemini
3.x the thinking level is itself a request parameter, so it is a client-settable
cost multiplier of the same kind as `candidateCount`; `docs/03-cost-model.md`
§3.7 explains how to pin it if you need the bound to be exact.

**The bound assumes the overwrite works.** That is what the smoke test checks.

---

## 5.6 Decision outcomes

`JS-EvaluateQuota` produces exactly one outcome per request.

| `cap.decision.reason` | Status | When |
|---|---|---|
| *(none)* | — | allowed |
| `BUDGET_EXCEEDED` | 429 | a counter is over its limit |
| `CONFIG_UNAVAILABLE` | 503 | prices, budgets or settings unreadable |
| `IDENTITY_MISSING` | 401 | verified token carried no subject claim |
| `MODEL_NOT_ALLOWED` | 403 | model not in the allowlist |
| `MODEL_NOT_PRICED` | 503 | allowed, but no price entry |
| `MALFORMED_BODY` | 400 | body would not parse |
| `PROMPT_TOO_LARGE` | 413 | over `maxPromptChars` |
| `COUNTER_UNAVAILABLE` | 503 | counters unreachable and `failMode` is `closed` |
| `PROMPT_BLOCKED` | 400 | content screening matched |

### The 429 body

```json
{
  "error": {
    "code": 429,
    "status": "RESOURCE_EXHAUSTED",
    "reason": "BUDGET_EXCEEDED",
    "breached_limit": "user_daily",
    "scope": "user",
    "period": "day",
    "limit_amount": "2.0000",
    "used_amount": "2.0104",
    "currency": "USD",
    "resets_in_seconds": 41231,
    "message": "Daily budget exhausted. Resets in 11 hours.",
    "contact": "platform-team@example.com"
  }
}
```

Every field is there so the caller does not have to open a ticket to learn
something the gateway already knows. `Retry-After` carries the same reset time
for clients that honour it.

Note `used_amount` exceeding `limit_amount` — that is the bounded overshoot
being reported honestly rather than clamped to look tidy.

---

## 5.7 Fail modes

Configured in `runtime-config.json`; applies **only** when the counters are
unreachable.

| Mode | Behaviour |
|---|---|
| `closed` | refuse everything, 503 |
| `open` | serve everything, unmetered |
| `open-degraded` *(default)* | serve, but force the cheapest configured model and a reduced output ceiling; flag it |

`open-degraded` bounds the damage instead of choosing between two absolutes. The
service stays up; spend during the outage is capped by construction rather than
by counters; and every affected call is marked `counter_degraded` in the ledger,
which drives an alert.

Users get `X-Budget-Degraded: true` and a smaller model than they asked for.
Better than a 503, and honest about what happened.

### Configuration failure is not a fail mode

If prices, budgets or settings cannot be read, the gateway refuses. Always.
Whatever `failMode` says.

The distinction matters and is easy to conflate:

- **Counters unreachable** — we know what a call costs and how big it may be,
  we just don't know what this user has already spent. Bounded degradation is
  available.
- **Configuration unreachable** — we don't know what anything costs, which
  models are allowed, or how many tokens one call may produce. There is no
  bounded way to serve that traffic.

---

## 5.8 Observation mode

`features.enforce: false` — every counter still runs, every call is priced,
logged, and reported; nothing is refused. `X-Budget-Enforcement: observe`.

This is the intended first phase of a rollout, not a debug setting. Caps set
before you know the real spend distribution are guesses, and a low guess arrives
as an outage for users who cannot explain what happened.

`make observe` / `make enforce` toggle it, taking effect within the KVM cache
TTL with no redeploy. That also makes it the right lever during an incident:
turning enforcement off is thirty seconds, and it is reversible.

---

## 5.9 Free operations

Two endpoints cost nothing.

`GET /v1/budget` runs the same three quota policies with `AM-SetZeroWeight`
forcing the weight to zero — so it reads the real counters without moving them.
Reading your balance must not spend it, or every dashboard polling the endpoint
becomes a slow drain on the thing it displays. The smoke test asserts this.

`GET /v1/models` touches no counters at all.

Refusals are also free: a request rejected for an unknown model, a malformed
body, or an oversized prompt never reaches the pricing stage. A 429 is free
too — the weight was charged before the decision, but the counter was already
over, so nothing is lost that was not already spent.

---

## 5.10 Concurrency

Apigee's distributed counters are synchronous and atomic
(`<Synchronous>true</Synchronous>`), so two simultaneous requests from one user
cannot both read the same pre-charge balance and both be allowed.

What concurrency *can* do is put several calls past the cap at once. Ten
parallel requests, each allowed on its input cost, each then adding its output
cost on the way back. The overshoot bound in §5.5 is per call, so the worst case
is `concurrency × bound`.

`SA-SpikeArrest` limits how far that goes — it is the reason the rate limit
exists at all. It is not access control (the key is a token the caller can
rotate), but against the actual threat here, which is one client in a loop, it
works.
