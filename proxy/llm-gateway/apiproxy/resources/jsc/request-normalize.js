/*
 * request-normalize.js
 * --------------------
 * Validates and rewrites the inbound generation request before anything is
 * charged or forwarded.
 *
 * THE POINT OF THIS POLICY
 * ------------------------
 * A per-user cap is only meaningful if the cost of a SINGLE call is bounded.
 * Without an output ceiling, one request can consume an entire monthly budget
 * before the counter has a chance to react - the overshoot described in
 * docs/05-enforcement-semantics.md would be unbounded and the cap would be
 * unenforceable in the only case that matters.
 *
 * So the gateway overwrites `generationConfig.maxOutputTokens` rather than
 * trusting whatever the client sent. That single line is what turns
 *
 *     "we cap users at 20 units/day"                (unfalsifiable)
 *
 * into
 *
 *     "we cap users at 20 units/day, with a worst-case overshoot of
 *      maxOutputTokens x output_price on the final call"   (a number)
 */

/* global context */

(function () {

  if (context.getVariable('cap.decision.deny') === true) { return; }

  // ---------------------------------------------------------------------------
  // Route parsing. EV-ExtractModel captured the trailing path segment whole, e.g.
  // "gemini-3.7-flash:generateContent", because Apigee URI patterns match on path
  // segments and a colon inside a segment is not a reliable delimiter for them.
  // Splitting here is unambiguous.
  // ---------------------------------------------------------------------------
  var segment = String(context.getVariable('route.modelAndMethod') || '');
  var colon = segment.lastIndexOf(':');
  var model = colon > 0 ? segment.substring(0, colon) : segment;
  var method = colon > 0 ? segment.substring(colon + 1) : '';

  context.setVariable('cap.model', model);
  context.setVariable('cap.method', method);

  // ---------------------------------------------------------------------------
  // Model allowlist.
  //
  // This is enforced at the gateway in addition to (not instead of) the
  // organisation policy constraint. The org policy is the structural guarantee;
  // this check gives the caller a clear 403 with an actionable message instead of
  // an opaque platform error, and lets different environments expose different
  // model sets without touching organisation-level configuration.
  // ---------------------------------------------------------------------------
  var allowed = [];
  try {
    allowed = JSON.parse(context.getVariable('cap.config.allowedModels') || '[]');
  } catch (e) { allowed = []; }

  var isAllowed = false;
  for (var i = 0; i < allowed.length; i++) {
    if (allowed[i] === model) { isAllowed = true; break; }
  }
  context.setVariable('cap.model.allowed', isAllowed);
  if (!isAllowed) {
    context.setVariable('cap.decision.reason', 'MODEL_NOT_ALLOWED');
    return;
  }

  // ---------------------------------------------------------------------------
  // Body parsing.
  // ---------------------------------------------------------------------------
  var raw = context.getVariable('request.content');
  var body;
  try {
    body = JSON.parse(raw || '{}');
  } catch (e) {
    context.setVariable('cap.decision.deny', true);
    context.setVariable('cap.decision.reason', 'MALFORMED_BODY');
    context.setVariable('cap.decision.detail', 'Request body is not valid JSON.');
    return;
  }

  // ---------------------------------------------------------------------------
  // Collect the prompt text. Used for the size guard and, when the pre-flight
  // countTokens call is disabled, for the character-based token estimate.
  //
  // Only text parts are measured. Inline images, audio and video are tokenised by
  // rules that a character count cannot approximate, which is precisely why the
  // pre-flight countTokens call is the default: it is free and it is exact for
  // every modality.
  // ---------------------------------------------------------------------------
  var textLength = 0;
  var nonTextParts = 0;
  var collected = [];

  function walkParts(parts) {
    if (!parts || !parts.length) { return; }
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i];
      if (p && typeof p.text === 'string') {
        textLength += p.text.length;
        collected.push(p.text);
      } else if (p) {
        nonTextParts++;
      }
    }
  }

  if (body.contents && body.contents.length) {
    for (var c = 0; c < body.contents.length; c++) {
      walkParts(body.contents[c].parts);
    }
  }
  if (body.systemInstruction) {
    walkParts(body.systemInstruction.parts);
  }

  context.setVariable('cap.request.textChars', textLength);
  context.setVariable('cap.request.nonTextParts', nonTextParts);

  // Flattened prompt text for the optional Model Armor callout. Truncated,
  // because the screening API has its own size limit and a multi-megabyte prompt
  // would fail the callout rather than screen it. JSON-escaped here so it can be
  // interpolated into the callout's payload template safely - an unescaped quote
  // or newline in a user prompt would otherwise produce malformed JSON, which is
  // both a bug and a trivially reachable injection point.
  var armorMax = Number(context.getVariable('cap.armor.maxChars')) || 40000;
  var flat = collected.join('\n');
  if (flat.length > armorMax) { flat = flat.substring(0, armorMax); }
  var escaped = JSON.stringify(flat);
  context.setVariable('cap.armor.promptText', escaped.substring(1, escaped.length - 1));

  var maxChars = Number(context.getVariable('cap.limits.maxPromptChars')) || 200000;
  if (textLength > maxChars) {
    context.setVariable('cap.request.oversized', true);
    context.setVariable('cap.decision.reason', 'PROMPT_TOO_LARGE');
    context.setVariable('cap.request.maxPromptChars', maxChars);
    return;
  }
  context.setVariable('cap.request.oversized', false);

  // ---------------------------------------------------------------------------
  // Force the output ceiling. This is the load-bearing line of the whole design.
  //
  // We take the minimum of what the client asked for and what policy allows, so a
  // client that legitimately wants a short answer still gets a short answer - we
  // only ever lower the ceiling, never raise it.
  // ---------------------------------------------------------------------------
  var ceiling = Number(context.getVariable('cap.limits.maxOutputTokens')) || 2048;
  if (!body.generationConfig) { body.generationConfig = {}; }

  var requested = Number(body.generationConfig.maxOutputTokens);
  var effective = (isFinite(requested) && requested > 0)
    ? Math.min(requested, ceiling)
    : ceiling;

  body.generationConfig.maxOutputTokens = effective;
  context.setVariable('cap.limits.effectiveMaxOutputTokens', effective);

  // ---------------------------------------------------------------------------
  // Strip fields the gateway must own rather than the caller.
  //
  // `candidateCount` multiplies output cost by N. Allowing a client to set it
  // would let one request cost N times the ceiling we just imposed, defeating the
  // bound above.
  // ---------------------------------------------------------------------------
  if (body.generationConfig.candidateCount &&
      Number(body.generationConfig.candidateCount) > 1) {
    body.generationConfig.candidateCount = 1;
    context.setVariable('cap.request.candidateCountClamped', true);
  }

  context.setVariable('request.content', JSON.stringify(body));

  // ---------------------------------------------------------------------------
  // Payload for the pre-flight countTokens call.
  //
  // countTokens accepts the content-bearing fields only; passing the full
  // generateContent body (with generationConfig, safetySettings and so on) is
  // rejected by some API versions. Building a trimmed copy here keeps the callout
  // simple and means a rejection cannot be caused by a field we control.
  // ---------------------------------------------------------------------------
  var ctPayload = { contents: body.contents || [] };
  if (body.systemInstruction) { ctPayload.systemInstruction = body.systemInstruction; }
  if (body.tools) { ctPayload.tools = body.tools; }
  context.setVariable('cap.countTokens.payload', JSON.stringify(ctPayload));

  context.setVariable('cap.request.normalized', true);
}());
