# 2. Architecture

What the pieces are, and what happens to a request as it passes through them.

Read [01-concepts.md](01-concepts.md) first if you have not — this document
assumes you know why a choke point is needed and what split-charge enforcement
is.

---

## 2.1 Components

```
      ┌──────────┐
      │  client  │
      └────┬─────┘
           │  Authorization: Bearer <OIDC id token>
           │  POST /llm/v1/models/{model}:generateContent
           ▼
 ╔═════════════════════════════════════════════════════════════╗
 ║  Apigee X  —  proxy "llm-gateway"                           ║
 ║                                                             ║
 ║   verify token ──▶ load config ──▶ price ──▶ charge/decide  ║
 ║        │               │                         │          ║
 ║        │               │                         │          ║
 ╚════════╪═══════════════╪═════════════════════════╪══════════╝
          │               │                         │
          ▼               ▼                         ▼
    ┌──────────┐   ┌────────────┐         ┌───────────────────┐
    │   IdP    │   │    KVM     │         │  quota counters   │
    │  JWKS    │   │  pricing   │         │  (Apigee runtime, │
    │ endpoint │   │  budgets   │         │   distributed)    │
    └──────────┘   │  settings  │         └───────────────────┘
                   └────────────┘
                                                    │
      ┌─────────────────────────────────────────────┘
      │  forwarded with the gateway's own service account
      ▼
 ┌──────────────────────────────────────────────┐
 │  Agent Platform                              │
 │    :countTokens          (free, pre-flight)  │
 │    :generateContent                          │
 │    :streamGenerateContent                    │
 └──────────────────────────────────────────────┘

 side channels:
   Cloud Logging ──▶ BigQuery      one row per call, the spend ledger
   Apigee analytics                interactive slicing by tier/team/model
   Model Armor                     optional content screening
```

| Component | Role | Notes |
|---|---|---|
| **Apigee X proxy** | The choke point. All logic lives here. | One environment of its own — see below |
| **Identity provider** | Issues the tokens the gateway trusts | Any OIDC provider; only its JWKS endpoint is contacted |
| **Key value map** | Prices, budgets, runtime settings | Environment-scoped, cached 300 s, changed without redeploying |
| **Quota counters** | The running totals | Apigee's distributed counter store |
| **Agent Platform** | The model, and the free token counter | Reached only by the gateway's service account |
| **Cloud Logging → BigQuery** | Durable spend ledger | What you reconcile against the invoice |
| **Model Armor** | Optional prompt/response screening | Off by default; the cap must not depend on it |

### Why a dedicated Apigee environment

Quota counters are environment-scoped. Sharing an environment means sharing the
counter store with unrelated traffic, and a noisy neighbour's incident becomes
your budget outage. The runtime service account — the one identity permitted to
call the model — is also attached per environment, so a dedicated environment
keeps that capability confined to proxies you have reviewed.

---

## 2.2 The life of a unary request

Each step names the policy that implements it, so you can read this alongside
[proxy/llm-gateway/apiproxy/proxies/default.xml](../proxy/llm-gateway/apiproxy/proxies/default.xml).

### PreFlow — runs for every request

The order is the design; each step depends on the previous one.

| # | Policy | What it does | Why here |
|---|---|---|---|
| 1 | `EV-ExtractBearerToken` | pulls the token out of the header | the next step needs something to key on |
| 2 | `SA-SpikeArrest` | throttles per token | before spending CPU on signature verification |
| 3 | `VJ-VerifyIdToken` | verifies signature, issuer, audience, expiry | identity must be trustworthy *before* it becomes a quota key |
| 4 | `KVM-Load{RuntimeConfig,Pricing,Budgets}` | reads configuration | needed by step 5 |
| 5 | `JS-BuildIdentityKeys` | derives subject, tier, team; resolves budgets; computes the local period; builds the three counter keys | needs both claims and configuration |
| 6 | `RF-ConfigUnavailable` / `RF-IdentityMissing` | fail closed | unpriceable or unattributable traffic is not served |

