/*
 * identity-build-keys.js
 * ----------------------
 * Runs once per request, immediately after JWT verification and config load.
 *
 * Responsibilities:
 *   1. Derive a verifiable caller identity from the validated JWT.
 *   2. Resolve the caller's tier and team, and the budgets attached to them.
 *   3. Build the three quota identifiers, each stamped with the caller-local
 *      period so that counters reset on a correct local boundary.
 *   4. Publish the feature switches the rest of the flow branches on.
 *
 * IDENTITY IS NOT AN API KEY
 * --------------------------
 * The quota key is taken from a claim inside a signature-verified JWT. An API
 * key would be worthless here: it is a bearer secret that can be copied between
 * users, so a per-key cap is a per-key cap and nothing more. A signed claim
 * cannot be forged without the identity provider's private key.
 *
 * See docs/04-identity.md.
 */

/* global context, CapTime */
/* include lib-time.js */

(function () {

  // ---------------------------------------------------------------------------
  // Configuration. A failure here is NOT the same as a counter failure.
  //
  // If the counter store is unavailable we can still make a reasoned choice to
  // serve traffic (fail-open-degraded). If the CONFIG is unavailable we do not
  // know the prices, the budgets, the allowed models or the output ceiling - we
  // cannot bound the spend of a single call, let alone a day's worth. That is
  // always fail-closed, regardless of the configured fail mode.
  // ---------------------------------------------------------------------------
  function parseOrNull(raw) {
    if (!raw) { return null; }
    try { return JSON.parse(raw); } catch (e) { return null; }
  }

  var config = parseOrNull(context.getVariable('cap.raw.runtimeConfig'));
  var budgets = parseOrNull(context.getVariable('cap.raw.budgets'));
  var pricing = parseOrNull(context.getVariable('cap.raw.pricing'));

  if (!config || !budgets || !pricing) {
    context.setVariable('cap.config.loaded', false);
    context.setVariable('cap.decision.deny', true);
    context.setVariable('cap.decision.reason', 'CONFIG_UNAVAILABLE');
    context.setVariable('cap.decision.detail',
      'One or more of the runtime-config, budgets or pricing key value maps could ' +
      'not be read or parsed. Refusing to serve traffic that cannot be priced.');
    return;
  }
  context.setVariable('cap.config.loaded', true);

  // ---------------------------------------------------------------------------
  // Feature switches, published as strings because Apigee step conditions
  // compare against string literals.
  // ---------------------------------------------------------------------------
  var features = config.features || {};
  context.setVariable('cap.config.preflightCountTokens',
    features.preflightCountTokens === false ? 'false' : 'true');
  context.setVariable('cap.config.modelArmorEnabled',
    features.modelArmorEnabled === true ? 'true' : 'false');
  context.setVariable('cap.config.enforce',
    features.enforce === false ? 'false' : 'true');
  context.setVariable('cap.config.failMode', config.failMode || 'open-degraded');

  // Agent Platform target shape, consumed by AM-BuildVertexRequest.
  var vertex = config.vertex || {};
  context.setVariable('cap.vertex.host', vertex.endpointHost || '');
  context.setVariable('cap.vertex.project', vertex.projectId || '');
  context.setVariable('cap.vertex.location', vertex.location || '');
  context.setVariable('cap.vertex.publisher', vertex.publisher || 'google');

  // Model Armor target, consumed by the two sanitize callouts when enabled.
  var armor = config.modelArmor || {};
  context.setVariable('cap.armor.project', armor.projectId || vertex.projectId || '');
  context.setVariable('cap.armor.location', armor.location || '');
  context.setVariable('cap.armor.template', armor.templateId || '');
  context.setVariable('cap.armor.maxChars', armor.maxChars || 40000);

  var limits = config.limits || {};
  context.setVariable('cap.limits.maxOutputTokens', limits.maxOutputTokens || 2048);
  context.setVariable('cap.limits.maxPromptChars', limits.maxPromptChars || 200000);
  context.setVariable('cap.config.allowedModels',
    JSON.stringify(config.allowedModels || []));

  // ---------------------------------------------------------------------------
  // Caller identity.
  //
  // Claim names are configurable because identity providers disagree about
  // everything. `sub` is the default subject claim rather than `email`: `sub` is
  // a stable opaque identifier, whereas an email address is personal data that
  // would otherwise be written into quota keys, analytics and logs - and would
  // then inherit every data-residency obligation attached to those stores.
  // See docs/04-identity.md, "Choosing the subject claim".
  // ---------------------------------------------------------------------------
  var idCfg = config.identity || {};
  var claimBase = 'jwt.VJ-VerifyIdToken.decoded.claim.';

  function claim(name, fallback) {
    if (!name) { return fallback; }
    var v = context.getVariable(claimBase + name);
    return (v === null || v === undefined || v === '') ? fallback : String(v);
  }

  var subject = claim(idCfg.subjectClaim || 'sub', null);
  if (!subject) {
    context.setVariable('cap.decision.deny', true);
    context.setVariable('cap.decision.reason', 'IDENTITY_MISSING');
    context.setVariable('cap.decision.detail',
      'The verified token carried no "' + (idCfg.subjectClaim || 'sub') +
      '" claim. There is no identity to meter against.');
    return;
  }

  var team = claim(idCfg.teamClaim, idCfg.defaultTeam || 'unassigned');
  var tier = claim(idCfg.tierClaim, idCfg.defaultTier || 'standard');

  // An unrecognised tier must fall back to the most restrictive one, never to an
  // unmetered default. A typo in an IdP group mapping should cost the caller
  // capability, not cost the organisation money.
  var tiers = budgets.tiers || {};
  if (!tiers[tier]) {
    tier = idCfg.defaultTier || 'standard';
  }
  var tierBudget = tiers[tier] || { userDaily: 0, userMonthly: 0 };

  var teams = budgets.teams || {};
  var teamBudget = teams[team] || teams._default || { daily: 0 };

  context.setVariable('cap.identity.subject', subject);
  context.setVariable('cap.identity.team', team);
  context.setVariable('cap.identity.tier', tier);
  context.setVariable('cap.budget.currency', budgets.currency || 'USD');

  // ---------------------------------------------------------------------------
  // Period buckets, in the caller-local timezone.
  // ---------------------------------------------------------------------------
  var now = new Date(Number(context.getVariable('system.timestamp')) || (new Date()).getTime());
  var tz = config.period || {};
  var periods = CapTime.periods(now, tz);

  context.setVariable('cap.period.day', periods.day);
  context.setVariable('cap.period.month', periods.month);
  context.setVariable('cap.period.strategy', periods.strategy);
  context.setVariable('cap.period.resetSeconds', CapTime.secondsUntilNextDay(now, tz));

  // ---------------------------------------------------------------------------
  // Quota identifiers.
  //
  // The period is part of the key. Combined with quota type="flexi" this gives an
  // exact local-day boundary with no shared reset instant - see lib-time.js.
  //
  // The tier is also part of the key. If an operator moves a user between tiers
  // mid-period the user starts a fresh counter rather than inheriting a counter
  // sized for the old budget, which would otherwise let a downgrade be bypassed
  // by an upgrade-then-downgrade cycle.
  // ---------------------------------------------------------------------------
  context.setVariable('cap.key.user.daily', 'u|' + subject + '|' + tier + '|D|' + periods.day);
  context.setVariable('cap.key.user.monthly', 'u|' + subject + '|' + tier + '|M|' + periods.month);
  context.setVariable('cap.key.team.daily', 't|' + team + '|D|' + periods.day);

  // Budgets, converted from display currency units to integer micro-units.
  function toMicros(units) {
    var n = Number(units);
    if (!isFinite(n) || n < 0) { return 0; }
    return Math.floor(n * 1000000);
  }

  context.setVariable('cap.budget.user.daily.micros', toMicros(tierBudget.userDaily));
  context.setVariable('cap.budget.user.monthly.micros', toMicros(tierBudget.userMonthly));
  context.setVariable('cap.budget.team.daily.micros', toMicros(teamBudget.daily));

  // Default weight. Every quota step reads `cap.weight.micros`; whichever JS
  // policy runs last before a quota step owns its value. Initialising it to zero
  // here means a mis-ordered flow under-charges visibly rather than charging a
  // stale value from an unrelated step.
  context.setVariable('cap.weight.micros', 0);
  context.setVariable('cap.charged.request.micros', 0);
  context.setVariable('cap.decision.deny', false);
}());
