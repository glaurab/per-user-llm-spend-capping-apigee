# Per-user LLM spend capping

A deployable reference implementation of a metering gateway that stops an
**individual person** from spending more than their allowance on a large
language model, and refuses their next call when they have.

Built on Apigee X in front of Gemini models on the **Gemini Enterprise Agent
Platform** (formerly Vertex AI). Google Cloud and open source only, and
deliberately so — this is a Google Cloud design and it names Google Cloud
products throughout. What it is *not* specific to is any organisation, industry
or region.

> **On dated claims.** This repository states facts about Google Cloud products,
> prices and packaging that are true at a point in time and will not stay true.
> Wherever one of those appears it is marked **(August 2026)**, so you can tell
> at a glance what needs re-checking rather than discovering it from a support
> ticket. If a statement carries no date, it is a property of the design rather
> than of the platform.

### A note on naming *(August 2026)*

Vertex AI was renamed the **Gemini Enterprise Agent Platform** — "Agent
Platform" for short, which is how the rest of these documents refer to it. Do
not confuse it with **Gemini Enterprise**, the per-seat enterprise assistant:
different product, different billing model. This gateway is about the
token-billed Agent Platform.

The rename is a product and console rename. **As of August 2026 the API surface
still says `aiplatform`**, and that is not an oversight in this repository:

| Still spelled the old way | Where you will see it |
|---|---|
| `aiplatform.googleapis.com`, `REGION-aiplatform.googleapis.com` | endpoint hostnames, `VERTEX_HOST` |
| `aiplatform.endpoints.predict`, `aiplatform.endpoints.computeTokens` | the custom IAM role in `terraform/iam.tf` |
| `roles/aiplatform.user` | the over-broad role this design avoids |
| `constraints/vertexai.allowedModels` | the optional org policy |
| `gcloud ai …` | CLI commands in the runbooks |

Internal names in this repository follow the same rule: `AM-BuildVertexRequest`,
`targets/vertex.xml`, `VERTEX_HOST` and `vertex.endpointHost` keep their names
so that they match the identifiers they wrap. Renaming them would gain nothing
and break every reference.

One practical consequence: **billing line items moved from "Vertex AI" to
"Gemini Enterprise Agent Platform" labels** *(August 2026)*. If you have BigQuery
billing queries or dashboards that filter on the service description as text, check them
before relying on the reconciliation in
[docs/09-observability.md](docs/09-observability.md) §9.5.

---

## The problem in one paragraph

Google Cloud meters by project, not by person. You can cap what a *project*
spends on Agent Platform inference — sort of, and after the fact — but you cannot cap
what Alex spends, because Google Cloud has never heard of Alex. Every request
arrives as the same service account, from the same project, and is billed to
the same billing account. Cloud Billing budgets notify you hours later and never
block. Agent Platform quotas count requests and tokens per project, region and
model, not per human, and not in money. IAM can say yes or no but cannot count.

So a per-user cap has to be built. It requires a **choke point**: something
that sits between the user and the model, knows who is calling, knows what each
call costs, keeps a running total per person, and refuses when the total is
spent. That is what this repository is.

New to the problem? Read **[docs/01-concepts.md](docs/01-concepts.md)** first.
It builds the whole thing up from first principles and assumes no prior
knowledge of Apigee, Agent Platform or token pricing.

---

## What it actually does

```
                                 ┌──────────────────────────────┐
   caller ──── signed JWT ──────▶│  Apigee X gateway            │
                                 │                              │
                                 │  who are you?    (verify)    │
                                 │  what will this cost?        │
                                 │  can you afford it? ──────┐  │
                                 │                           │  │
                                 │       ┌───────────────────▼─┐│
                                 │       │ per-user counters   ││
                                 │       │ money, not tokens   ││
                                 │       └───────────────────┬─┘│
                                 │                           │  │
   429 with remaining ◀──────────┤  no ◀─────────────────────┘  │
   budget + reset time           │                              │
                                 │  yes                         │
                                 └───────────────┬──────────────┘
                                                 │
                                        ┌────────▼───────┐
                                        │ Agent Platform │
                                        └────────┬───────┘
                                                 │
                            charge the difference between
                            what we estimated and what it
                            really cost, then return
```

