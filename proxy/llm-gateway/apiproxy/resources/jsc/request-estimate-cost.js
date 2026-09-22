/*
 * request-estimate-cost.js
 * ------------------------
 * Computes the input-side cost of the call and publishes it as the quota weight
 * for the request leg.
 *
 * WHY CHARGE ANYTHING BEFORE THE CALL RUNS
 * ----------------------------------------
 * Output tokens cannot be known before generation, so a cap can never be
 * perfectly pre-emptive. But the INPUT side can be known exactly, for free, via
 * the countTokens API. Charging it up front means:
 *
 *   - a caller who is already over budget is refused before any billable
 *     generation happens, not after;
 *   - long-context calls, which are the expensive ones, are metered by the
 *     component that makes them expensive;
 *   - the response leg only ever has to add the remainder, which is always a
 *     non-negative number - so we never need a negative quota weight, which
 *     Apigee does not support.
 *
 * See docs/05-enforcement-semantics.md, "Split-charge enforcement".
 */

/* global context, CapPricing */
/* include lib-pricing.js */

(function () {

  if (context.getVariable('cap.decision.deny') === true) { return; }

  var pricing;
  try {
    pricing = JSON.parse(context.getVariable('cap.raw.pricing') || '{}');
  } catch (e) {
    context.setVariable('cap.decision.deny', true);
    context.setVariable('cap.decision.reason', 'PRICING_UNPARSEABLE');
    return;
  }

  var model = context.getVariable('cap.model');
  var resolved = CapPricing.ratesFor(pricing, model);

  if (!resolved.rates) {
    // unknownModelPolicy = "deny". The model passed the allowlist but has no
    // price entry, which means the allowlist and the price table have drifted
    // apart. Refusing is correct: the alternative is serving traffic we cannot
    // meter, which is exactly the condition this gateway exists to prevent.
    context.setVariable('cap.decision.deny', true);
    context.setVariable('cap.decision.reason', 'MODEL_NOT_PRICED');
    context.setVariable('cap.decision.detail',
      'Model "' + model + '" is allowed but absent from the price table. ' +
      'Allowlist and price table are out of step.');
    return;
  }
  context.setVariable('cap.pricing.knownModel', resolved.known);

  // ---------------------------------------------------------------------------
  // Input token count: exact if the pre-flight countTokens call ran, estimated
  // from character length otherwise.
  // ---------------------------------------------------------------------------
  var promptTokens = 0;
  var cachedTokens = 0;
  var source = 'estimate';

  var ctRaw = context.getVariable('capCountTokensResponse.content');
  if (ctRaw) {
    try {
      var ct = JSON.parse(ctRaw);
      if (ct && typeof ct.totalTokens !== 'undefined') {
        promptTokens = Number(ct.totalTokens) || 0;
        source = 'countTokens';
      }
    } catch (e) {
      // Fall through to the estimate. A countTokens failure must not fail the
      // request - it is an accuracy optimisation, not a control.
      context.setVariable('cap.countTokens.parseFailed', true);
    }
  }

  if (source === 'estimate') {
    var chars = Number(context.getVariable('cap.request.textChars')) || 0;
    promptTokens = CapPricing.estimateTokensFromChars(pricing, chars);

    // Non-text parts are not measurable by character count. Add a configured
    // flat allowance per part so that image-heavy prompts are not treated as
    // free. This is deliberately crude; it is the reason countTokens is the
    // default.
    var nonText = Number(context.getVariable('cap.request.nonTextParts')) || 0;
    var perPart = Number(pricing.estimatedTokensPerNonTextPart) || 260;
    promptTokens += nonText * perPart;
  }

  context.setVariable('cap.tokens.input', promptTokens);
  context.setVariable('cap.tokens.source', source);

  var inputMicros = CapPricing.inputCostMicros(resolved.rates, promptTokens, cachedTokens);

  // This is what the three quota policies on the request leg will charge.
  context.setVariable('cap.weight.micros', inputMicros);
  context.setVariable('cap.charged.request.micros', inputMicros);
}());
