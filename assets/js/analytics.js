(function (global) {
  'use strict';
  var ENDPOINT = 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/track-site-event';
  var SESSION_KEY = 'cascade_booking_session';
  function sessionId() {
    var existing = sessionStorage.getItem(SESSION_KEY);
    if (existing) return existing;
    var value = crypto.randomUUID();
    sessionStorage.setItem(SESSION_KEY, value);
    return value;
  }
  function referrerGroup() {
    if (!document.referrer) return 'direct';
    try {
      var host = new URL(document.referrer).hostname.toLowerCase();
      if (/google|bing|yahoo|duckduckgo/.test(host)) return 'search';
      if (/facebook|instagram|tiktok|youtube|x\.com|twitter/.test(host)) return 'social';
      return 'referral';
    } catch (_) { return 'other'; }
  }
  function track(eventName, properties) {
    var payload = Object.assign({
      session_id: sessionId(), event_name: eventName, occurred_at: new Date().toISOString(),
      page_version: document.documentElement.dataset.version || '2026-08-24',
      viewport_group: innerWidth < 768 ? 'mobile' : innerWidth < 1100 ? 'tablet' : 'desktop',
      referrer_group: referrerGroup()
    }, properties || {});
    var body = JSON.stringify(payload);
    // NOTE: navigator.sendBeacon always sends with credentials mode "include".
    // The edge function answers with `Access-Control-Allow-Origin: *`, which the
    // browser rejects for credentialed requests — and because sendBeacon returns
    // true as soon as the request is *queued*, the fetch fallback below never
    // ran and every event was silently dropped. Use fetch + keepalive, which is
    // uncredentialed by default and survives page unload just as well.
    fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: body,
      keepalive: true,
      credentials: 'omit',
      mode: 'cors'
    }).catch(function () {});
  }
  global.CascadeAnalytics = { track: track };
  track('page_view');
}(window));
