# ADR 0005 — Identity from a signature-verified OIDC token, keyed on `sub`

**Status:** Accepted
**Related:** [0004](0004-period-stamped-identifiers-with-flexi.md), [0006](0006-fail-open-degraded-by-default.md)

---

## Context

A per-user cap is only as good as its notion of "user". Whatever supplies the
identity has to satisfy four requirements:

1. **Unforgeable.** If a caller can choose their own identifier, they can choose a
   fresh one whenever a counter fills up, and the cap is decorative.
2. **Stable.** The identifier is a counter key. If it changes, the budget resets.
3. **Attributable.** It has to map back to a real person for the spend report to
   mean anything.
4. **Carrying tier and team**, because those determine which limits apply and are
   properties of the person, not of the request.

Three options were available: Apigee API keys, platform-managed identity such as
Identity-Aware Proxy, or a generic OIDC bearer token verified by the gateway.

## Decision

**Require an OIDC ID token in `Authorization: Bearer`, verified by
`VJ-VerifyIdToken` against a configurable JWKS URI, with issuer *and* audience
checked.**

The counter key comes from the `sub` claim by default. Tier and team come from
configurable claims, with configured defaults when absent.

```
identity.subjectClaim  = "sub"
identity.tierClaim     = "llm_tier"
identity.teamClaim     = "llm_team"
identity.defaultTier   = "standard"
identity.defaultTeam   = "unassigned"
```

A caller whose token carries no tier or team claim is not refused — they land on
the defaults, and an unrecognised team falls back to `teams._default` in the
budget table. Refusing instead would make the gateway undeployable until every
token in the estate had been reissued.

JWKS URI, issuer and audience are **build-time** values substituted into the
policy, because Apigee reads them at policy-compile time.

## Consequences

**Claims cannot be edited by the caller.** They are inside a signature-verified
token. This is what closes the "just change your tier" bypass, and it is the
reason tier lives in the token rather than in a list inside the proxy.

**Tiering is an identity-provider operation.** Moving someone between tiers is a
group membership change that takes effect on their next token refresh — no
deploy, no configuration change, and reversible the same way. That is a better
place for the decision to live than a file in this repository.

**The audience check is mandatory, not optional.** An issuer check alone accepts
*any* token that provider ever issued, including one minted for an unrelated
application. Anyone holding such a token becomes a user of your gateway with a
budget. `OIDC_AUDIENCE` has no permissive default for this reason, and
`preflight-check.sh` fails if it is empty.

**`sub` rather than `email`, by default.** `sub` is opaque, stable across name
changes, and not personal data in the way an address is. This matters more than
it looks, because the identifier propagates into three stores with different
retention and location properties: quota keys, the BigQuery ledger, and Apigee
analytics — **whose location was fixed permanently when the organisation was
created and cannot be changed afterwards**
([11-regions-and-residency.md](../11-regions-and-residency.md) §11.3). Choosing
`email` is a one-line configuration change and an unrecoverable one if the
implications surface a year later.

The cost is a mapping step: `sub` is not human-readable, so turning a spend report
into names requires a lookup against the identity provider. That is a small,
deliberate friction on a report that names individuals and their spending.

**Build-time settings mean rotation requires a redeploy.** Changing the issuer or
audience also invalidates every token in flight — every client gets 401 until it
re-authenticates. [12-operations-runbook.md](../12-operations-runbook.md) §12.8
covers doing it safely. Key rotation *within* a JWKS URI needs nothing.

**Non-human callers need real identities too.** A service account calling the
gateway presents its own ID token and gets its own budget. Do not let backend
services share one identity: the counter becomes a shared pool with no
attribution, and one misbehaving job exhausts everyone.

**The caller's token must not be forwarded upstream.** `AM-BuildVertexRequest`
replaces it with the gateway's own credential. Passing it through would mean the
model endpoint sees, and might honour, a credential the gateway does not control.

## Alternatives considered

**Apigee API keys, with an API product, developer and app.** The native Apigee
path, and the reason those resources are absent from the Terraform. Rejected
because an API key is a bearer secret with no expiry that is routinely shared
between colleagues — precisely the failure mode a per-user cap must not have —
and because tier and team would then have to be carried as app attributes,
managed in a second place, out of step with the identity provider.

**Identity-Aware Proxy.** Excellent where it fits: IAP terminates authentication
before the gateway and hands over a signed assertion header. Not chosen as the
default because it presumes a particular front-door topology and does not cover
service-to-service callers. It is documented as a supported variant in
[04-identity.md](../04-identity.md) — the change is confined to the extraction
policy; everything downstream is identical.

**Trust a header set by an upstream component.** `X-User-Id`, set by a load
balancer or a client library. Rejected outright: it satisfies requirements 2, 3
and 4 and fails requirement 1, which is the only one that makes the cap a
control. Anyone who can reach the gateway directly can set the header.
