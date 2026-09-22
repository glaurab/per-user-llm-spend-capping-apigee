/*
 * stream-finalize.js
 * ------------------
 * Runs after a streaming response has completed (or been abandoned). Turns the
 * usage captured by stream-capture-usage.js into a quota weight.
 *
 * THE DISCONNECT PROBLEM
 * ----------------------
 * If the client closes the connection mid-stream, generation on the model side
 * has usually already happened and is billed. If the gateway only charges when
 * it sees a clean terminal event, then "open a chat, send an expensive prompt,
 * close the tab" becomes a free call - and it is the single easiest bypass of the
 * entire design, discoverable by accident.
 *
 * So an abandoned stream is charged too, using a conservative ceiling: the input
 * cost we already know plus the full forced output ceiling at the output rate.
 * That deliberately over-charges. It has to: the alternative is a bypass, and a
 * caller who repeatedly abandons expensive streams should feel it, not profit
 * from it.
 */

/* global context, CapPricing */
/* include lib-pricing.js */

(function () {

  context.setVariable('cap.weight.micros', 0);

  var pricing;
  try {
    pricing = JSON.parse(context.getVariable('cap.raw.pricing') || '{}');
  } catch (e) { return; }

  var model = context.getVariable('cap.stream.servedModel') ||
              context.getVariable('cap.model');
  var resolved = CapPricing.ratesFor(pricing, model);
  if (!resolved.rates) {
    resolved = CapPricing.ratesFor(pricing, context.getVariable('cap.model'));
  }
  if (!resolved.rates) {
    context.setVariable('cap.usage.unpriced', model);
    return;
  }

  var alreadyCharged = Number(context.getVariable('cap.charged.request.micros')) || 0;
  var totalMicros;
  var basis;

  var usageRaw = context.getVariable('cap.stream.usage');
  var usage = null;
  if (usageRaw) {
    try { usage = JSON.parse(usageRaw); } catch (e) { usage = null; }
  }

  if (usage) {
    totalMicros = CapPricing.totalCostMicros(pricing, resolved.rates, usage);
    basis = 'usageMetadata';

    context.setVariable('cap.usage.promptTokens', Number(usage.promptTokenCount) || 0);
    context.setVariable('cap.usage.candidatesTokens', Number(usage.candidatesTokenCount) || 0);
    context.setVariable('cap.usage.cachedTokens', Number(usage.cachedContentTokenCount) || 0);
    context.setVariable('cap.usage.thoughtsTokens', Number(usage.thoughtsTokenCount) || 0);
    context.setVariable('cap.usage.totalTokens', Number(usage.totalTokenCount) || 0);
  } else {
    // No usage was ever observed. Either the stream was abandoned before the
    // terminal event, or EventFlow did not run. Both are charged at the ceiling.
    var ceiling = Number(context.getVariable('cap.limits.effectiveMaxOutputTokens')) || 0;
    var outRate = Number(resolved.rates.output) || 0;
    totalMicros = alreadyCharged + Math.ceil(ceiling * outRate);
    basis = 'ceiling_fallback';

    context.setVariable('cap.stream.usageMissing', true);
  }

  var delta = totalMicros - alreadyCharged;
  if (delta < 0) { delta = 0; }

  context.setVariable('cap.weight.micros', delta);
  context.setVariable('cap.cost.total.micros', totalMicros);
  context.setVariable('cap.cost.delta.micros', delta);
  context.setVariable('cap.cost.basis', basis);
  context.setVariable('cap.usage.servedModel', model);

  var remaining = Number(context.getVariable('cap.budget.remaining.micros'));
  if (isFinite(remaining)) {
    var after = remaining - delta;
    if (after < 0) { after = 0; }
    context.setVariable('cap.budget.remainingAfter.micros', after);
    context.setVariable('cap.budget.remainingAfter.display', CapPricing.microsToDisplay(after));
  }
  context.setVariable('cap.cost.display', CapPricing.microsToDisplay(totalMicros));
}());
