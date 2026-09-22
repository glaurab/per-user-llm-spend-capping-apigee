/*
 * stream-capture-usage.js
 * -----------------------
 * Executes inside the EventFlow, once per server-sent event, while the response
 * is still streaming to the client.
 *
 * THE PROBLEM THIS SOLVES
 * -----------------------
 * A streaming generation returns a sequence of `data: {...}` events. Usage
 * metadata is not known until generation finishes, so it appears on the last
 * event (and, on some model versions, is repeated cumulatively on every event).
 * A proxy that buffers the whole stream to read that metadata destroys the only
 * property that makes streaming worth having - time to first token.
 *
 * So we inspect each event as it passes, keep the most recent usageMetadata we
 * have seen, and let the bytes continue to the client untouched. This policy
 * must never modify the event and must never throw: an exception here would
 * break a stream that is already half-delivered to a user.
 *
 * IMPORTANT: EventFlow behaviour is one of the three validation gates for this
 * implementation. Confirm it against your Apigee version before relying on it,
 * and see docs/08-streaming.md for the fallback if it does not hold.
 */

/* global context */

(function () {

  try {
    var raw = context.getVariable('message.content');
    if (!raw) { return; }

    // An SSE frame may carry several lines; only `data:` lines are payload.
    // The terminal sentinel used by some APIs is the literal string "[DONE]".
    var lines = String(raw).split('\n');

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.indexOf('data:') !== 0) { continue; }

      var payload = line.substring(5).replace(/^\s+/, '');
      if (!payload || payload === '[DONE]') { continue; }

      var evt;
      try {
        evt = JSON.parse(payload);
      } catch (e) {
        continue; // partial frame or non-JSON keepalive; ignore
      }

      // Count events for observability. A stream that produced zero events but
      // reported usage, or vice versa, is a signal worth having in the logs.
      var seen = Number(context.getVariable('cap.stream.events')) || 0;
      context.setVariable('cap.stream.events', seen + 1);

      if (evt && evt.usageMetadata) {
        // Overwrite rather than accumulate. Where usage is reported cumulatively
        // the last value is the total; where it is reported once, on the final
        // event, the last value is also the total. Summing would be wrong in the
        // first case and identical in the second, so overwriting is correct in
        // both.
        context.setVariable('cap.stream.usage', JSON.stringify(evt.usageMetadata));
      }

      if (evt && evt.modelVersion) {
        context.setVariable('cap.stream.servedModel', String(evt.modelVersion));
      }
    }
  } catch (outer) {
    // Deliberately swallowed. Losing the meter for one stream is bad; breaking a
    // stream that the user is actively reading is worse. The missing charge is
    // recoverable from the analytics log; a broken response is not.
    context.setVariable('cap.stream.captureError', String(outer));
  }
}());