Concretely:

| | |
|---|---|
| **Caps money, not tokens** | Counters hold micro-units of currency. A token cap is meaningless when one model's token costs twenty times another's. |
| **Charges in two legs** | Input cost is charged up front and *can refuse*. The remainder is charged after the response arrives and never refuses — the answer already exists. |
| **Bounds the overshoot** | The gateway overwrites the client's `maxOutputTokens`, so the worst a single call can push someone past their cap is a number you can compute and publish. |
| **Three counters** | Per user per day, per user per month, per team per day. Tightest wins. |
| **Correct local days** | Budget periods begin at local midnight in a configured timezone, DST included — not at a shared UTC instant that hands half your users a free reset at lunchtime. |
| **Meters streaming too** | Server-sent events are metered per event, and an abandoned stream is still charged. Otherwise "close the tab" is a free call. |
| **Tells the caller** | Every response carries cost and remaining budget. `GET /v1/budget` answers "how much do I have left" without spending any. A refusal says what was breached, by how much, when it resets and who to ask. |
| **Fails deliberately** | If the counters are unreachable you choose: refuse everything, serve everything, or serve a cheap model with a short ceiling and alert. If the *configuration* is unreachable it always refuses, because unpriceable traffic is unbounded traffic. |

---

## Repository layout

```
docs/                           the reasoning, from first principles
  01-concepts.md                why this cannot be done natively — start here
  02-architecture.md            components and the life of a request
  03-cost-model.md              micro-units, the price table, the full formula
  04-identity.md                who the caller is, and why that must be unforgeable
  05-enforcement-semantics.md   split-charge, overshoot, periods, fail modes
  06-deployment.md              first deploy, step by step
  07-configuration.md           every setting, its default and its blast radius
  08-streaming.md               SSE metering and the disconnect problem
  09-observability.md           the ledger, dashboards, invoice reconciliation
  10-security.md                making the gateway the only road, not a suggestion
  11-regions-and-residency.md   endpoint forms, residency, what is irreversible
  12-operations-runbook.md      raise a cap, price change, incident response
  13-validation-gates.md        three assumptions to verify on your own version
  adr/                          six decision records: the unit, the split
                                charge, the quota primitive, the period
                                boundary, identity, and the fail mode

proxy/llm-gateway/    the Apigee bundle: policies, flows, JavaScript
terraform/            environment, KVM, service account, log sink, alerts
config/               price table, budgets, runtime settings (examples)
scripts/              preflight, deploy, seed, smoke test
```

Everything in the tree is either something you deploy or something that
explains what you are deploying. There is no planning material, no design
history and no working notes: this repository is the artefact, not the account
of how it was made.

---

## Quickstart

