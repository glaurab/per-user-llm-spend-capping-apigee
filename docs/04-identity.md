# 4. Identity

A per-user cap is only as good as its answer to "which user?". This document
covers how the gateway establishes that, why it refuses some plausible-looking
alternatives, and what the choice costs you in privacy terms.

---

## 4.1 The requirement

The gateway needs an identifier that is:

**Unforgeable.** If a caller can change it, they can reset their own budget by
changing one string. This is the whole ballgame.

**Stable.** It becomes part of a counter key. If it changes, the user gets a
fresh budget. If it is reused after someone leaves, the new person inherits a
balance.

**Not transferable.** Two people sharing one identifier share one budget — which
sounds fine until it means neither of them can work because the other was busy.

**Present on every request**, cheaply. It is on the hot path.

---

## 4.2 Why not an API key

API keys are the obvious answer and they fail the first test completely.

An API key is a **bearer secret**: whoever holds the string is the identity. It
can be copied into a colleague's terminal, committed to a repository, pasted
into a chat message. Nothing about presenting one demonstrates that you are the
person it was issued to.

So a per-key cap caps a *key*, not a person. And the failure mode is not theft —
it is helpfulness. Someone hits their cap, a teammate shares their key, and the
control has been routed around by two people trying to get work done. There is
no log entry that says anything is wrong.

Keys also have no expiry, no revocation propagation, and no claims — no tier, no
team, nothing to derive a budget from without a separate lookup table that has
to be kept in step with your identity system and won't be.

**This implementation uses signed tokens.** A JWT from your identity provider is
verified against the provider's public keys on every request. Forging one
requires the provider's private key.

---

## 4.3 What the gateway does

`VJ-VerifyIdToken` checks, on every request:

| Check | Failure means |
|---|---|
| Signature (RS256, against the JWKS) | the token was not issued by your IdP |
| `iss` matches the configured issuer | issued by a different IdP entirely |
| `aud` matches the configured audience | issued for a different application |
| `exp` in the future | expired |
| `sub` present | nothing to meter |

Keys are fetched from the JWKS endpoint and cached, so this is not a network
round trip per request.

### The audience check is not optional

`OIDC_AUDIENCE` is asserted as non-empty by `scripts/preflight-check.sh`, and
this is the reason.

Without it, the gateway accepts **any** token your identity provider has ever
issued — including one minted for a completely unrelated internal application.
Anyone who can obtain a token for any service in your estate can spend against
this gateway, charged to whatever subject that token happens to carry.

Configure your IdP to issue tokens whose audience is this gateway, and configure
the gateway to demand exactly that.

---

## 4.4 Choosing the subject claim

Configurable, defaulting to `sub`:

```json
"identity": {
  "subjectClaim": "sub",
  "tierClaim":    "llm_tier",
  "teamClaim":    "llm_team",
  "defaultTier":  "standard",
  "defaultTeam":  "unassigned"
}
```

`sub` rather than `email`, and the reason is worth spelling out because `email`
is so much more convenient.

The subject identifier is written into **quota keys, analytics dimensions, and
every row of the spend ledger**. Choosing `email` puts a piece of personal data
into all three. Those stores have their own locations, their own retention, and
their own access controls — and Apigee's analytics store in particular has a
location fixed when the organisation was created, which cannot be changed
afterwards.

So `email` silently extends every data-residency and retention obligation you
have to a set of stores nobody thought about when the obligation was written.
`sub` is an opaque identifier: stable, unique, and meaningless to anyone without
access to your directory.

**If you need names**, keep the mapping from subject to person in a system you
already control, and join on it when you produce a report. The join happens in
the place where you already handle personal data properly, rather than in three
new places.

This is the default because it is the right default for most organisations. It
is one configuration line to change if your circumstances differ.

A related caution: verify that your IdP's `sub` is genuinely stable and not
recycled. Some directories reuse identifiers after an account is deleted. If
yours does, a new joiner can inherit a departed colleague's budget balance and,
more awkwardly, their spend history.

---

## 4.5 Tier and team

**Tier** decides which budget applies. **Team** adds a second, aggregate
counter, so that a group's total is bounded even when no individual exceeds
their own allowance.

Both come from claims, and both are optional — absent, everyone lands on
`defaultTier` and `defaultTeam`.

