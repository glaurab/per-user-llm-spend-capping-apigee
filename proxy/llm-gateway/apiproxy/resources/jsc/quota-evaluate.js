/*
 * quota-evaluate.js
 * -----------------
 * Reads the three quota counters and makes the allow / deny / degrade decision.
 *
 * WHY THE DECISION IS MADE HERE AND NOT BY THE QUOTA POLICY
 * ---------------------------------------------------------
 * The Quota policies are configured with continueOnError="true", so they never
 * raise a fault themselves. That is deliberate, for three reasons:
 *
 *   1. THE SAME policy object is attached on both the request leg and the
 *      response leg so that both legs share one counter. A fault on the response
 *      leg would be nonsense - the model has already generated, the money is
 *      already spent, and there is nothing left to prevent.
 *
 *   2. Three counters are evaluated together. A built-in fault would abort on
 *      the first violation, so we could never tell the caller WHICH limit they
 *      hit, or report the other two.
 *
 *   3. A hand-built 429 can carry the remaining budget, the limit that was hit
 *      and an accurate reset time. The stock quota fault carries none of that,
 *      and a 429 a user cannot act on is just an outage with a friendly code.
 *
 * DISTINGUISHING "OVER BUDGET" FROM "COUNTER BROKEN"
 * --------------------------------------------------
 * These need opposite responses and look similar from inside the flow. A caller
 * over budget must be refused. A caller whose counter store is unreachable has
 * done nothing wrong, and the configured fail mode decides their fate. We tell
 * them apart by checking whether the policy published a usage figure at all: a
 * policy that ran and refused reports counts; a policy that could not reach its
 * counter reports nothing.
 */

/* global context */