Prerequisites: an existing **Apigee X organisation** with a runtime instance, a
project with the Agent Platform API enabled, an OIDC identity provider, and
`gcloud`, `terraform`, `jq` and [`apigeecli`](https://github.com/apigee/apigeecli)
on your path.

**The Apigee organisation is assumed to exist and is *not* created by the
Terraform here.** Terraform manages everything below the organisation — the
environment, the environment group, the key value map, the service account, the
log sink — and nothing above it. Creating an organisation permanently fixes its
control-plane location and analytics region; that decision belongs in a
checklist a person reads, not in a plan output that scrolls past.
[docs/06-deployment.md](docs/06-deployment.md) covers it.

One prerequisite that is easy to miss until the deploy fails, and it depends on
which Apigee pricing model you are on. Apigee packaging is restructured
periodically, so everything in this subsection is **as of August 2026** and is
worth confirming against the current
[environment types documentation](https://cloud.google.com/apigee/docs/api-platform/reference/pay-as-you-go-environment-types).

This proxy uses JavaScript and ServiceCallout policies. Those are **extensible
policies**, and using even one of them makes the whole proxy an **Extensible API
proxy**.

- **Subscription plans** — nothing to check. Every environment is Comprehensive,
  environment types are not a concept you are exposed to, and this proxy
  deploys.
- **Pay-as-you-go** — environments have a *type*: `BASE`, `INTERMEDIATE` or
  `COMPREHENSIVE`. Extensible proxies **cannot be deployed into a Base
  environment**, so you need Intermediate or Comprehensive. A pay-as-you-go
  organisation is provisioned with an Intermediate environment by default, so
  this only bites if someone deliberately created a Base one — and it is
  recoverable, since the type can be changed in place (Management →
  Environments → Edit, or `PATCH …/environments/ENV?updateMask=type`) as long as
  the environment holds nothing incompatible.

Two consequences worth knowing before you cost this out. Extensible proxy calls
are billed at **five times** the Standard rate, and there is no variant of this
design that is Standard. And pay-as-you-go environments start accruing charges
when they are **attached to an instance**, not when traffic arrives.

```bash
make init      # copy the example config files into place
$EDITOR config/env.sh config/*.json terraform/terraform.tfvars

make check     # preflight: tools, config, Apigee, IAM, endpoint DNS, IdP
make infra     # terraform apply
make seed      # push prices, budgets and settings into the key value map
make deploy    # build the bundle and deploy it
make smoke     # exercise it end to end
```

Then:

```bash
export GATEWAY_TEST_TOKEN="...a token from your IdP..."

curl -X POST "https://$HOST/llm/v1/models/gemini-3.7-flash:generateContent" \
  -H "Authorization: Bearer $GATEWAY_TEST_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Hello"}]}]}' -i
```

```
HTTP/2 200
x-budget-currency: USD
x-budget-call-cost: 0.0004
x-budget-remaining: 1.9996
x-budget-period-resets-in: 41231
x-budget-enforcement: on
```

---

## What you have to change before this is yours

This is a reference implementation, which means every value in it is either a
placeholder or somebody else's decision. The two are not equally dangerous, and
this section separates them on exactly that basis.

Nothing here is secret. `config/env.sh`, `config/*.json` (your copies) and
`terraform/terraform.tfvars` are gitignored because they are
*environment-specific*, not because they are sensitive.

### 1. Placeholders — nothing works until you replace them

These are written as obvious non-values so they cannot be mistaken for
defaults. Every one of them fails loudly: `make check` refuses, `terraform
apply` errors, or DNS does not resolve. That is the intended behaviour.

| Placeholder | Where | Replace with |
|---|---|---|
| `your-apigee-org` | `config/env.sh` → `APIGEE_ORG` | your existing Apigee organisation |
| `my-apigee-project`, `my-instance` | `terraform.tfvars` → `project_id`, `apigee_org`, `apigee_instance_id` | `gcloud apigee organizations list`, `gcloud apigee instances list` |
| `your-inference-project-id` | `env.sh` → `INFERENCE_PROJECT_ID`; `runtime-config.json` → `vertex.projectId`; `terraform.tfvars` → `inference_project_id` | the project that will be **billed** for model usage |
| `REGION` | `env.sh` → `INFERENCE_LOCATION`, `VERTEX_HOST`, `MODEL_ARMOR_HOST`; `runtime-config.json` → `vertex.location`, `vertex.endpointHost`; `terraform.tfvars` → `region` | see below — this is not a simple find-and-replace |
| `REGION_OR_MULTIREGION` | `terraform.tfvars` → `spend_dataset_location` | the BigQuery location for the spend ledger. Fixed at dataset creation |
| `llm.example.internal` | `env.sh` → `APIGEE_HOSTNAME`; `terraform.tfvars` → `gateway_hostnames` | the hostname clients call. Must be covered by the environment group's TLS certificate |
| `https://your-idp.example.com/…` | `env.sh` → `OIDC_JWKS_URI`, `OIDC_ISSUER`, `OIDC_AUDIENCE` | your identity provider. **Build-time — changing these needs a redeploy** |
| `llm-gateway-runtime@your-apigee-org.…` | `env.sh` → `RUNTIME_SA_EMAIL` | must match the service account Terraform creates |
| `platform-team@example.com` | `env.sh` → `ESCALATION_CONTACT` | who a blocked user should actually ask for more budget |
| `[]` | `terraform.tfvars` → `alert_notification_channels` | create the channels first, then paste the ids. Left empty, the alerts deploy and notify nobody |

**On `REGION` specifically.** Three of those occurrences are not the same kind
of value, and substituting one string everywhere produces a hostname that does
not exist. The inference endpoint has three forms and the multi-region one is
*inverted* relative to the regional one:

```
regional      https://REGION-aiplatform.googleapis.com
multi-region  https://aiplatform.JURISDICTION.rep.googleapis.com
global        https://aiplatform.googleapis.com
```

`scripts/preflight-check.sh` resolves whatever you configure before you deploy,
because otherwise the mistake surfaces as a DNS error at request time.
[docs/11-regions-and-residency.md](docs/11-regions-and-residency.md) explains
which form you want and what each one costs you.

### 2. Working values that are still decisions — these deploy silently

This is the more dangerous list. Every value below is real, valid, and will
deploy without complaint. None of them is right for you by accident.

| Setting | Shipped as | Why it is yours to set |
|---|---|---|
| **Prices** — `config/pricing.json` | Gemini list rates, standard tier, global endpoint, **as of 16 August 2026** | A price table is a dated snapshot. `gemini-3.7-flash` is on an introductory rate that **doubles on 1 January 2027**; non-global endpoints carry roughly a 10% premium; `gemini-3.1-pro` moves to a higher tier above 200k input tokens. A stale table means your meter is confidently wrong, and nothing in the gateway can detect it — §12.7 reconciliation is how you find out |
| **Budgets** — `budgets.json` → `tiers` | `standard` 2.00/day, `elevated` 10.00, `unmetered` 500.00 | Pure illustration. Do not ship these. Get them from observation mode (next section) |
| **Teams** — `budgets.json` → `teams` | `example-team-a`, `example-team-b`, `_default` 100.00 | The example names exist to show the shape. Any team not listed falls to `_default` |
| **Currency** — `budgets.json` → `currency` | `USD` | A label on the counters and the headers. It does **not** convert anything: it must match the currency your prices are written in |
| **`limits.maxOutputTokens`** | `2048` | The single most important number in the config. It is what makes worst-case overshoot stateable: `maxOutputTokens × the output price of the dearest allowed model`. Raise it and you raise how far one call can push someone past their cap. `make seed` prints the resulting figure |
| **`limits.maxPromptChars`** | `200000` | Chosen to stay an order of magnitude clear of the 200k-*token* long-context pricing cliff **as it stood in August 2026**, which is what lets a single rate per model remain correct. Both the threshold and which models have one can move. If you raise this, or if the tier boundary drops, re-check the price table against the long-context rates |
| **`allowedModels`** | the three Gemini models current in **August 2026** | Your allowlist, and it dates as fast as the model line-up does. Adding a model means three edits, not one — price, allowlist, and the org policy if you use it. [docs/12](docs/12-operations-runbook.md) §12.3 |
| **`degraded.model` / `maxOutputTokens`** | `gemini-3.5-flash-lite`, `512` | What gets served when the counters are unreachable. Should be the cheapest model you are willing to serve, not simply the cheapest one listed — and "cheapest" was **August 2026**. Re-check it whenever the model line-up changes, since a degraded mode pointing at a no-longer-cheap model is the definition of a control that quietly stopped working |
| **`period.zone`** | `UTC` | **Not a neutral default — a decision.** It defines when "today" starts for every user. Leave it at UTC only if your users genuinely are. The gateway reports which strategy it actually resolved in `cap.period.strategy`; check it once after deploying |
| **`identity.*Claim`** | `sub`, `llm_tier`, `llm_team` | Only `sub` is standard. The other two are names this project invented; yours will differ. A tier claim that matches nothing demotes the caller to `defaultTier` **silently** |
| **`failMode`** | `open-degraded` | Availability versus cost exposure, and it is a governance call rather than a technical one. [docs/05](docs/05-enforcement-semantics.md) |
| **`SPIKE_ARREST_RATE`** | `30pm` | Burst protection sized for interactive human use. Build-time |
| **`budget_exceeded_alert_threshold`** | `25` | Refusals per hour before anyone is told. Depends entirely on your population size |
| **`manage_org_policies`** | `false` | Organisation policies usually belong to someone other than you. Read [docs/10-security.md](docs/10-security.md) and go and talk to them |
| **`grant_predict_via_custom_role`** | `true` | The narrow custom role instead of `roles/aiplatform.user`. Set it false only if custom roles are blocked in your organisation, and know what you are widening |
| **Model Armor** — `modelArmorEnabled`, `modelArmor.*` | `false`, empty | Off by design, so the spend cap has no dependency on an optional service. Turning it on means filling in the project, location and template, and setting `MODEL_ARMOR_HOST` |

### 3. Things that look like placeholders and are not

Worth knowing before you start renaming.

| Looks changeable | Leave it, or change it carefully |
|---|---|
| `vertex`, `aiplatform`, `VERTEX_HOST`, `AM-BuildVertexRequest` | Deliberate. The product was renamed; the API surface was not — **true as of August 2026**, and worth re-checking, because the day the API surface does move these identifiers stop matching what they wrap. See the naming note at the top |
| `llm-gateway` (env, envgroup, KVM, proxy, bundle directory) | Changeable, but the name appears in `env.sh`, `terraform.tfvars`, the bundle directory and the `name` attribute in `llm-gateway.xml`. Change all four or none |
| Micro-units in the counters | An internal representation, never something you write. Budgets and prices are in whole currency units and the gateway converts |
| `_documentation` / `_note` keys in the JSON | Read by people, ignored by the loader. Keep them; they are where the reasoning lives |

### 4. Not configuration at all, and still yours

Three things no config file can settle, in rough order of how badly they bite.

**The IAM audit.** A metering gateway is only a control if it is the only path
to the model. This is the one item on the list that can invalidate the entire
deployment, and it is not a setting —
[docs/10-security.md](docs/10-security.md) §10.2 has the audit, and it needs
re-running quarterly because grants accumulate.

**The three validation gates.** Behaviours this design depends on, which you
should confirm on your own Apigee version. See the last section of this README.

**Monthly invoice reconciliation.** Somebody owns it, or the price table drifts
and takes your spend reporting with it. [docs/12](docs/12-operations-runbook.md)
§12.7.

---

## Roll it out in observation mode first

`make observe` switches enforcement off while leaving everything else on. The
gateway meters every call, records what it cost, publishes budget headers and
fills the spend ledger — and refuses nothing.

This is not a debug setting. It is the intended first phase. Caps chosen before
you know what people's work actually costs are guesses, and a guess that is too
low arrives as an outage for the users least able to explain what happened.
Run in observation for long enough to see a real distribution — a few weeks,
including whatever your equivalent of month-end is — then set caps from the
data and `make enforce`.

[docs/09-observability.md](docs/09-observability.md) has the queries for
choosing caps from the ledger.

---

## Before you trust it

Three mechanisms at the centre of this design depend on Apigee behaviour that
you should confirm on your own version rather than take on faith. Each has a
test and a documented fallback in
**[docs/13-validation-gates.md](docs/13-validation-gates.md)**:

1. the same quota policy attached at two points in a flow shares one counter,
2. a quota's message weight can be a computed integer flow variable,
3. `EventFlow` can run JavaScript per SSE event without breaking the stream.

If any of them turns out to be false on your Apigee version, the fallback costs
you precision, not enforcement.

And one thing that is not an Apigee question at all: **a metering gateway is
only a control if it is the only path to the model.** If callers hold
credentials that reach the inference API directly, this is a courtesy that the
first person to read the API docs will stop using.
[docs/10-security.md](docs/10-security.md) has the audit.