The important property is that tier assignment lives in your identity provider,
not in the gateway. Groups you already maintain map to claims; the gateway reads
them. The alternative — a list of usernames in the gateway's configuration —
goes stale within a week, and then it is a list nobody trusts and everybody
works around.

### Unrecognised tiers fall to the most restrictive

If the tier claim holds something not present in `budgets.json`, the caller is
demoted to `defaultTier`. Never promoted, never granted an implicit unlimited
budget.

A typo in an identity-provider group mapping should cost the caller capability,
not cost the organisation money. This is the safe direction, and the failure is
visible — a user complains their budget is smaller than expected, which is a
conversation, rather than nobody noticing until the invoice.

### Tier is part of the counter key

```
u|{subject}|{tier}|D|{date}
```

Including the tier means that moving a user between tiers mid-period starts them
on a fresh counter rather than inheriting one sized for the old budget.

Without it, downgrading a user from `elevated` to `standard` would leave them
holding a counter that already reads, say, 8.00 spent — instantly over a 2.00
standard cap, refused for the rest of the day, for an administrative action they
did not take. And in the other direction it would be exploitable: upgrade,
spend, downgrade, upgrade again.

The trade-off is that a tier change grants a fresh allowance for the remainder
of the period. That is the lesser problem: tier changes are administrative
events, they are logged, and they are rare.

---

## 4.6 Using Identity-Aware Proxy instead

If your users reach the gateway through IAP, you already have a verified
identity and can use it instead of running your own JWT verification.

IAP injects `x-goog-iap-jwt-assertion`, a signed assertion carrying `sub` and
`email`. The changes are:

1. Verify against Google's IAP public keys rather than your IdP's JWKS, with the
   issuer `https://cloud.google.com/iap` and the audience being your IAP
   resource identifier.
2. Read the assertion from that header instead of `Authorization`.
3. Drop the `EV-ExtractBearerToken` step, or keep it if you also want SpikeArrest
   keyed on the presented credential.

Everything downstream — keys, budgets, counters, enforcement — is unchanged. It
reads a claim from a verified token; where the token came from does not matter.

The trade: IAP is straightforward for browser-based access and awkward for
service-to-service and CLI callers. Most deployments that serve both end up
verifying OIDC tokens directly, which is why that is the default here.

On Google Cloud the issuer is usually Cloud Identity or Workforce Identity
Federation, whose JWKS URI is `https://www.googleapis.com/oauth2/v3/certs` and
whose issuer is `https://accounts.google.com`. `VJ-VerifyIdToken` is written
against the OIDC standard rather than against Google specifically, so a
third-party IdP already in place works without modification — but Cloud Identity
is the path of least resistance and the one to reach for first.

---

## 4.7 Service accounts and shared identities

Some traffic legitimately does not come from a person: a batch job, a scheduled
summariser, a backend service.

Three workable patterns, in decreasing order of how much you will like them
later.

**Give the workload its own tier.** A `service` tier with a budget sized for the
job. Clean, and the spend is attributable to a thing you can name.

**Pass through the originating user.** If the service acts on behalf of a
person, have it forward that person's token. The spend lands on the person who
caused it, which is usually the right answer for a chat backend.

**One shared identity for a whole class of automation.** Simple and the least
informative: when the shared budget runs out, every job stops, and finding out
which one was responsible means reading the ledger.

What all three have in common is that the workload is still metered. The pattern
to avoid is exempting service traffic from the gateway, because service traffic
is precisely where an unnoticed loop runs all weekend.

---

## 4.8 What the gateway sends upstream

The caller's token is **stripped** before the request reaches the model.
`AM-BuildVertexRequest` removes `Authorization`, `X-Goog-Api-Key` and
`X-Goog-User-Project`, and the target authenticates with the gateway's own
service account.

Three reasons.

The caller's token is for the gateway; forwarding it to a third party is a
credential leak, even to a first-party service.

The caller has no permission to call the model directly — that is the entire
point of the architecture — so the token would not work anyway.

And it makes the trust boundary crisp: exactly one identity reaches the
inference API, and it belongs to the gateway. That is what makes the IAM audit
in [10-security.md](10-security.md) a short and checkable exercise.