Inverting steps 2 and 3 would let a flood of invalid tokens hammer signature
verification. Moving step 5 before step 3 would key the budget on an unverified
claim — the entire cap defeated by editing a string.

Note what step 2 can and cannot do. It throttles on the presented token, which
an attacker can rotate; it is burst protection, not access control. Its actual
job is stopping one runaway client loop from draining a budget in seconds, and
at that it works.

### Request flow

```
  EV-ExtractModel            parse {model}:{method} from the path
  JS-NormalizeRequest        ┌ check the allowlist
                             │ parse the body, measure the prompt
                             │ FORCE generationConfig.maxOutputTokens
                             └ clamp candidateCount to 1
  RF-MalformedBody           400, if the body would not parse
  RF-ModelNotAllowed         403, echoing what IS allowed
  RF-PromptTooLarge          413
  SC-CountTokens             free Agent Platform :countTokens — exact input size
  JS-EstimateRequestCost     input tokens × price  ->  cap.weight.micros
  RF-NotMeterable            503, if the model is allowed but has no price
  QU-BudgetUserDaily    ─┐
  QU-BudgetUserMonthly   ├─ charge the input cost against all three counters
  QU-BudgetTeamDaily    ─┘
  JS-EvaluateQuota           read all three results; decide
  RF-BudgetExceeded          429 with limit, usage, reset time, contact
  RF-NotMeterable            503, if a counter was unreachable and mode is closed
  SC-SanitizeUserPrompt      optional screening — after the budget decision, so a
  EV-ArmorPromptVerdict      caller about to be refused does not trigger a paid
  RF-PromptBlocked           screening call
  AM-BuildVertexRequest      rewrite the path, set target.url, strip the caller's
                             Authorization header
```

Two details in `JS-NormalizeRequest` carry more weight than their size suggests.

**Forcing `maxOutputTokens`** is what converts an unbounded overshoot into a
stated number. The client's value is read and discarded; the effective value is
`min(requested, ceiling)`.

**Clamping `candidateCount` to 1** closes a multiplier the request-leg estimate
does not see. Asking for eight candidates costs eight times the output, and the
input-side charge is identical either way.

### Response flow

```
  JS-ReconcileResponseCost   read usageMetadata; price it properly, per component
                             delta = max(0, actual_total − already_charged)
  QU-*  (all three)          charge the delta — skipped entirely when it is zero
  SC-SanitizeModelResponse   optional
  EV-ArmorResponseVerdict
  AM-RedactBlockedResponse   451
  AM-AddBudgetHeaders        cost, remaining, reset, enforcement state
  DC-CaptureUsage            dimensions into Apigee analytics
```

The same three `QU-*` policies appear in both flows. That is deliberate and is
the mechanism that makes split-charge work: one policy object attached at two
points shares one counter, so the response leg tops up the total the request leg
started. This is [validation gate 1](13-validation-gates.md) — confirm it on
your version.

The response leg never denies. It cannot: the answer exists and has already been
paid for upstream. It records reality and moves on.

### PostClientFlow

```
  ML-LogSpend                one structured JSON record to Cloud Logging
```

After the client has its response, so the ledger write costs the user no
latency. It runs for faults too, so refusals are recorded alongside successes —
a 429 that leaves no trace is a 429 nobody can investigate.

---

## 2.3 Streaming

Identical up to `AM-BuildVertexRequest`. The difference is on the way back:

```
  EventFlow (content-type: text/event-stream)
      JS-CaptureStreamUsage    runs per SSE event, without buffering;
                               keeps the latest usageMetadata seen

  Response
      JS-FinalizeStreamCost    price what was captured — or, if nothing was,
                               charge the ceiling
      QU-*                     charge the delta
      DC-CaptureUsage
```

`JS-CaptureStreamUsage` overwrites rather than accumulates: each event carries
cumulative usage, so the last one seen is the total. Accumulating would multiply
the charge by the event count.

Response screening is deliberately absent on this path — screening a stream
requires buffering it, which defeats the purpose. See
[08-streaming.md](08-streaming.md).

---

## 2.4 Public interface

