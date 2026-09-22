# 10. Security: making the gateway the only road

Everything else in this repository is about metering accurately. This document
is about whether the metering matters at all.

---

## 10.1 The premise

**A metering gateway is a control only if it is the only path to the model.**

If a user can obtain credentials that reach the inference API directly, the
gateway is a courtesy. The caps are real for people who use it and absent for
people who do not, and the people who do not are exactly the people who found a
cap inconvenient.

This is not a hypothetical failure. It is the normal outcome, because the
project that hosts the model usually already has developers with broad roles on
it — granted before anyone thought about spend control — and nothing revokes
them when a gateway is deployed.

So: build the gateway, then **do the audit**. The audit is the control. The
gateway is the mechanism.

---

## 10.2 The audit

### Who can call the model?

```bash
gcloud projects get-iam-policy INFERENCE_PROJECT --format=json \
| jq -r '
    .bindings[]
    | select(.role | test("aiplatform|editor|owner"; "i"))
    | .role as $r | .members[] | "\($r)\t\(.)"
  ' | sort
```

Read every line. The expected result is:

```
projects/INFERENCE_PROJECT/roles/llmGatewayInference   serviceAccount:llm-gateway-runtime@...
```

...plus whatever break-glass administrative access your organisation requires,
held by named humans and audited.

Anything else is a bypass. In particular, look for:

| Principal | Why it is there | Why it is a problem |
|---|---|---|
| `roles/editor` on a group of developers | inherited from project creation | Editor includes `aiplatform.endpoints.predict` |
| `roles/aiplatform.user` on individuals | granted during a prototype | direct model access, unmetered |
| The default Compute Engine service account | automatic, and frequently Editor | anything running on a VM in the project can call the model |
| `allAuthenticatedUsers` | a mistake, but they happen | everyone |

Then check inherited grants, which the project policy does not show:

```bash
gcloud organizations get-iam-policy ORG_ID --format=json \
| jq -r '.bindings[] | select(.role | test("aiplatform|editor|owner"; "i"))
         | .role as $r | .members[] | "\($r)\t\(.)"'
```

And repeat for any folder between the organisation and the project.

### Test it as a user

```bash
# as a normal user, with their own credentials
curl -X POST \
  "https://REGION-aiplatform.googleapis.com/v1/projects/P/locations/L/publishers/google/models/gemini-3.7-flash:generateContent" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}'
```

Must fail with a permission error. Run it as a real user — not as yourself with
admin rights, which proves nothing.

### The ongoing detection

The reconciliation query in [09-observability.md](09-observability.md) §9.5 is
the only routine check that finds a bypass introduced later. If the invoice for
the inference project exceeds what the gateway believes it metered, something is
calling the model without passing through. Run it monthly.

---

## 10.3 Least privilege for the gateway itself

The runtime service account gets a custom role containing two permissions:

```
aiplatform.endpoints.predict
aiplatform.endpoints.computeTokens
```

Not `roles/aiplatform.user`, which is the convenient choice and much too broad —
it also permits creating tuning jobs, deploying endpoints and reading datasets.
A component whose entire job is forwarding one API call should not be able to
start a training run.

This also makes the revocation test meaningful: there is exactly one binding to
remove, and removing it must stop the gateway working.

---

## 10.4 No downloadable service account keys

A JSON key for the runtime account is a file that calls the model, spends money,
is attributable to nobody, can be copied to a laptop, and does not expire. It is
the most direct way to reduce this gateway to a suggestion.

Nothing here needs one — Apigee impersonates the service account, which is
short-lived, revocable and logged.

```
constraints/iam.disableServiceAccountKeyCreation = TRUE
```

Available in `terraform/org-policies.tf` behind `manage_org_policies`.

---

## 10.5 Organisation policies

Off by default, because organisation policies affect resources far beyond this
project and are normally owned by a central platform team. Treat this section as
a proposal to hand to whoever owns policy.

| Constraint | What it adds |
|---|---|
| `iam.disableServiceAccountKeyCreation` | see above |
| `gcp.resourceLocations` | bounds where resources in the project may be created. If residency motivated the gateway, this does more of the real work than the gateway does |
| `vertexai.allowedModels` | bounds what the *project* may serve, independently of what the gateway allows its callers to ask for |

