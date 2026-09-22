/*
 * response-reconcile-cost.js
 * --------------------------
 * Runs on the response leg of a unary generation call. Computes the true cost of
 * the call from the model's own usageMetadata and charges the difference between
 * that and what was already charged on the request leg.
 *
 * WHY A DIFFERENCE AND NOT THE FULL AMOUNT
 * ----------------------------------------
 * The request leg already charged the input cost. Charging the full total here
 * would double-charge the input. So:
 *
 *     weight = max(0, actual_total - already_charged)
 *
 * The clamp at zero matters. Apigee quota weights must be non-negative, so we can
 * never refund. That is why the request leg deliberately charges only the input
 * side - the one component that cannot come in lower than estimated when
 * countTokens was used. Any residual over-charge is bounded by the accuracy of
 * the pre-flight count and, in practice, is zero.
 *
 * When countTokens is disabled and the character estimate over-shot the real
 * prompt size, the clamp silently absorbs the difference. The caller keeps the
 * slightly high charge from the request leg. This is the intended bias: the
 * estimator is configured to over-estimate precisely so this direction is the
 * one that happens.
 */

/* global context, CapPricing */
/* include lib-pricing.js */

(function () {

  context.setVariable('cap.weight.micros', 0);

  // Only successful generations are charged for output. An upstream 4xx/5xx
  // produced no candidates and Google does not bill for it, so neither do we -
  // the input charge from the request leg is also arguably too much, but it
  // cannot be refunded and it is bounded and small.
  var status = Number(context.getVariable('response.status.code')) || 0;
  if (status < 200 || status >= 300) {
    context.setVariable('cap.usage.skipped', 'upstream_status_' + status);
    return;
  }

  var raw = context.getVariable('response.content');
  var body;
  try {
    body = JSON.parse(raw || '{}');
  } catch (e) {
    // A response we cannot parse is a response we cannot price. Record it loudly:
    // silent zero-cost calls are how a meter quietly stops meaning anything.
    context.setVariable('cap.usage.parseFailed', true);
    return;
  }

  var usage = body.usageMetadata;
  if (!usage) {
    context.setVariable('cap.usage.missing', true);
    return;
  }

  // Flattened, JSON-escaped candidate text for the optional Model Armor response
  // screening. Same escaping rationale as the prompt side in request-normalize.js.
  try {
    var out = [];
    var cands = body.candidates || [];
    for (var ci = 0; ci < cands.length; ci++) {
      var parts = (cands[ci].content && cands[ci].content.parts) || [];
      for (var pi = 0; pi < parts.length; pi++) {
        if (typeof parts[pi].text === 'string') { out.push(parts[pi].text); }
      }
    }
    var armorMax = Number(context.getVariable('cap.armor.maxChars')) || 40000;
    var flat = out.join('\n');
    if (flat.length > armorMax) { flat = flat.substring(0, armorMax); }
    var esc = JSON.stringify(flat);
    context.setVariable('cap.armor.responseText', esc.substring(1, esc.length - 1));
  } catch (e) { /* screening is optional; never let it break metering */ }

  var pricing;
  try {
    pricing = JSON.parse(context.getVariable('cap.raw.pricing') || '{}');
  } catch (e) { return; }

  // Prefer the model id the API actually served, which can differ from the one
  // requested when an alias or a version pointer was used. We price what ran.
  var model = body.modelVersion || context.getVariable('cap.model');
  var resolved = CapPricing.ratesFor(pricing, model);
  if (!resolved.rates) {
    resolved = CapPricing.ratesFor(pricing, context.getVariable('cap.model'));
  }
  if (!resolved.rates) {
    context.setVariable('cap.usage.unpriced', model);
    return;
  }

  var totalMicros = CapPricing.totalCostMicros(pricing, resolved.rates, usage);
  var alreadyCharged = Number(context.getVariable('cap.charged.request.micros')) || 0;
  var delta = totalMicros - alreadyCharged;
  if (delta < 0) { delta = 0; }

  context.setVariable('cap.weight.micros', delta);
  context.setVariable('cap.cost.total.micros', totalMicros);
  context.setVariable('cap.cost.delta.micros', delta);

  // Published for logging and analytics. Keeping the raw components alongside the
  // money means a future price correction can be replayed over historical data.
  context.setVariable('cap.usage.promptTokens', Number(usage.promptTokenCount) || 0);
  context.setVariable('cap.usage.candidatesTokens', Number(usage.candidatesTokenCount) || 0);
  context.setVariable('cap.usage.cachedTokens', Number(usage.cachedContentTokenCount) || 0);
  context.setVariable('cap.usage.thoughtsTokens', Number(usage.thoughtsTokenCount) || 0);
  context.setVariable('cap.usage.totalTokens', Number(usage.totalTokenCount) || 0);
  context.setVariable('cap.usage.servedModel', model);

  // Remaining budget after this charge, for the response header. Derived rather
  // than re-read: the quota steps that apply `delta` run after this policy, so
  // re-reading the counter here would report a pre-charge figure.
  var remaining = Number(context.getVariable('cap.budget.remaining.micros'));
  if (isFinite(remaining)) {
    var after = remaining - delta;
    if (after < 0) { after = 0; }
    context.setVariable('cap.budget.remainingAfter.micros', after);
    context.setVariable('cap.budget.remainingAfter.display', CapPricing.microsToDisplay(after));
  }
  context.setVariable('cap.cost.display', CapPricing.microsToDisplay(totalMicros));
}());
