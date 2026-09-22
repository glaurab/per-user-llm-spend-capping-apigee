# 1. Concepts: why per-user LLM spend capping has to be built

This document assumes you know nothing about Apigee, the Gemini Enterprise Agent
Platform (formerly Vertex AI), or how language models are priced. It builds the problem up from the beginning and arrives at
the design the rest of this repository implements. Read it before the code.

---

## 1.1 The situation

An organisation gives its staff access to a large language model. Perhaps
through an internal chat application, perhaps as an API that teams build on.
Someone in finance asks a reasonable question:

> What stops one person spending fifty thousand this month?

The honest first answer is: nothing. And the second answer — "we'll set up a
budget alert" — is worse than nothing, because it sounds like a control and
isn't one.

Understanding *why* takes about ten minutes and is the foundation for everything
that follows.

---

## 1.2 How model usage is billed

You are billed per **token**. A token is roughly three-quarters of a word in
English; "unbelievable" might be three tokens, "the" is one. Both what you send
and what you get back are counted.

Two things about this pricing matter enormously and are routinely missed.

**Output costs several times more than input.** A typical ratio is four to
eight times. A short question producing a long answer is dominated entirely by
the output side.

**Models differ by more than an order of magnitude.** A small fast model and a
large capable one might differ by 10–20× per token. The same conversation
costs pennies on one and a meaningful amount of money on the other.

There are also components that are easy to overlook and are billed anyway:

| Component | What it is |
|---|---|
| `promptTokenCount` | everything you sent: the question, the history, the system instruction |
| `candidatesTokenCount` | the generated answer |
| `cachedContentTokenCount` | the part of the prompt served from a context cache, at a discount. **It is a subset of `promptTokenCount`, not an addition to it** |
| `thoughtsTokenCount` | reasoning the model did internally before answering. You never see these tokens. **You are billed for them.** |

That last row is the one that quietly breaks home-made meters. A reasoning model
can spend more tokens thinking than answering. A meter that counts only what the
user sent and what the user received can be wrong by a factor of two, and it
will be wrong in the direction that costs you money.

**Takeaway: a token is not a unit of cost.** Any cap expressed in tokens is a
cap on a quantity whose price varies by more than tenfold depending on choices
the user makes freely. See [03-cost-model.md](03-cost-model.md).

---

## 1.3 Why Google Cloud's own controls do not do this

Three native Google Cloud mechanisms look like they might. Each fails for a different and
instructive reason.

### Budgets and budget alerts

A budget in Cloud Billing watches spend and notifies you when it crosses a
threshold. Two problems.

It is a **notification, not a control**. Nothing stops. By default, crossing
100% of a budget sends an email, and the calls keep flowing.

And the data is **hours late**. Billing data is aggregated on a delay measured
in hours. A runaway script can spend a month's allowance before the first alert
is generated. You will find out. You will find out afterwards.

There is a way to make a budget do something — publish to Pub/Sub and run a
Cloud Function that calls the Cloud Billing API to detach the billing account
from the project. It works, and it is a circuit
breaker of last resort, not a cap: it is hours late, and it takes down the
entire project for everybody, which is a fairly dramatic response to one user
being enthusiastic.

### Agent Platform quotas

Quotas do block, in real time. But look at what they count and at what
granularity: requests per minute, or tokens per minute, **per project, per
region, per model**.

There is no dimension for "user" because at the moment of the API call, there is
no user. Your application calls Agent Platform with its own service account. From
Agent Platform's point of view, one caller is making all the requests.

And quotas count requests and tokens — not money. A quota of "one million tokens
per minute" is a very different amount of money depending on which model those
tokens go to.

### IAM

IAM answers "may this principal perform this action" — may this service account
call `aiplatform.endpoints.predict`, yes or no. It is a yes-or-no question
with no memory. There is no version of an IAM policy that means "yes, until
you've spent twenty pounds, then no". Permissions do not count.

### The pattern