On `vertexai.allowedModels`: keep it in step with the gateway's own
`allowedModels`, with the gateway's list a subset. If they diverge, a model
passes the gateway's allowlist and is then refused upstream — a confusing 403
from the target instead of a clean one from the gateway.

Note what `gcp.resourceLocations` does *not* do: it constrains where resources
are **created**, not where a global or multi-region API endpoint routes a request
internally. That is a separate problem —
[11-regions-and-residency.md](11-regions-and-residency.md).

---

## 10.6 Network controls

IAM is identity-based: the right credential from anywhere works. Network
controls add a second, independent dimension.

**VPC Service Controls** put the inference project inside a perimeter, so calls
from outside it are refused even with valid credentials. This is the strongest
available answer to credential leakage.

It is also genuinely disruptive to introduce. Everything that legitimately calls
the API — including your Apigee runtime — needs to be inside the perimeter or
explicitly bridged, and the failure mode during rollout is that things stop
working with errors that do not obviously say "perimeter". Plan it as its own
project, with a dry-run period.

**Private connectivity** between Apigee and the model, and a private-only
environment group, remove the public internet from the path. Worth doing; note
that neither prevents a credentialed caller *inside* your network from going
direct. They reduce exposure; they do not replace the IAM audit.

---

## 10.7 Bypasses within the gateway

Distinct from going around it — these are ways to use the gateway while paying
less than you should. Each is closed, and it is worth knowing where.

| Bypass | Closed by |
|---|---|
| Call the unmetered streaming endpoint | streaming is metered identically |
| Abandon the stream before usage arrives | ceiling fallback charge ([08-streaming.md](08-streaming.md)) |
| Request a huge `maxOutputTokens` | overwritten with the configured ceiling |
| Request 8 candidates for the price of 1 | `candidateCount` clamped to 1 |
| Use an unpriced model | 503; there is no "free" policy |
| Reach an unhandled path that forwards upstream | terminal `NotFound` flow returns 404 |
| Edit the tier claim in the token | claims come from a signature-verified JWT |
| Share a credential to get a second budget | tokens are per-user and expire; not transferable in practice |
| Downgrade tier to reset a counter | tier is part of the counter key, and downgrades start a *fresh* counter — which is the point; the exploitable direction is closed because a downgrade never restores an old, lower total |
| Spam parallel requests to slip several past the cap | `SA-SpikeArrest`; residual exposure is `concurrency × overshoot bound` |

The one that most often gets left open in home-grown implementations is the
first two. Streaming is where the metering effort runs out.

---

## 10.8 What the gateway can see, and does not keep

`VJ-VerifyIdToken` gives the gateway the caller's full token claims, and the
request body gives it every prompt.

It records: the subject identifier, tier, team, model, token counts, cost,
decision.

It does not record: prompt text, completion text, email addresses, names.

That is a deliberate line, and it is drawn where it is because the ledger and
the analytics store are spend records. Adding prompt content would extend every
residency, retention and access obligation you have to two new stores, silently.
If you need conversation logging, build it separately with its own controls and
make that decision on its own merits.

---

## 10.9 Trusting the price table

An unusual attack surface worth naming: **the price table is a control input.**

Anyone who can write to the key value map can set every price to zero, and the
gateway will meter enthusiastically and enforce nothing. There will be no error,
no alert from the gateway itself, and every dashboard will look healthy — spend
per user will simply be reported as near zero.

Restrict write access to the KVM to the same set of people you would trust to
raise budgets, and rely on the monthly invoice reconciliation as the detection:
a price table set to zero shows up immediately as an enormous divergence between
what the gateway believes and what you are billed.

---

## 10.10 Checklist

Before declaring the gateway a control:

- [ ] The inference project's IAM policy contains exactly one non-administrative
      principal that can call the model, and it is the gateway's
- [ ] Inherited organisation- and folder-level grants checked too
- [ ] A real user, with their own credentials, cannot call the model directly
- [ ] The runtime account holds a predict-only role, not `aiplatform.user`
- [ ] Service account key creation is disabled, or keys are audited
- [ ] `OIDC_AUDIENCE` is set and matches tokens issued for this gateway
- [ ] KVM write access is restricted to budget owners
- [ ] The monthly invoice reconciliation is scheduled and someone owns it
- [ ] The streaming path has been tested, including a deliberate disconnect
- [ ] `GET /v1/budget` has been confirmed not to move the counters
