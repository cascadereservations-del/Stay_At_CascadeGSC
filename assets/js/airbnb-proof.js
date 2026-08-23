/* ============================================================
   Cascade Hideaway — Airbnb proof integration (Task 5A)

   Rules this file must never break:
   - Never fetch, scrape, or parse airbnb.com from the browser.
   - Never synthesize an iframe src pointing at airbnb.com.
   - The official embed HTML is host-supplied and pasted into the
     #airbnbProofSlot container by Lloyd (see the TODO comment in
     index.html). Until that happens, this script only manages the
     loading state and the dated, non-live fallback badge that is
     already present in the markup.
============================================================ */
(function () {
  'use strict';

  var container = document.getElementById('airbnbProofEmbed');
  var loading   = document.getElementById('airbnbProofLoading');
  var slot      = document.getElementById('airbnbProofSlot');
  var fallback  = document.getElementById('airbnbProofFallback');
  var hint      = document.getElementById('airbnbProofHint');

  if (!container || !slot || !fallback) return;

  function hasOfficialEmbed() {
    // The official embed is considered "present" only once Lloyd has replaced
    // the placeholder comment with real host-supplied markup (an <iframe> or
    // <script> element Airbnb generated, never one this file constructs).
    return slot.children.length > 0;
  }

  function showLoaded() {
    container.dataset.state = 'loaded';
    if (loading) loading.hidden = true;
    fallback.hidden = true;
  }

  function showFallback(reason) {
    container.dataset.state = 'fallback';
    if (loading) loading.hidden = true;
    fallback.hidden = false;
    if (hint) hint.textContent = 'See all current reviews on Airbnb';
    if (reason && window.console) {
      console.info('[airbnb-proof] using dated fallback badge:', reason);
    }
  }

  function init() {
    if (hasOfficialEmbed()) {
      if (loading) loading.hidden = false;
      // Give the host-supplied embed a moment to paint; if it errors or never
      // renders, keep the dated fallback visible instead of a blank panel.
      var settleTimer = setTimeout(function () {
        showFallback('embed did not report ready in time');
      }, 4000);

      slot.addEventListener('load', function () {
        clearTimeout(settleTimer);
        showLoaded();
      }, { once: true, capture: true });

      slot.addEventListener('error', function () {
        clearTimeout(settleTimer);
        showFallback('embed reported an error');
      }, { once: true, capture: true });
    } else {
      // No official embed configured yet — show the dated fallback badge only.
      showFallback('no official embed configured');
    }
  }

  function lazyInit() {
    if (!('IntersectionObserver' in window)) {
      init();
      return;
    }
    var observer = new IntersectionObserver(function (entries) {
      if (entries[0].isIntersecting) {
        observer.disconnect();
        init();
      }
    }, { rootMargin: '200px 0px' });
    observer.observe(container);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', lazyInit);
  } else {
    lazyInit();
  }
}());