| | |
|---|---|
| `POST /v1/models/{model}:generateContent` | metered, unary |
| `POST /v1/models/{model}:streamGenerateContent` | metered, SSE |
| `GET /v1/budget` | remaining budget on all three counters. Costs nothing |
| `GET /v1/models` | the allowlist |
| anything else | `404` |

That last row is not tidiness. A proxy that forwards unmatched paths to its
target is an unmetered proxy for every endpoint the target exposes. The
catch-all `NotFound` flow exists to make sure there is no such path.

The request and response bodies are the model API's own, unchanged. Existing
client code changes its base URL and its `Authorization` header; nothing else.
That compatibility is worth protecting — a gateway with a bespoke request format
is a gateway people write scripts to avoid.

---

## 2.5 Where configuration lives, and why it is split

Two stores, and the distinction is operational rather than aesthetic.

**Key value map — runtime.** Prices, budgets, allowed models, output ceiling,
fail mode, enforcement switch, timezone. Read on every request through a 300-
second cache. Changed with `make seed`: seconds, no redeploy, no revision.

**Bundle placeholders — build time.** JWKS URI, issuer, audience, the
ServiceCallout hostnames, the SpikeArrest rate, the escalation contact. These
are fields Apigee reads when a policy is compiled, not when it runs, so they
cannot come from a variable. They are written into the bundle as `@@TOKEN@@` and
substituted by `scripts/deploy-proxy.sh`. Changing one requires a redeploy.

The rule when adding a setting: **prefer the KVM.** Everything that changes
under time pressure — an emergency budget increase, a price correction, turning
enforcement off during an incident — must be on the fast path. The build fails
if any placeholder survives substitution, so a missed one cannot ship.

---

## 2.6 Failure behaviour, by cause

| What failed | Behaviour | Configurable |
|---|---|---|
| Configuration unreadable | refuse everything, `503` | **no** — always closed |
| Counters unreachable | per `failMode`: closed / open / open-degraded | yes |
| Token invalid or absent | `401` | no |
| Model not in allowlist | `403` | no |
| Model allowed but unpriced | `503` | no — never serve for free |
| `countTokens` unavailable | fall back to estimating from character count | implicitly |
| Screening call fails | fail open, request proceeds | yes, one line |
| Target 5xx | passed through; nothing charged on the response leg | no |

The first two rows are the ones worth internalising. They look similar and are
treated differently on purpose: losing the counters means not knowing what
someone has already spent — bad, and survivable with a bounded degradation.
Losing the configuration means not knowing what anything costs or how large one
call may be — there is no bounded way to serve that.

---

## 2.7 Flow variables

All gateway state is namespaced `cap.*`. The ones worth knowing when reading the
code or debugging a trace:

| Variable | Set by | Meaning |
|---|---|---|
| `cap.identity.subject` / `.tier` / `.team` | `JS-BuildIdentityKeys` | who is being charged |
| `cap.key.user.daily` / `.user.monthly` / `.team.daily` | `JS-BuildIdentityKeys` | the three counter identifiers, period-stamped |
| `cap.budget.*.micros` | `JS-BuildIdentityKeys` | the limits, in micro-units |
| `cap.period.day` / `.month` / `.strategy` | `JS-BuildIdentityKeys` | local period, and which timezone strategy produced it |
| `cap.weight.micros` | whichever JS ran last | **what the next quota step will charge** |
| `cap.charged.request.micros` | `JS-EstimateRequestCost` | what the request leg took |
| `cap.decision.deny` / `.reason` | `JS-EvaluateQuota` and others | the outcome, and why |
| `cap.cost.total.micros` / `.basis` | reconciliation | final cost, and whether it came from real usage or a ceiling fallback |

`cap.weight.micros` is the one to watch. Every quota step reads it, and whichever
JavaScript policy ran most recently owns its value. It is initialised to zero in
`JS-BuildIdentityKeys` so that a mis-ordered flow under-charges visibly rather
than charging a stale value left over from an unrelated step.

`cap.period.strategy` is worth checking once after deployment: it reports
whether local dates came from full timezone data, from the configured offset
table, or from a UTC fallback. See [07-configuration.md](07-configuration.md).
