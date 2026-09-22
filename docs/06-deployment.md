# 6. Deployment

From nothing to a serving gateway. Roughly two hours the first time, most of it
waiting for the Apigee organisation.

---

## 6.1 Prerequisites

| | |
|---|---|
| An Apigee X organisation with a runtime instance | see §6.2 — **not** created by the Terraform here |
| A project with the Gemini Enterprise Agent Platform API enabled | formerly Vertex AI; may be the same project |
| An OIDC identity provider | any; only its JWKS endpoint is contacted |
| A DNS name and TLS certificate for the gateway | attached to the environment group |
| `gcloud`, `terraform`, `jq`, [`apigeecli`](https://github.com/apigee/apigeecli) | on your path |

Permissions you will need: Apigee Organization Admin, Project IAM Admin on both
projects, and BigQuery/Logging admin on the Apigee project.

---

## 6.2 Step 1 — the Apigee organisation (manual, and irreversible)

**Do not automate this.** Creating an Apigee organisation permanently fixes two
properties:

- the **control plane location**, which determines where proxy configuration and
  runtime metadata live;
- the **analytics data region**, which determines where usage records live.

Neither can be changed afterwards. Not by editing Terraform, not by support
ticket. The only remedy is deleting the organisation — and with it every proxy,
environment, key value map and historical analytics record inside it.

That is why this repository leaves it to a human reading a checklist rather than
to a plan output that scrolled past.

```bash
gcloud services enable apigee.googleapis.com \
  compute.googleapis.com servicenetworking.googleapis.com \
  aiplatform.googleapis.com --project=PROJECT_ID
```

Then create the organisation through the console or `gcloud apigee`
([provisioning guide](https://cloud.google.com/apigee/docs/api-platform/get-started/provisioning-intro)),
and record your answers to:

| Decision | Why it matters |
|---|---|
| Control plane location | Permanent. Where configuration lives |
| Analytics region | Permanent. Where usage records live |
| Runtime region(s) | Where traffic is processed. Latency to the model endpoint |
| Networking | Whether the gateway is reachable from the public internet |
| Billing type | Subscription vs. pay-as-you-go |

Two points that specifically affect this gateway.

**Runtime and inference should be close.** Every request makes a gateway →
model round trip, and if `preflightCountTokens` is on, two. A gateway in one
region calling a model in another adds that latency to every call, twice.

**Check availability before promising a region.** Apigee runtime regions and
Agent Platform model regions are different lists and do not fully overlap. Confirm
both support what you need *before* the organisation is created, because
afterwards the control plane location is fixed regardless of what you learn.
See [11-regions-and-residency.md](11-regions-and-residency.md).

Then create a runtime instance and note its id:

```bash
gcloud apigee instances list --organization=ORG
```

---

## 6.3 Step 2 — configure

```bash
git clone <this repository> && cd <it>
make init
```

Four files to edit. `make init` will not overwrite existing copies.

| File | Contents |
|---|---|
| `config/env.sh` | build-time settings: org, environment, hostnames, JWKS URI, endpoint host |
| `config/runtime-config.json` | feature switches, allowlist, limits, timezone, fail mode |
| `config/pricing.json` | the price table — **replace the placeholder prices** |
| `config/budgets.json` | per-tier and per-team caps |
| `terraform/terraform.tfvars` | projects, regions, instance id, notification channels |

Three things to get right now rather than debug later.

**`VERTEX_HOST` must be the exact endpoint host.** The three forms are not
interchangeable and one of them is inverted relative to the others:

```
  regional      https://REGION-aiplatform.googleapis.com
  multi-region  https://aiplatform.JURISDICTION.rep.googleapis.com
  global        https://aiplatform.googleapis.com
```

Guessing the multi-region form by analogy with the regional one produces a
hostname that does not exist, and the failure arrives as a DNS error at request
time. `make check` resolves it for you.

**`OIDC_AUDIENCE` must not be empty.** Without an audience check the gateway
accepts any token your IdP ever issued, for any application.
[04-identity.md](04-identity.md) §4.3.

**Set `period.zone`** to the timezone your users' working day follows.
Otherwise daily budgets reset in the middle of it.

---

## 6.4 Step 3 — preflight

```bash
make check
```

Checks tooling, config validity, that every allowed model has a price, that no
tier has a zero budget, that the Apigee environment and KVM exist, that the
runtime service account exists and the Apigee service agent can impersonate it,
that the inference hostname resolves, that a real `generateContent` call returns
`usageMetadata`, and that the JWKS endpoint serves keys.

Every one of those corresponds to a failure that is cheap now and expensive
later — most of them surface at request time as a 500 with no useful body.

On a first run the Apigee checks will fail because the environment does not
exist yet. That is expected; run `make infra`, then run `make check` again.

---

## 6.5 Step 4 — infrastructure

```bash
make plan     # read it
make infra
```

Creates the environment and environment group, attaches them to the instance,
creates the key value map, creates the runtime service account with a
predict-only custom role, grants the Apigee service agent permission to
impersonate it, and sets up the BigQuery sink, log metrics and alert policies.

Attaching an environment to an instance takes several minutes.

---

## 6.6 Step 5 — seed and deploy

```bash
make seed
```

Validates the three JSON files, refuses a configuration where an allowed model
has no price, writes them into the KVM, and prints a summary — including the
worst-case overshoot computed from your ceiling and your most expensive model.
Read that number; it is the one you will be asked about.

```bash
make deploy
```

Substitutes the build-time placeholders into a copy of the bundle, fails if any
survive, ensures the analytics data collectors exist, imports the bundle and
deploys it with the runtime service account attached.

---

## 6.7 Step 6 — verify

```bash
export GATEWAY_TEST_TOKEN="$(...mint a token from your IdP...)"
make smoke
```

There is deliberately no test bypass. A gateway with a backdoor for testing is a
gateway with a backdoor. How to mint a token depends on your provider — a client
credentials grant with the right audience, or `gcloud auth print-identity-token`
if you are fronting with IAP.

The smoke test asserts that a call is metered and returns cost headers; that
reading the budget costs nothing; that streaming is charged; that a disallowed
model gets 403, an unknown path 404, and an unauthenticated call 401.

The cap-exhaustion test is skipped unless you ask for it, because it spends a
real budget down to zero:

```bash
SMOKE_TEST_EXHAUST_BUDGET=true make smoke
```

Use a test subject on a tier with a small cap. It verifies the 429 arrives, that
its body carries the breached limit and a reset time, and that the final balance
never falls further past zero than the stated overshoot bound.

### The verification that matters most

Everything above tests the gateway. This tests whether the gateway *matters*:

```bash
# As a normal user, with their own credentials, try the model directly.
curl -X POST \
  "https://REGION-aiplatform.googleapis.com/v1/projects/PROJECT/locations/REGION/publishers/google/models/gemini-3.7-flash:generateContent" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}'
```

**This must fail with a permission error.** If it succeeds, the gateway is
decorative: every cap in it can be avoided by anyone who reads the API
documentation, and there is no log of them doing so.

Run it as a real user, not as yourself with admin rights. Then work through
[10-security.md](10-security.md), which lists the principals to check and the
query to find them.

---

## 6.8 Step 7 — observation mode

```bash
make observe
```

Meter everything, refuse nothing. Leave it here.

Set caps from data, not from intuition. Run long enough to see a real
distribution — a few weeks, including whatever your month-end looks like — then
use the percentile query in [09-observability.md](09-observability.md) to choose
numbers, and:

```bash
make enforce
```

Tell users before you do. A cap that appears without warning is an incident from
their point of view, whatever it says in the change log.

---

## 6.9 Client migration

Clients change two things:

```diff
- https://REGION-aiplatform.googleapis.com/v1/projects/P/locations/L/publishers/google/models/MODEL:generateContent
+ https://gateway.example.internal/llm/v1/models/MODEL:generateContent

- Authorization: Bearer <google access token>
+ Authorization: Bearer <your OIDC id token>
```

Request and response bodies are the model API's own and unchanged. That
compatibility is worth protecting: a gateway with a bespoke request format is a
gateway people write scripts to avoid.

Worth telling client authors about:

- `429` now means budget, not rate limiting. The body says which and when it
  resets.
- `maxOutputTokens` is capped by the gateway. Asking for more is not an error;
  it is silently reduced.
- `candidateCount` is forced to 1.
- Response headers carry cost and remaining budget on every call.
- `GET /v1/budget` is free — use it to show a balance rather than inferring one.

---

## 6.10 Rollback

```bash
# previous proxy revision
apigeecli apis deploy -n llm-gateway -v <previous> -e <env> -o <org> --ovr --wait

# configuration only — usually enough, and much faster
$EDITOR config/*.json && make seed

# stop enforcing without changing anything else
make observe

# stop serving entirely
make undeploy
```

Most incidents are configuration, not code. Reach for `make seed` and
`make observe` first: both take effect within the 300-second cache TTL, need no
redeploy, and are reversible.
[12-operations-runbook.md](12-operations-runbook.md) has the specific runbooks.