| | granularity | real time? | unit | blocks? |
|---|---|---|---|---|
| Cloud Billing budget alert | project | no, hours late | money | no |
| Budget → Pub/Sub → detach billing | project | hours late | money | yes, catastrophically |
| Agent Platform quotas | project × region × model | yes | requests / tokens | yes |
| IAM | principal | yes | none | yes, permanently |

Nothing has the combination that the question demands: **per person, in real
time, denominated in money.**

That is not an oversight, and it is not a gap Google Cloud is likely to close.
Cloud Billing tracks resource consumption against projects and billing accounts,
and your users are neither. Agent Platform sees one service account. Google Cloud
never learns that Alex exists.

---

## 1.4 The consequence: you need a choke point

If Google Cloud cannot attribute cost to a person, something else must — and it
has to sit on the path between the person and the model, because that is the
only place where both facts are simultaneously available:

- **who is calling** (from their credentials), and
- **what this call costs** (from the request and the response).

A component in that position can keep a running total per person and refuse when
the total is spent. Nothing else can.

```
   ┌──────┐      ┌──────────────────────┐      ┌───────┐
   │ user │─────▶│  choke point         │─────▶│ model │
   └──────┘      │  knows WHO           │      └───────┘
                 │  knows HOW MUCH      │
                 │  keeps a TOTAL       │
                 │  can say NO          │
                 └──────────────────────┘
```

**And it only works if it is the only path.** A choke point you can walk around
is a suggestion. This turns out to be the part most implementations get wrong,
and it is not a coding problem — it is an IAM audit. If any principal your users
can obtain credentials for is able to call the inference API directly, the
gateway is decorative. [10-security.md](10-security.md) is about closing that,
and it deserves as much attention as the metering itself.

---

## 1.5 The hard part: you cannot know the cost in advance

Here is the difficulty at the centre of the whole design.

To decide whether someone can afford a call, you need to know what it costs. The
cost depends mostly on the **output**, because output is priced several times
higher than input. And the output does not exist yet. Its length is determined
by the model, during generation, after you have already decided to allow it.

So the check you want — "compute the cost, compare to the balance, allow or
deny" — is not available. Something has to give.

There are three honest ways to respond, and one dishonest one.

**Refuse to be precise: charge the worst case.** Assume every call produces the
maximum output tokens allowed, charge that up front, and refund the difference
after. Correct, and brutal: a user asking twenty one-word questions is charged
as though they wrote twenty essays, and hits their cap at a fraction of real
spend.

**Charge afterwards, deny the next one.** Let the call through, meter it
accurately, and refuse the *following* call if the balance is now gone. Simple
and accurate, but the last permitted call is unbounded: a user at 0.01 remaining
can make one enormous request, and nothing stops it.

**Split the difference — the approach used here.** Charge the input up front,
where the cost is *exactly* knowable; decide there; then charge the actual
remainder once the response exists.

**And the dishonest one:** pretend the estimate is exact and never reconcile.
This is common and it fails silently. Whatever the estimate systematically gets
wrong becomes free forever, and nobody notices because the counters all look
healthy.

### Why the split works

The input side is fully determined before generation: you have the text. There
is a free `countTokens` API that returns the exact token count for a given
prompt and model. So the request-leg charge is not an estimate at all — it is
exact.

The output side is unknown, so it is charged after the fact:

```
request leg    charge  input_cost                      ← exact, and CAN refuse
                       │
                       ▼
                   [ model generates ]
                       │
                       ▼
response leg   charge  actual_total − already_charged  ← exact, never refuses
```

Two properties fall out of this that are worth naming.

The response-leg charge is **always positive**, because the total always
includes the input already charged. That matters: it means the design never
needs a negative counter adjustment, which is a thing distributed counters are
generally bad at.

And the response leg **never refuses**. It cannot — the answer already exists,
and it cost money whether or not you deliver it. Refusing at that point would
mean paying for a response and then discarding it, which is worse for everyone.

### Bounding the overshoot

So a user *can* end a period over their cap. The last call they made was allowed
on the basis of its input cost, and its output cost was added afterwards. How
far over?

The gateway answers this by refusing to let the client decide. It **overwrites**
`generationConfig.maxOutputTokens` in every request with a configured ceiling.
The client's value is ignored. Which makes the worst case arithmetic:

```
maximum overshoot = output_ceiling × highest_output_price
```

With a 2048-token ceiling and the most expensive model in the table at 12.00 per
million output tokens, that is 0.0246 currency units. Under three cents.

This is the sentence that makes the design defensible to whoever asked the
original question:

> A user cannot exceed their daily allowance by more than the cost of one
> maximum-length response — and here is that number.

`make seed` prints it, computed from your actual configuration, every time you
change the price table or the ceiling.

---

## 1.6 Counting money, not tokens

The gateway's counters hold **micro-units of currency**: integers, one
millionth of a unit each. A cap of 20.00 is stored as 20 000 000.

Integers, because floating-point money accumulated across thousands of
increments drifts, and because the underlying counter primitive is integral
anyway.

Micro-units specifically, because of a small piece of arithmetic that makes the
whole thing cheap. Prices are published *per million tokens*. Store them that
way, and the conversion from tokens to micro-units becomes:

```
cost_micros = tokens × price_per_million
```

No scaling factor, no division, no rounding except one deliberate `ceil` at the
end. 1000 tokens at 0.30 per million is 300 micro-units — which is 0.0003
currency units. Correct, and it took one multiplication.

Prices live in a configuration store, never in code. A hardcoded price is a
silent budget breach the day the vendor changes it.

---

## 1.7 When does a day start?

A daily cap needs a definition of "day", and this is much more interesting than
it sounds.

The obvious implementation resets every counter at midnight UTC. For anyone not
in UTC, that instant falls in the middle of their working day. A user in UTC+9
exhausts their allowance by mid-morning, waits — and at 09:00 local, their
budget refills. They have two allowances per calendar day, and the second one
arrives during the exact hours they are most likely to use it.

A shared reset instant has a second problem: every counter in the system resets
simultaneously, producing a synchronised traffic spike against the model.

This implementation instead **puts the period into the counter's identity**. The
key for a user's daily budget is not `user-123`, it is:

```
u|user-123|standard|D|2026-08-13
```

At local midnight the date changes, so the key changes, so the lookup finds a
counter that has never existed and starts it at zero. There is no reset event.
Nothing is scheduled. Old keys simply stop being referenced and expire.

Daylight saving is handled by the same mechanism, because "what is the local
date right now" is evaluated per request against a timezone definition rather
than computed from a fixed offset. The day the clocks change is 23 or 25 hours
long, and the key changes exactly once during it, at the right moment.

---

## 1.8 Three counters, not one

A single per-user daily cap leaves gaps that people find quickly.

- Daily only: a user can spend their full daily allowance every single day, and
  the monthly total is thirty times larger than anyone budgeted for.
- Per-user only: a hundred users each spending exactly their allowance is a
  hundred times the allowance, and no individual did anything wrong.

So there are three, checked independently, and the most constraining one wins:

| counter | catches |
|---|---|
| user / day | the runaway script, the enthusiastic afternoon |
| user / month | sustained daily-maximum usage |
| team / day | aggregate cost of a group, when no individual is at fault |

Which budget a user gets comes from their **tier** — `standard`, `elevated`,
whatever your organisation needs — carried as a claim in their token or derived
from a group. Never a list of usernames inside the gateway; that list goes stale
the first week and then nobody trusts it.

---

## 1.9 What happens when the gateway itself has a bad day

Distributed counters live in a store. Stores have outages. When the gateway
cannot read the counters, it must decide something, and there is no answer that
is right for everyone:

| mode | behaviour | suits |
|---|---|---|
| `closed` | refuse everything | cost exposure is the dominant risk |
| `open` | serve everything, unmetered | availability is the dominant risk |
| `open-degraded` | serve, but force the cheapest model and a short output ceiling, and alert | most people, most of the time |

`open-degraded` is the default because it bounds the damage rather than choosing
between two absolutes: the service stays up, spend during the outage is capped
by construction rather than by counters, and somebody is told.