(function () {

  if (context.getVariable('cap.decision.deny') === true) { return; }

  var LIMITS = [
    { policy: 'QU-BudgetUserDaily',   label: 'user_daily',   scope: 'user',  period: 'day' },
    { policy: 'QU-BudgetUserMonthly', label: 'user_monthly', scope: 'user',  period: 'month' },
    { policy: 'QU-BudgetTeamDaily',   label: 'team_daily',   scope: 'team',  period: 'day' }
  ];

  var breached = null;
  var infrastructureFailure = false;
  var report = [];

  for (var i = 0; i < LIMITS.length; i++) {
    var L = LIMITS[i];
    var base = 'ratelimit.' + L.policy + '.';

    var allowed = context.getVariable(base + 'allowed.count');
    var used = context.getVariable(base + 'used.count');
    var available = context.getVariable(base + 'available.count');
    var exceeded = context.getVariable(base + 'exceed.count');

    // A quota that could not consult its counter publishes no usage figure.
    if (used === null || used === undefined || used === '') {
      infrastructureFailure = true;
      report.push({ limit: L.label, status: 'unavailable' });
      continue;
    }

    var usedN = Number(used) || 0;
    var allowedN = Number(allowed) || 0;
    var availableN = Number(available);
    if (!isFinite(availableN)) { availableN = allowedN - usedN; }

    report.push({
      limit: L.label,
      scope: L.scope,
      period: L.period,
      limitMicros: allowedN,
      usedMicros: usedN,
      remainingMicros: availableN > 0 ? availableN : 0
    });

    var didExceed = (Number(exceeded) || 0) > 0 || availableN < 0;
    if (didExceed && !breached) {
      breached = {
        limit: L.label,
        scope: L.scope,
        period: L.period,
        limitMicros: allowedN,
        usedMicros: usedN
      };
    }
  }

  context.setVariable('cap.budget.report', JSON.stringify(report));

  // The tightest remaining headroom across all three counters. This is what the
  // caller actually has left, and what goes into the response header.
  var tightest = null;
  for (var r = 0; r < report.length; r++) {
    if (typeof report[r].remainingMicros === 'number') {
      if (tightest === null || report[r].remainingMicros < tightest) {
        tightest = report[r].remainingMicros;
      }
    }
  }
  context.setVariable('cap.budget.remaining.micros', tightest === null ? 0 : tightest);

  // ---------------------------------------------------------------------------
  // Over budget.
  // ---------------------------------------------------------------------------
  if (breached) {
    if (context.getVariable('cap.config.enforce') === 'false') {
      // Observation mode. Counters run and are reported, but nothing is refused.
      // This is how a deployment should always start: measure real consumption
      // for a period, then set limits against the observed distribution. Limits
      // chosen before there is data are either inert or they break people's work
      // on day one.
      context.setVariable('cap.decision.deny', false);
      context.setVariable('cap.decision.reason', 'OVER_BUDGET_NOT_ENFORCED');
      context.setVariable('cap.decision.breachedLimit', breached.limit);
      return;
    }

    context.setVariable('cap.decision.deny', true);
    context.setVariable('cap.decision.reason', 'BUDGET_EXCEEDED');
    context.setVariable('cap.decision.breachedLimit', breached.limit);
    context.setVariable('cap.decision.breachedScope', breached.scope);
    context.setVariable('cap.decision.breachedPeriod', breached.period);
    context.setVariable('cap.decision.limitMicros', breached.limitMicros);
    context.setVariable('cap.decision.usedMicros', breached.usedMicros);
    // Human-readable forms for the 429 body. A caller who is told "you used
    // 20.0000 of 20.0000" can check the number against their own usage; one who
    // is told "you used 20000000" cannot, and will assume the gateway is wrong.
    context.setVariable('cap.decision.limitDisplay',
      (breached.limitMicros / 1000000).toFixed(4));
    context.setVariable('cap.decision.usedDisplay',
      (breached.usedMicros / 1000000).toFixed(4));
    return;
  }

  // ---------------------------------------------------------------------------
  // Counter store unavailable. Apply the configured fail mode.
  //
  // This is a business decision, not a technical one, which is why it is a
  // configuration value and not a constant in this file. Whoever owns the budget
  // has to choose between "the AI service is down" and "spend is briefly
  // unmetered", and that choice should be written down and signed off, not
  // inherited from a default someone picked while writing a proxy.
  // ---------------------------------------------------------------------------
  if (infrastructureFailure) {
    var mode = context.getVariable('cap.config.failMode') || 'open-degraded';
    context.setVariable('cap.counter.degraded', true);

    if (mode === 'closed') {
      context.setVariable('cap.decision.deny', true);
      context.setVariable('cap.decision.reason', 'COUNTER_UNAVAILABLE');
      return;
    }

    if (mode === 'open-degraded') {
      // Serve, but shrink the blast radius: force the cheapest configured model
      // and a reduced output ceiling. Unmetered spend at the Flash rate with a
      // short ceiling is a very different exposure from unmetered spend at the
      // Pro rate with a long one.
      var config;
      try {
        config = JSON.parse(context.getVariable('cap.raw.runtimeConfig') || '{}');
      } catch (e) { config = {}; }

      var degraded = config.degraded || {};
      if (degraded.model) {
        context.setVariable('cap.model', degraded.model);
        context.setVariable('cap.degraded.modelForced', degraded.model);
      }
      if (degraded.maxOutputTokens) {
        try {
          var body = JSON.parse(context.getVariable('request.content') || '{}');
          if (!body.generationConfig) { body.generationConfig = {}; }
          body.generationConfig.maxOutputTokens = Number(degraded.maxOutputTokens);
          context.setVariable('request.content', JSON.stringify(body));
          context.setVariable('cap.limits.effectiveMaxOutputTokens',
            Number(degraded.maxOutputTokens));
        } catch (e2) { /* leave the body as-is rather than corrupt it */ }
      }
    }

    // mode === "open" falls through untouched.
    context.setVariable('cap.decision.deny', false);
    return;
  }

  context.setVariable('cap.decision.deny', false);
}());
