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
  /* Marketing event layer (s137 R3). Nothing here leaves the browser by itself: it fills window.dataLayer and calls gtag / fbq
     only if a vendor script has defined them (none is installed). It never calls track() above and never touches the database.
     Only the keys in ALLOWED can pass, so a name, phone, e-mail, token or booking reference cannot be attached by accident. */
  var UTM_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term', 'gclid', 'fbclid'];
  var ALLOWED = ['nights', 'guests', 'value', 'currency'].concat(UTM_KEYS);
  var UTM_STORE = 'cascade_utm';
  var FB_EVENTS = { view_item: 'ViewContent', begin_checkout: 'InitiateCheckout', add_payment_info: 'AddPaymentInfo', generate_lead: 'Lead' };
  /* first touch of the session: the first visit that carries any campaign parameter is kept; later pages never overwrite it */
  function captureCampaign() {
    try {
      if (sessionStorage.getItem(UTM_STORE)) return;
      var q = new URLSearchParams(global.location.search), found = {};
      UTM_KEYS.forEach(function (k) { var v = q.get(k); if (v) found[k] = String(v).slice(0, 100); });
      if (Object.keys(found).length) sessionStorage.setItem(UTM_STORE, JSON.stringify(found));
    } catch (_) { /* storage blocked: no campaign data, nothing else changes */ }
  }
  function campaign() {
    try { var s = JSON.parse(sessionStorage.getItem(UTM_STORE)); return s && typeof s === 'object' ? s : {}; } catch (_) { return {}; }
  }
  function cascadeTrack(name, params) {
    try {
      var src = Object.assign({}, campaign(), params || {}), p = {};
      ALLOWED.forEach(function (k) {
        var v = src[k];
        if (v == null || v === '') return;
        if (k === 'nights' || k === 'guests' || k === 'value') { v = Number(v); if (!isFinite(v)) return; }
        else v = String(v).slice(0, 100);
        p[k] = v;
      });
      (global.dataLayer = global.dataLayer || []).push(Object.assign({ event: name }, p));
      if (typeof global.gtag === 'function') global.gtag('event', name, p);
      if (typeof global.fbq === 'function') {
        if (FB_EVENTS[name]) global.fbq('track', FB_EVENTS[name], p); else global.fbq('trackCustom', name, p);
      }
    } catch (_) { /* tracking never breaks the page */ }
  }
  captureCampaign();
  global.cascadeTrack = cascadeTrack;

  global.CascadeAnalytics = { track: track };
  track('page_view');
}(window));
