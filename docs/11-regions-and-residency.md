# 11. Regions and residency

Endpoint hostname forms, what "the data stays in region" does and does not mean,
and the decisions you cannot take back.

---

## 11.1 The three endpoint forms

This trips people up often enough to lead with. The Gemini Enterprise Agent
Platform (formerly Vertex AI) exposes inference at three scopes, and the hostnames are **not** variations on one pattern:

```
  regional      https://REGION-aiplatform.googleapis.com
                e.g. https://europe-west4-aiplatform.googleapis.com

  multi-region  https://aiplatform.JURISDICTION.rep.googleapis.com
                e.g. https://aiplatform.eu.rep.googleapis.com

  global        https://aiplatform.googleapis.com
```

Look at the middle one. The regional form puts the location **first**; the
multi-region form puts it **in the middle**, after `aiplatform`, with a `.rep.`
segment. Deriving one from the other by analogy gives you `eu-aiplatform.
googleapis.com`, which does not exist.

And because it does not exist, the failure is a DNS error at request time — an
opaque 503 from the proxy, minutes or hours after a deployment that reported
success. `scripts/preflight-check.sh` resolves whatever you configure, which is
the entire reason that check is in there.

### Choosing between them

| | Processing location | Availability | Model availability |
|---|---|---|---|
| Regional | one named region | that region's | narrowest — newest models arrive last |
| Multi-region | within a jurisdiction | higher | wider |
| Global | anywhere | highest | widest — newest models arrive first |

The trade is real and it is not primarily about latency: **the strictest
placement guarantee tends to have the fewest models and the least capacity.**
Teams frequently discover that the model they wanted to use is not available in
the region their residency requirement demands, and that discovery should happen
before commitments are made rather than after.

---

## 11.2 Configure it in two places

`VERTEX_HOST` (build time) is substituted into the ServiceCallout policies —
`countTokens` and Model Armor.

`vertex.endpointHost` (runtime, in the KVM) is used to build the target URL for
generation.

**They must agree.** Changing only one gives you a gateway whose token counting
and whose generation calls point at different places — which mostly works,
quietly reports slightly wrong costs, and violates whatever residency
requirement motivated the split.

`vertex.location` must also match the form: a region name for the regional
endpoint, the jurisdiction for multi-region, `global` for global.

---

## 11.3 Where Apigee itself lives

An Apigee organisation has locations of its own, chosen at creation:

| | What it holds | Changeable? |
|---|---|---|
| Control plane location | proxy configuration, runtime metadata | **no** |
| Analytics data region | API usage records | **no** |
| Runtime instance region(s) | where traffic is processed | instances can be added and removed |

The first two are permanent. Not adjustable later, not by support ticket. The
only remedy is deleting the organisation and creating a new one — losing every
proxy, environment, key value map and historical analytics record in it.

This is why `terraform/` deliberately does not create the organisation. An
irreversible decision with residency implications should be taken by a person
reading a checklist, not by a plan output that scrolled past.

### The analytics region matters more than it looks

Apigee analytics receives the dimensions `DC-CaptureUsage` publishes — including
the subject identifier — and its location was fixed when the organisation was
created.

If that identifier is an email address, personal data is now in a store whose
location you cannot change. This is the concrete reason
[04-identity.md](04-identity.md) defaults to an opaque `sub` claim. It is a
one-line configuration change and an unrecoverable one if you get it wrong and
notice a year later.

---

## 11.4 Co-location

Every request makes a gateway → model round trip. With
`preflightCountTokens` enabled, two.

Runtime and inference in the same region: single-digit milliseconds of added
network time, twice per request.

Different continents: 100–200 ms, twice per request, on every single call. That
is not a tuning problem, it is an architectural one, and users feel it on the
first token of every response.

Check both lists before committing:

```bash
gcloud apigee organizations describe ORG --format='value(analyticsRegion,runtimeType)'
gcloud ai models list --region=REGION 2>/dev/null | head
```

Apigee runtime regions and Agent Platform model regions are different lists and do
not fully overlap. If they do not intersect where you need them to, that is a
finding to surface before the organisation exists — afterwards the control plane
location is fixed regardless of what you learn.

---

## 11.5 What residency actually gets you

Worth being precise, because "the data stays in region" is used to mean several
different things.

**A regional endpoint** means inference is processed in that region and data at
rest for the request stays there.

It does **not** automatically mean:

- Logs stay there. Cloud Logging has its own storage location, and your log sink
  writes to a BigQuery dataset whose location you chose separately —
  `spend_dataset_location` in `terraform.tfvars`, which is why that variable has
  no default.
- Apigee analytics stays there. Separate, and fixed at organisation creation.
- Support access is limited to it. That is a contractual question, not a
  technical one.
- Everything else in the project stays there. That is
  `gcp.resourceLocations`, and it is a separate control.

If residency is a compliance requirement rather than a preference, enumerate
**every** store the system touches — the model endpoint, Apigee analytics, Cloud
Logging, the BigQuery ledger, and anything your identity provider records — and
check each one individually. This gateway constrains the first; it gives you
configuration for the third and fourth; it cannot help with the second after the
fact.

---

## 11.6 If the model you need is not available where you need it

A real and common bind. The options, in decreasing order of how much you will
like them:

**Use a different model.** Often the honest answer. A smaller model that is
available where you need it beats a better model you cannot lawfully call.

**Use a broader endpoint scope and document it.** Multi-region within a
jurisdiction is frequently sufficient where a single region is not required.

**Wait.** Model availability expands. If the requirement is genuinely
non-negotiable, waiting is a legitimate plan with a review date.

**Split traffic.** Route data-classified traffic to a compliant regional
endpoint and everything else to a broader one. Two `allowedModels` lists, two
tiers, two proxies — real added complexity, but it beats a blanket restriction
where only some of the traffic needs it.

What not to do is quietly use a global endpoint while telling stakeholders the
data stays in region. The gateway will happily enforce budgets against a global
endpoint and will not comment on the discrepancy.
