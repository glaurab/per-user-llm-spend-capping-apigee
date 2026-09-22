# 7. Configuration reference

Every setting, what it does, what it defaults to, and what breaks if you get it
wrong.

---

## 7.1 Two kinds of setting

**Runtime — key value map.** Everything in the three JSON files under `config/`.
Read on every request through a 300-second cache. Changed with `make seed`:
seconds, no redeploy, no proxy revision.

**Build time — bundle placeholders.** A handful of fields Apigee reads when a
policy is compiled rather than when it runs. Written into the bundle as
`@@TOKEN@@` and substituted by `scripts/deploy-proxy.sh`. Changing one requires
a redeploy.

The rule when adding a setting: **prefer the KVM.** Everything that changes
under pressure — an emergency budget increase, a price correction, turning
enforcement off mid-incident — must be on the fast path. The build fails if any
placeholder survives substitution, so a missed one cannot ship.

---

## 7.2 `config/env.sh` — build time

| Variable | Notes |
|---|---|
| `APIGEE_ORG` | Existing organisation. Not created by Terraform |
| `APIGEE_ENV` | Must match `environment_name` in tfvars |
| `APIGEE_ENVGROUP` | Must match `envgroup_name` |
| `APIGEE_HOSTNAME` | Must be covered by the environment group's certificate |
| `PROXY_NAME` | Must match the bundle directory and `llm-gateway.xml` |
| `KVM_NAME` | **Must match `mapIdentifier` in the `KVM-Load*` policies.** That value is baked into the bundle; change one and change both |
| `INFERENCE_PROJECT_ID` / `INFERENCE_LOCATION` | Where the model runs |
| `VERTEX_HOST` | See below |
| `RUNTIME_SA_EMAIL` | From `terraform output runtime_service_account` |
| `OIDC_JWKS_URI` / `OIDC_ISSUER` / `OIDC_AUDIENCE` | Token verification. See below |
| `SPIKE_ARREST_RATE` | e.g. `30pm`. Per presented token |
| `ESCALATION_CONTACT` | Shown in the 429 body |
| `MODEL_ARMOR_HOST` | Only used when screening is enabled |

### `VERTEX_HOST`

Three forms, not interchangeable:

```
  regional      https://REGION-aiplatform.googleapis.com
  multi-region  https://aiplatform.JURISDICTION.rep.googleapis.com
  global        https://aiplatform.googleapis.com
```

Note the inversion in the middle form. Deriving it by analogy with the regional
one produces a hostname that does not resolve, and the symptom is an opaque 503
at request time rather than an error at deploy time. `make check` resolves
whatever you configure. [11-regions-and-residency.md](11-regions-and-residency.md).

### `OIDC_AUDIENCE`

Never leave this empty. Without an audience check the gateway accepts any token
your identity provider has ever issued, for any application in your estate, and
charges the spend to whatever subject that token carries.
`scripts/preflight-check.sh` fails if it is unset.

### `SPIKE_ARREST_RATE`

Keyed on the presented token, which a determined caller can rotate — so this is
burst protection, not access control. Its real job is stopping one client loop
from draining a budget in seconds, and it does that well.

Set it above your busiest legitimate client's peak. Too low and you break the
application that made the gateway worth building.

---

## 7.3 `config/runtime-config.json`

### `features`

| Key | Default | Effect |
|---|---|---|
| `enforce` | `true` | `false` = observation mode: meter, log and report; refuse nothing |
| `preflightCountTokens` | `true` | `false` = estimate input size from character count instead of calling `countTokens` |
| `modelArmorEnabled` | `false` | Content screening |

**`enforce`** is the rollout switch and the incident switch. `make observe` /
`make enforce`.

**`preflightCountTokens`** is a real trade. On: one extra synchronous round trip
per request, and the request-leg charge is exact. Off: no extra call, and the
request leg charges an estimate biased ~15% high, which means some users are
refused slightly earlier than they should be. Total charged is unaffected either
way — the response leg reconciles to reality regardless. Turn it off if the
latency matters more than fair refusal timing.

**`modelArmorEnabled`** is off by default deliberately. Screening is an optional
enhancement; the spend cap — the reason this gateway exists — must not depend
on a second service being healthy.

### `failMode`

`open-degraded` (default) · `open` · `closed`

Applies **only** when the quota counters are unreachable. Configuration failure
is always fail-closed and is not affected by this setting; see
[05-enforcement-semantics.md](05-enforcement-semantics.md) §5.7.

### `degraded`

```json
"degraded": { "model": "gemini-3.5-flash-lite", "maxOutputTokens": 512 }
```

Used only under `open-degraded`. Point `model` at the cheapest thing in your
allowlist and keep `maxOutputTokens` short — during a counter outage this is the
*only* thing bounding spend.

### `vertex`

| Key | Notes |
|---|---|
| `endpointHost` | Same value as `VERTEX_HOST` |
| `projectId` | Billed for inference |
| `location` | Region in the request path. Must match the endpoint form |
| `publisher` | `google` |

### `limits`

| Key | Default | Effect |
|---|---|---|
| `maxOutputTokens` | `2048` | **The single most important number in this file** |
| `maxPromptChars` | `200000` | Prompts above this get 413 |

`maxOutputTokens` overwrites whatever the client asked for. It is what converts
overshoot from unbounded to a number you can publish:

```
  maximum overshoot = maxOutputTokens × highest output price in the table
```

Raising it raises how far one call can push a user past their cap. `make seed`
prints the resulting figure every time.

`maxPromptChars` bounds the input cost of a single call and stops an enormous
prompt from consuming a whole allowance in one request. 200 000 characters is
roughly 50 000 tokens.

### `allowedModels`

An array of model ids. Anything else gets 403 with the allowlist echoed back.

**Every entry must have a price.** `make seed` refuses to push a configuration
where one does not, because the runtime handles that case by returning 503 to
the user — correct, but a poor way to find out.

Keep this in step with the `vertexai.allowedModels` organisation policy if you
use one, or you get a confusing upstream 403 instead of a clean gateway 403.

### `identity`

| Key | Default | Notes |
|---|---|---|
| `subjectClaim` | `sub` | Prefer an opaque id over an email — [04-identity.md](04-identity.md) §4.4 |
| `tierClaim` | `llm_tier` | Absent → `defaultTier` |
| `teamClaim` | `llm_team` | Absent → `defaultTeam` |
| `defaultTier` | `standard` | Also the fallback for an unrecognised tier |
| `defaultTeam` | `unassigned` | |

`defaultTier` should be your **most restrictive** tier. Every caller with a
missing or misspelled tier claim lands here, and the safe direction is less
capability rather than more money.

### `period`

```json
"period": { "zone": "UTC", "offsetMinutes": 0, "dstWindows": [] }
```

Defines when "today" starts. Three strategies, tried in order:

1. `zone` — an IANA name, used when the runtime's JS engine has full timezone
   data. Correct, including DST, with no maintenance.
2. `offsetMinutes` + `dstWindows` — explicit fallback: base offset, plus the
   intervals during which a different offset applies. Correct if you maintain
   the table.
3. UTC — always available, wrong for anyone not in UTC.

```json
"dstWindows": [
  { "from": "2026-03-29T01:00:00Z", "to": "2026-10-25T01:00:00Z", "offsetMinutes": 120 }
]
```

**Check `cap.period.strategy` once after deploying.** If it says `utc` when you
configured a zone, your daily budgets are resetting in the middle of the working
day and nothing else will tell you.

### `modelArmor`

Only read when `features.modelArmorEnabled` is true. `projectId`, `location`,
`templateId`, `maxChars`.

---

## 7.4 `config/pricing.json`

Covered in [03-cost-model.md](03-cost-model.md). Summary:

| Key | Default | Notes |
|---|---|---|
| `models.{id}.input` / `.output` / `.cachedInput` / `.thinking` | — | Currency units **per 1 000 000 tokens** |
| `unknownModelPolicy` | `deny` | or `mostExpensive`. There is no "free" |
| `thoughtsIncludedInCandidates` | `false` | **Verify empirically per model family** — getting it backwards is a silent 2× error |
| `estimatedCharsPerToken` | `4` | Fallback estimate only |
| `estimateSafetyFactor` | `1.15` | Bias the estimate high |
| `estimatedTokensPerNonTextPart` | `260` | Blunt. Calibrate from the ledger if your traffic is multimodal |

The shipped values are placeholders. Replace them.

---

## 7.5 `config/budgets.json`

```json
{
  "currency": "USD",
  "tiers":  { "standard": { "userDaily": 2.00, "userMonthly": 30.00 } },
  "teams":  { "_default": { "daily": 100.00 }, "team-a": { "daily": 250.00 } }
}
```

Whole currency units; converted to micro-units internally.

`teams._default` applies to any team without its own entry, including
`unassigned`. Removing it means unlisted teams get a zero budget, which refuses
every call from them.

`currency` is a label. It appears in headers, the 429 body and the ledger; it
does not convert anything. Your price table must already be in that currency.

Monthly is not 30× daily. Nobody works 30 days, so a 30× monthly cap never binds
and is decoration. Around 15× actually constrains.

---

## 7.6 Changing settings safely

| Change | How | Effect |
|---|---|---|
| Price correction | edit `pricing.json`, `make seed` | ≤ 300 s |
| Budget increase | edit `budgets.json`, `make seed` | ≤ 300 s |
| Allow a model | add to `allowedModels` **and** `pricing.json`, `make seed` | ≤ 300 s |
| Stop enforcing | `make observe` | ≤ 300 s |
| Change fail mode | edit `runtime-config.json`, `make seed` | ≤ 300 s |
| Change JWKS/issuer/audience | edit `env.sh`, `make deploy` | redeploy |
| Change SpikeArrest rate | edit `env.sh`, `make deploy` | redeploy |
| Change endpoint host | edit **both** `env.sh` and `runtime-config.json`, then `make deploy` | redeploy |

That last row is the one to watch: the endpoint host appears in two places — as
a build-time placeholder in the ServiceCallout policies, and as a runtime value
used to build the target URL. Changing only one gives you a gateway whose token
counting and whose generation calls point at different regions.

### The 300-second cache

`ExpiryTimeInSecs` on the `KVM-Load*` policies. Shorter means more reads on the
hot path; longer means a budget change that appears not to work.

If you need an immediate effect, redeploying the proxy clears the cache. During
an incident, remember that `make seed` takes up to five minutes to bite — and
that the clock starts when you run it, not when you notice.
