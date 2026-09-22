/*
 * budget-report.js
 * ----------------
 * Builds the JSON body for GET /v1/budget.
 *
 * WHY THIS ENDPOINT EXISTS
 * ------------------------
 * A cap that a user only discovers by being refused is experienced as an outage.
 * A cap a user can see approaching is experienced as a budget. The difference is
 * entirely in whether the client application can display remaining headroom, and
 * that requires an endpoint that reports it without spending anything.
 *
 * The quota policies on this flow are invoked with weight 0, so reading your
 * budget never costs budget - an obvious property that is surprisingly easy to
 * get wrong, and which the smoke test asserts explicitly.
 */

/* global context, CapPricing */
/* include lib-pricing.js */

(function () {

  var LIMITS = [
    { policy: 'QU-BudgetUserDaily',   label: 'user_daily',   scope: 'user',  period: 'day' },
    { policy: 'QU-BudgetUserMonthly', label: 'user_monthly', scope: 'user',  period: 'month' },
    { policy: 'QU-BudgetTeamDaily',   label: 'team_daily',   scope: 'team',  period: 'day' }
  ];

  var currency = context.getVariable('cap.budget.currency') || 'USD';
  var limits = [];
  var tightestRatio = null;

  for (var i = 0; i < LIMITS.length; i++) {
    var L = LIMITS[i];
    var base = 'ratelimit.' + L.policy + '.';

    var allowed = Number(context.getVariable(base + 'allowed.count'));
    var used = Number(context.getVariable(base + 'used.count'));
    var available = Number(context.getVariable(base + 'available.count'));

    if (!isFinite(allowed)) {
      limits.push({ limit: L.label, scope: L.scope, period: L.period, status: 'unavailable' });
      continue;
    }
    if (!isFinite(used)) { used = 0; }
    if (!isFinite(available)) { available = allowed - used; }
    if (available < 0) { available = 0; }

    var ratio = allowed > 0 ? (used / allowed) : 0;
    if (tightestRatio === null || ratio > tightestRatio) { tightestRatio = ratio; }

    limits.push({
      limit: L.label,
      scope: L.scope,
      period: L.period,
      status: 'ok',
      limit_amount: CapPricing.microsToDisplay(allowed),
      used_amount: CapPricing.microsToDisplay(used),
      remaining_amount: CapPricing.microsToDisplay(available),
      used_fraction: Math.round(ratio * 10000) / 10000
    });
  }

  var report = {
    currency: currency,
    tier: context.getVariable('cap.identity.tier'),
    team: context.getVariable('cap.identity.team'),
    period: {
      day: context.getVariable('cap.period.day'),
      month: context.getVariable('cap.period.month'),
      resets_in_seconds: Number(context.getVariable('cap.period.resetSeconds')) || null
    },
    enforcement: context.getVariable('cap.config.enforce') === 'false'
      ? 'observation_only'
      : 'enforcing',
    limits: limits,
    // The single number a UI should render. Derived from whichever limit is
    // closest to exhaustion, since that is the one that will actually refuse.
    headroom_fraction: tightestRatio === null
      ? null
      : Math.round((1 - Math.min(tightestRatio, 1)) * 10000) / 10000
  };

  context.setVariable('cap.budget.reportBody', JSON.stringify(report, null, 2));
}());
