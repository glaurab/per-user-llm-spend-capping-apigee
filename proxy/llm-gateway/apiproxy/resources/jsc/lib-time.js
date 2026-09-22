/*
 * lib-time.js
 * -----------
 * Period bucket computation for quota identifiers.
 *
 * WHY THIS EXISTS
 * ---------------
 * Apigee's `calendar` quota type resets every counter at a shared boundary derived
 * from a single UTC StartTime. That boundary bisects local days for any timezone
 * other than UTC, which means users silently get a fresh budget in the middle of
 * their working day. That is not a cap.
 *
 * Instead we bake the caller-local period into the quota IDENTIFIER
 * (".../2026-08-13") and use quota type="flexi", which starts a counter on that
 * identifier's first request and runs for the configured interval. Each identifier
 * therefore lives exactly one local period and expires on its own. Day boundaries
 * are exact in any timezone and daylight saving is handled correctly.
 *
 * See docs/05-enforcement-semantics.md, section "Period boundaries".
 *
 * TIMEZONE RESOLUTION
 * -------------------
 * The Apigee JavaScript runtime (Rhino) does not reliably ship a full ICU dataset,
 * so `Intl.DateTimeFormat` with a timeZone option may or may not be available.
 * We therefore try three strategies in order:
 *
 *   1. Intl.DateTimeFormat with the configured IANA zone   (exact, preferred)
 *   2. A fixed UTC offset plus an explicit DST window table from runtime config
 *   3. UTC
 *
 * Strategy 2 exists so that an operator can get correct behaviour without depending
 * on the runtime's ICU support. The DST table is small and only needs revisiting
 * when a jurisdiction changes its rules.
 */

/* global context */

var CapTime = (function () {

  function pad2(n) {
    return (n < 10 ? '0' : '') + n;
  }

  /**
   * Try the Intl path. Returns a {y,m,d} object or null if Intl is unusable.
   */
  function partsViaIntl(date, ianaZone) {
    try {
      if (typeof Intl === 'undefined' || !Intl.DateTimeFormat) {
        return null;
      }
      var fmt = new Intl.DateTimeFormat('en-CA', {
        timeZone: ianaZone,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit'
      });
      // en-CA yields YYYY-MM-DD, which is exactly what we want.
      var s = fmt.format(date);
      var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
      if (!m) { return null; }
      return { y: m[1], m: m[2], d: m[3] };
    } catch (e) {
      return null;
    }
  }

  /**
   * Fallback: apply a fixed offset, adjusted by an explicit DST window table.
   *
   * dstWindows is an array of { from: "2026-03-27T01:00:00Z",
   *                             to:   "2026-10-30T01:00:00Z",
   *                             offsetMinutes: 180 }
   * Windows are matched in order; the first match wins. Outside every window the
   * baseOffsetMinutes applies.
   */
  function partsViaOffset(date, baseOffsetMinutes, dstWindows) {
    var offset = baseOffsetMinutes;
    if (dstWindows && dstWindows.length) {
      var t = date.getTime();
      for (var i = 0; i < dstWindows.length; i++) {
        var w = dstWindows[i];
        var from = Date.parse(w.from);
        var to = Date.parse(w.to);
        if (!isNaN(from) && !isNaN(to) && t >= from && t < to) {
          offset = w.offsetMinutes;
          break;
        }
      }
    }
    var shifted = new Date(date.getTime() + offset * 60000);
    return {
      y: String(shifted.getUTCFullYear()),
      m: pad2(shifted.getUTCMonth() + 1),
      d: pad2(shifted.getUTCDate())
    };
  }

  return {
    /**
     * @param {Date}   now
     * @param {Object} tzConfig  { zone, offsetMinutes, dstWindows }
     * @returns {{day:string, month:string, strategy:string}}
     *          day   -> "2026-08-13"
     *          month -> "2026-08"
     */
    periods: function (now, tzConfig) {
      var cfg = tzConfig || {};
      var strategy = 'intl';
      var p = cfg.zone ? partsViaIntl(now, cfg.zone) : null;

      if (!p) {
        strategy = (typeof cfg.offsetMinutes === 'number') ? 'offset' : 'utc';
        p = partsViaOffset(
          now,
          (typeof cfg.offsetMinutes === 'number') ? cfg.offsetMinutes : 0,
          cfg.dstWindows
        );
      }

      return {
        day: p.y + '-' + p.m + '-' + p.d,
        month: p.y + '-' + p.m,
        strategy: strategy
      };
    },

    /**
     * Seconds until the next local midnight. Used to populate Retry-After on a 429
     * so the caller knows when their budget resets rather than retrying blindly.
     */
    secondsUntilNextDay: function (now, tzConfig) {
      var today = this.periods(now, tzConfig).day;
      // Walk forward in hourly steps until the local date changes. At most 25
      // iterations, and it is correct across DST transitions precisely because it
      // re-evaluates the local date each step rather than assuming 86400 seconds.
      for (var h = 1; h <= 26; h++) {
        var probe = new Date(now.getTime() + h * 3600000);
        if (this.periods(probe, tzConfig).day !== today) {
          // Refine to the minute.
          var lo = (h - 1) * 3600000;
          var hi = h * 3600000;
          while (hi - lo > 60000) {
            var mid = Math.floor((lo + hi) / 2);
            if (this.periods(new Date(now.getTime() + mid), tzConfig).day !== today) {
              hi = mid;
            } else {
              lo = mid;
            }
          }
          return Math.ceil(hi / 1000);
        }
      }
      return 86400;
    }
  };
}());
