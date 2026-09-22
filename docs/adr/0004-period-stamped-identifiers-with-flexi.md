# ADR 0004 — Period-stamped quota identifiers with `type="flexi"`

**Status:** Accepted
**Related:** [0003](0003-generic-quota-with-computed-weight.md), [0005](0005-identity-from-verified-oidc-token.md)

---

## Context

"Two units a day" needs a definition of *a day*. The obvious answer — let the
quota policy handle it — turns out to be the wrong one for anyone outside UTC.

Apigee's `type="calendar"` resets every counter in the environment at one shared
instant derived from a UTC `StartTime`. Three problems follow.

**The boundary lands mid-day.** For a user several hours from UTC, the reset falls
somewhere inside their working afternoon. They exhaust their budget at 14:00, and
at 15:00 it is inexplicably full again. That is not a daily cap; it is two partial
caps whose sum is unbounded in a way nobody intended.

**Daylight saving breaks it twice a year.** A fixed UTC instant drifts an hour
against local time. Whatever boundary you picked is wrong for half the year.

**Every counter resets at the same instant.** If your callers are in one timezone,
their budgets all refill simultaneously — and a population that has been queuing
against a cap all arrives at once. A synchronised spike against a shared upstream
quota is a self-inflicted outage.

## Decision

**Put the caller-local period into the quota identifier, and use `type="flexi"`.**

```
u|{sub}|{tier}|D|2026-08-13        user, daily
u|{sub}|{tier}|M|2026-08           user, monthly
t|{team}|D|2026-08-13              team, daily
```

`JS-BuildIdentityKeys` computes the local date from the configured IANA zone and
builds these keys. `type="flexi"` starts a counter when its identifier is first
seen and runs it for `Interval`.

`Interval` is a **key lifetime, not a budget period**: 2 days for daily counters,
40 days for monthly. The period itself is expressed entirely by the identifier —
a key stamped `2026-08-13` receives traffic only on that local day, and its
generous lifetime exists so that a counter created just before local midnight
survives to the end of its own day rather than expiring early.

## Consequences

**Day boundaries are exact in any timezone, and DST is a non-issue.** The date
string changes at local midnight because it is computed from local time. There is
no fixed UTC instant to drift.

**Counters expire by themselves.** Yesterday's key stops receiving traffic and its
lifetime runs out. Nothing has to sweep old counters, and nothing has to reset
anything.

**No synchronised refill.** Each user's counter begins on their first request of
the day, so a population spread over a morning starts spread over a morning.

**Per-user timezones are possible without redesign.** The zone is read from
configuration today, but nothing in the mechanism requires it to be global — a
`zoneinfo` claim in the token would slot straight in.

**Tier is part of the key, deliberately.** A tier change starts a fresh counter
for the remainder of the period. This makes "raise someone's tier" an instant,
reversible operational lever ([12-operations-runbook.md](../12-operations-runbook.md)
§12.1). The direction that would be exploitable — downgrading to escape a total —
is not, because a downgrade also starts a fresh counter but at the *lower* limit,
and the higher tier's spend is not restored to them on the way back up. Worth
knowing rather than worth worrying about.

**Timezone handling is now the gateway's problem.** JavaScript in Apigee has no
IANA timezone database. `lib-time.js` therefore implements three strategies in
order of preference: the Apigee runtime's own `Intl` support where available, an
explicit DST-window table from configuration, and a fixed UTC offset as the last
resort. The last of these is wrong for one hour twice a year, and the strategy
actually in use is reported in `cap.period.strategy` — which is why
"[12] §12.10 quarterly: confirm `cap.period.strategy` is not `utc`" is on the
periodic checklist. Silently falling back to UTC is exactly the failure this ADR
exists to prevent.

**Keys are long, and appear in the counter store.** They contain the subject
identifier, which is another reason [0005](0005-identity-from-verified-oidc-token.md)
prefers an opaque `sub` over an email address.

## Alternatives considered

**`type="calendar"` with a UTC start.** Correct only for UTC populations. All
three problems above.

**`type="calendar"` with a start time offset to local midnight.** Fixes the
mid-day boundary for one timezone and still breaks on DST, still synchronises
every reset, and still cannot serve two timezones from one environment.

**`type="rollingwindow"`.** A rolling 24-hour window is arguably a *better* cap —
no boundary to game at all. Rejected because "two units a day, resetting at
midnight" is what people can reason about, and a budget that refills continuously
is very hard to communicate or to display in a client.

**Keep period state externally and reset counters on a schedule.** A scheduled job
that has to run correctly across every timezone, and an outage in which it does
not run means nobody's budget refills. Strictly worse than a key that expires on
its own.
