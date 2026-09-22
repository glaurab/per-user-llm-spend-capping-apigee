# 8. Streaming

Metering server-sent events without buffering them, and why an unmetered
streaming endpoint would make the entire cap optional.

---

## 8.1 Why this cannot be deferred

Streaming looks like a nice-to-have. It is not: **an unmetered streaming
endpoint is a free lane around the cap**, and reaching it costs the caller one
query parameter.

```
POST /v1/models/gemini-3.7-flash:streamGenerateContent?alt=sse
```

Same model, same cost to you, same billing upstream. If the gateway meters the
unary path and waves this one through, every cap in the system is advisory and
the workaround fits in a tweet.

So streaming is metered on the same counters, by the same rules, with the same
refusal behaviour on the request leg. Only the reconciliation differs.

---

## 8.2 What a stream looks like

With `?alt=sse`, the response is a sequence of events:

```
data: {"candidates":[{"content":{"parts":[{"text":"The "}]}}]}

data: {"candidates":[{"content":{"parts":[{"text":"capital "}]}}]}

data: {"candidates":[{"content":{"parts":[{"text":"is Paris."}]}}],
       "usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":5,
                        "totalTokenCount":17}}

data: [DONE]
```

Three properties that shape the implementation:

**Usage arrives at the end.** Only the final content event carries
`usageMetadata` — the totals are not known until generation finishes.

**Usage is cumulative, not incremental.** When `usageMetadata` appears on more
than one event, each carries running totals. The last one seen is the answer.
Adding them up multiplies the charge by the number of events.

**The terminal marker is not JSON.** `[DONE]` will fail a parser that assumes
every `data:` line is an object.

---

## 8.3 How the gateway meters it

The request leg is **identical** to the unary path: verify, price the input,
charge, decide, force the output ceiling, refuse if over budget. Nothing about
streaming changes the decision.

The difference is on the way back.

```
  EventFlow  (content-type: text/event-stream)
      JS-CaptureStreamUsage      runs per event, forwards it unchanged,
                                 OVERWRITES cap.stream.usage with whatever
                                 usageMetadata it saw

  Response
      JS-FinalizeStreamCost      price the captured usage
                                 delta = max(0, total − already_charged)
      QU-*                       charge the delta
      DC-CaptureUsage
```

`EventFlow` is the mechanism that makes this possible: it runs a policy per SSE
event as the event passes through, without accumulating the stream. This is
[validation gate 3](13-validation-gates.md) — verify it on your Apigee version.

### Details that matter in `JS-CaptureStreamUsage`

**It overwrites, never accumulates.** Cumulative usage plus accumulation equals
a charge multiplied by the event count.

**It swallows every exception.** An unhandled error inside an EventFlow policy
risks corrupting the stream a user is reading. A metering bug should cost you
accuracy on one call — recovered by the ceiling fallback below — not a broken
response. The failure is visible in the ledger as `stream_usage_missing`.

**It never modifies the event.** Read-only. The bytes forwarded are the bytes
received.

---

## 8.4 The disconnect problem

A client opens a stream, receives a few tokens, and closes the connection.

The model **has already generated**, or is generating, and you are billed for it
either way. If the gateway only charges when it sees a clean `usageMetadata`,
then "start a request and close the connection" is a free call — one line of
client code, and it is the cheapest possible bypass.

So when the stream ends without usage metadata, the gateway charges the
**ceiling**:

```
  total = already_charged + ceil(output_ceiling × output_rate)
```

The most it could have been.

This over-charges an honest user whose network dropped. That is the correct
direction to be wrong. The alternative — under-charging — is not a rounding
error, it is an exploit, and one that gets discovered.

Ceiling-charged calls are marked `basis: "ceiling_fallback"` in the ledger:

```sql
SELECT COUNT(*) AS ceiling_charged,
       COUNTIF(CAST(jsonPayload.outcome.stream_events AS INT64) = 0) AS never_started
FROM   `PROJECT.llm_gateway_spend.llm_gateway_spend`
WHERE  jsonPayload.cost.basis = 'ceiling_fallback'
  AND  DATE(timestamp) >= CURRENT_DATE() - 7
```

A handful is normal — networks drop. A sustained rate is a signal: either a
client that abandons streams by design (fix the client, or it will keep paying
the ceiling), or `EventFlow` is not capturing usage at all, in which case
*every* streaming call is being charged the maximum and your users are wondering
why streaming is so expensive.

---

## 8.5 No response screening on the streaming path

`SC-SanitizeModelResponse` is attached to the unary flow and deliberately not to
the streaming one.

Screening a response requires having the whole response. Buffering the stream to
screen it removes the only reason streaming exists — the first token would
arrive after the last one was generated.

Your options, if screening matters more than latency for some traffic:

- **Screen the prompt only** on streaming paths. That is the default here, and
  it catches the input-side risks.
- **Route sensitive traffic to the unary endpoint** and screen it fully. An
  application-level decision, not a gateway one.
- **Buffer and screen**, accepting that you no longer have streaming.

What you should not do is assume the streaming path is screened because the
unary one is.

---

## 8.6 Timeouts

`targets/vertex.xml` sets a 300-second I/O timeout with request and response
streaming enabled. Long generations legitimately take minutes.

The trade-off is that a hung upstream connection is held for five minutes. With
`SA-SpikeArrest` bounding how many a single caller can open, that is an
acceptable exposure — but if your model responses are reliably fast, lowering it
tightens the failure mode.

Note that a timeout produces no `usageMetadata`, so it takes the ceiling
fallback: an upstream problem charges the user the maximum. If you see ceiling
charges correlated with target timeouts rather than client disconnects, that is
worth fixing at the source rather than absorbing.

---

## 8.7 If `EventFlow` does not work on your version

The fallback, documented in [13-validation-gates.md](13-validation-gates.md):

Charge the ceiling for every streaming call at the point of the request, then
reconcile nightly from the BigQuery ledger against real usage — either by
crediting the following day's budget, or simply by treating streaming as a
conservatively-priced mode and telling users so.

It is worse: users are over-charged all day and the correction lags. But it is
still enforcement, and it is still not a free lane. Never the third option of
leaving streaming unmetered.
