/*
 * lib-pricing.js
 * --------------
 * Converts model token usage into cost, expressed in integer micro-units of the
 * billing currency (1 unit = 1,000,000 micro-units).
 *
 * WHY MICRO-UNITS
 * ---------------
 * Apigee quota counters are integers. Money is not. Storing cost as micro-units
 * gives six decimal places of precision with pure integer arithmetic, which
 * removes any floating-point drift from the counter itself.
 *
 * THE ARITHMETIC SHORTCUT
 * -----------------------
 * Prices are stored as "currency units per 1,000,000 tokens" - the same unit
 * every model vendor publishes. That choice makes the conversion a bare
 * multiplication with no scaling factor at all:
 *
 *     cost_in_units  = tokens / 1e6 * price_per_million
 *     cost_in_micros = cost_in_units * 1e6
 *                    = tokens * price_per_million
 *
 * So a price of 0.30 per million and 1,234 tokens is 1234 * 0.30 = 370 micros.
 * See docs/03-cost-model.md.
 *
 * WHY A PRICE TABLE AND NOT CONSTANTS
 * -----------------------------------
 * Published prices change. A price hardcoded in a proxy bundle that is now wrong
 * does not throw an error - it silently under- or over-charges every user until
 * someone notices in the monthly invoice. The table lives in a Key Value Map so
 * it can be corrected without a proxy redeployment.
 */

/* global context */

var CapPricing = (function () {

  /**
   * Round up. We never round a charge down: a systematic downward bias across
   * millions of calls is a real budget leak, and over-charging by at most one
   * micro-unit per call is not material.
   */
  function ceilInt(n) {
    if (!isFinite(n) || n <= 0) { return 0; }
    return Math.ceil(n);
  }

  function num(v) {
    var n = Number(v);
    return isFinite(n) && n > 0 ? n : 0;
  }

  return {

    /**
     * Resolve the price entry for a model id, applying the configured policy for
     * unknown models.
     *
     * @returns {{rates:Object, known:boolean}} rates has input/output/cachedInput/thinking
     */
    ratesFor: function (pricing, modelId) {
      var models = (pricing && pricing.models) || {};
      if (models[modelId]) {
        return { rates: models[modelId], known: true };
      }

      // An unrecognised model must never be free. Two defensible behaviours:
      //   "deny"          - refuse the call (default; safest, and forces the
      //                     operator to keep the table in step with the allowlist)
      //   "mostExpensive" - charge at the highest rate in the table
      var policy = (pricing && pricing.unknownModelPolicy) || 'deny';
      if (policy === 'mostExpensive') {
        var worst = { input: 0, output: 0, cachedInput: 0, thinking: 0 };
        for (var k in models) {
          if (!models.hasOwnProperty(k)) { continue; }
          var m = models[k];
          worst.input = Math.max(worst.input, num(m.input));
          worst.output = Math.max(worst.output, num(m.output));
          worst.cachedInput = Math.max(worst.cachedInput, num(m.cachedInput));
          worst.thinking = Math.max(worst.thinking, num(m.thinking));
        }
        return { rates: worst, known: false };
      }

      return { rates: null, known: false };
    },

    /**
     * Cost of the input side alone. Charged on the request leg, where it is the
     * only component that can be known before generation.
     *
     * @param {number} promptTokens  exact (from countTokens) or estimated
     * @param {number} cachedTokens  portion served from context cache, if known
     */
    inputCostMicros: function (rates, promptTokens, cachedTokens) {
      if (!rates) { return 0; }
      var cached = Math.min(num(cachedTokens), num(promptTokens));
      var billable = num(promptTokens) - cached;
      return ceilInt(
        billable * num(rates.input) +
        cached * num(rates.cachedInput)
      );
    },

    /**
     * Full cost of a completed call, from the model's own usageMetadata.
     *
     * The four components are priced separately because they genuinely differ:
     *
     *   promptTokenCount        - input, full rate
     *   cachedContentTokenCount - the discounted subset of the input; it is
     *                             reported IN ADDITION to being counted inside
     *                             promptTokenCount, so it must be subtracted out
     *                             before applying the full input rate
     *   candidatesTokenCount    - output, typically 3-5x the input rate
     *   thoughtsTokenCount      - reasoning tokens. Billable, and the component
     *                             most often omitted from home-made meters. On
     *                             most models these are NOT included in
     *                             candidatesTokenCount, but that has varied, so
     *                             it is a configuration flag rather than an
     *                             assumption. Getting it wrong double-charges or
     *                             under-charges every reasoning call.
     */
    totalCostMicros: function (pricing, rates, usage) {
      if (!rates || !usage) { return 0; }

      var prompt = num(usage.promptTokenCount);
      var cached = Math.min(num(usage.cachedContentTokenCount), prompt);
      var candidates = num(usage.candidatesTokenCount);
      var thoughts = num(usage.thoughtsTokenCount);

      var thoughtsInsideCandidates =
        !!(pricing && pricing.thoughtsIncludedInCandidates);

      if (thoughtsInsideCandidates) {
        candidates = Math.max(0, candidates - thoughts);
      }

      var billableInput = prompt - cached;

      return ceilInt(
        billableInput * num(rates.input) +
        cached * num(rates.cachedInput) +
        candidates * num(rates.output) +
        thoughts * num(rates.thinking !== undefined ? rates.thinking : rates.output)
      );
    },

    /**
     * Cheap character-based input estimate, used only when the pre-flight
     * countTokens call is disabled. Deliberately conservative: it is better to
     * over-reserve on the request leg (the reconciliation on the response leg
     * cannot refund) than to under-reserve and let a caller slip past the cap.
     *
     * The ratio is configurable because it is language-dependent - scripts with
     * few Latin characters tokenize very differently.
     */
    estimateTokensFromChars: function (pricing, chars) {
      var perToken = (pricing && pricing.estimatedCharsPerToken) || 4;
      var safety = (pricing && pricing.estimateSafetyFactor) || 1.15;
      var n = Number(chars);
      if (!isFinite(n) || n <= 0) { return 0; }
      return Math.ceil((n / perToken) * safety);
    },

    /**
     * Format micro-units back to a human-readable currency amount, for headers,
     * error bodies and logs. Six decimals is more precision than anyone wants to
     * read, so trim to a sensible display scale.
     */
    microsToDisplay: function (micros) {
      var n = Number(micros) || 0;
      return (n / 1000000).toFixed(4);
    }
  };
}());