**One case is not configurable.** If the gateway cannot read its own
*configuration* — the price table, the budgets, the model allowlist, the output
ceiling — it refuses, always, whatever the fail mode says. Losing the counters
means not knowing how much someone has spent. Losing the configuration means not
knowing what anything costs or how large a single call may be. There is no
bounded way to serve traffic you cannot price.

---

## 1.10 Telling the user

A cap that surprises people generates support tickets and resentment. Three
things make it liveable, and all three are cheap:

**Every response carries the cost.** Headers on each call: what it cost, what
remains, when the period resets. Client applications can display a running
balance without asking for one.

**A free balance endpoint.** `GET /v1/budget` returns remaining budget for each
of the three counters. It costs nothing to call — it reads the counters with a
weight of zero — so an application can poll it to show "you have 1.42 left
today" without that display slowly consuming the thing it displays.

**A refusal that can be acted on.** Not `429 Too Many Requests`, but which limit
was breached, what the limit is, what was used, how many seconds until it
resets, and who to contact for more. A refusal with no route to resolution
becomes a ticket against the platform team; a refusal that names the budget
owner becomes a conversation with the budget owner.

---

## 1.11 Streaming is not a special case, and treating it as one is a bypass

Streaming responses arrive as a sequence of server-sent events rather than one
body. The usage figures come in the final event.

It is tempting to handle this later. Don't: an unmetered streaming endpoint is
a free lane around the entire cap, reachable by adding one query parameter.

Two specifics that are easy to get wrong:

**Do not buffer the stream to meter it.** Waiting for the full response before
forwarding destroys the only reason streaming exists. Events must be inspected
as they pass.

**Charge abandoned streams.** If a client disconnects mid-stream, the model has
already generated — the tokens are billed to you regardless. If the gateway only
charges on clean completion, then "start a request and close the connection" is
a free call, and it is one line of client code. When usage metadata never
arrives, this implementation charges the ceiling: the most it could have been.
Erring high is correct here; the alternative is a bypass.

See [08-streaming.md](08-streaming.md).

---

## 1.12 Where this leaves us

Everything above assembles into one component sitting between users and the
model:

1. **Verify** the caller's identity from a signed token. Not an API key — a
   bearer secret that can be pasted into a colleague's terminal is not an
   identity, and a per-key cap is worth nothing.
2. **Look up** their tier, their team, and the budgets attached to both.
3. **Price** the input exactly, using the free token-counting API.
4. **Charge and decide** against three counters. Refuse here if over.
5. **Constrain** the request — force the output ceiling, refuse models that are
   not allowed.
6. **Forward** to the model with the gateway's own credentials, never the
   caller's.
7. **Reconcile**: charge the difference between the real cost and what was
   already taken.
8. **Report**: cost headers to the caller, a structured record to a durable log.

The remaining documents cover how each of those is built:
[02-architecture.md](02-architecture.md) for the components and the request
lifecycle, [03-cost-model.md](03-cost-model.md) for the arithmetic,
[04-identity.md](04-identity.md) for step 1, and
[05-enforcement-semantics.md](05-enforcement-semantics.md) for the exact
semantics of steps 4 and 7.

---

## 1.13 What this design does not solve

Worth stating plainly, because a control whose limits are undocumented gets
trusted for things it cannot do.

**It does not cap what Google Cloud bills you.** It caps what it *observes*
passing through it, priced with a table you maintain. If the table drifts from
real prices, the meter drifts too. [09-observability.md](09-observability.md)
covers reconciling the ledger against the actual invoice; do it, and treat a
divergence as a bug in the table.

**It does not stop anyone who can reach the model directly.** See
[10-security.md](10-security.md).

**It does not make cost fair, only bounded.** A per-person cap is a blunt
instrument: it treats a support engineer running twenty short queries and a
researcher running one enormous one as equivalent claims on a shared resource.
Tiers help. They do not turn a cap into an allocation policy.

**It adds a hop.** The gateway is one more component between your users and the
model, with its own latency, its own failure modes, and its own operational
burden. The token-counting call in particular is a synchronous round trip on
every request. It can be switched off, at the cost of charging estimates on the
request leg instead of exact figures. That is a real trade and
[07-configuration.md](07-configuration.md) treats it as one.
