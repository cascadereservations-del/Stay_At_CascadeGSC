import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { effectiveFrom, isRatePost, rateFromImageJson, rateFromPosts, rateFromText, rateImageCandidate } from './rates.ts';

const post = (title: string, body: string, extra = {}) => ({ id: 1, link: 'https://www.socoteco2.com/rate', date_gmt: '2026-11-03T02:00:00', title: { rendered: title }, content: { rendered: body }, ...extra });

Deno.test('common wordings give the total residential rate', () => {
  assertEquals(rateFromText('Residential rate: P 12.3456/kWh'), 12.3456);
  assertEquals(rateFromText('Residential rate ₱12.35 per kWh'), 12.35);
  assertEquals(rateFromText('Generation charge 6.1234 per kWh. Total Rate (Residential): PHP 11.9876'), 11.9876);
  assertEquals(rateFromText('TOTAL RATE ....... 13.01'), 13.01);
  assertEquals(rateFromText('Overall rate for residential: Php 12.5/kWh'), 12.5);
});

Deno.test('a component charge, an implausible figure or no figure is ignored', () => {
  assertEquals(rateFromText('Generation charge 6.1234 per kWh, system loss 0.4'), null);
  assertEquals(rateFromText('Total rate 120.5'), null);
  assertEquals(rateFromText('Total rate 2.1'), null);
  assertEquals(rateFromText('Residential rates are posted at our offices'), null);
  // a single component listed under residential is not the total (s110 review)
  assertEquals(rateFromText('Residential generation charge P 6.12/kWh'), null);
  assertEquals(rateFromText('Residential: Generation charge 6.1200 per kWh; Transmission 1.2 per kWh'), null);
  assertEquals(rateFromText('Residential Customers ₱12.35 per kWh'), null, 'no total wording');
  assertEquals(rateFromText('Residential rate: system loss charge P 0.9/kWh'), null);
  assertEquals(rateFromText('Residential generation rate 6.12. Residential rate P 12.4/kWh'), 12.4);
});

Deno.test('the effective month is the one named, else the month of the post (Manila)', () => {
  assertEquals(effectiveFrom('Rate for the month of November 2026', post('', '')), '2026-11-01');
  assertEquals(effectiveFrom('October, 2026 billing', post('', '')), '2026-10-01');
  assertEquals(effectiveFrom('no month here', post('', '', { date_gmt: '2026-10-31T17:00:00' })), '2026-11-01'); // 01:00 on 1 Nov in Manila
  assertEquals(effectiveFrom('', {}), null);
});

Deno.test('rateFromPosts skips advisories and posts that are not about rates, and takes the newest rate post', () => {
  const advisory = post('NOTICE OF SCHEDULED POWER INTERRUPTIONS ON November 5, 2026', 'Residential rate 99.00');
  const news = post('Plebiscite results', 'Nothing here');
  const old = post('Rate Update for the Month of October 2026', 'Residential rate P 11.1111/kWh');
  const fresh = post('Electricity Rate Update - November 2026', '<p>Total Rate (Residential): P 12.3456 per kWh</p>');
  assertEquals(isRatePost(advisory), false);
  assertEquals(rateFromPosts([advisory, news, fresh, old]), { php_per_kwh: 12.3456, effective_from: '2026-11-01', source_url: 'https://www.socoteco2.com/rate', via: 'text' });
  assertEquals(rateFromPosts([advisory, news]), null);
});

Deno.test('an image-only rate post is the one vision candidate, and its answer is validated', () => {
  const img = 'https://www.socoteco2.com/wp-content/uploads/2026/11/RATE-NOV-2026.jpg';
  const p = post('Rate Update November 2026', `<img src="${img}">`);
  assertEquals(rateImageCandidate([post('Rate Update', 'Total rate 12.5'), p])?.url, img);
  assertEquals(rateImageCandidate([post('Rate Update', 'Total rate 12.5')]), null);
  assertEquals(rateFromImageJson({ residential_total_php_per_kwh: 12.4, month: '2026-11' }, p)?.effective_from, '2026-11-01');
  assertEquals(rateFromImageJson({ residential_total_php_per_kwh: 124, month: '2026-11' }, p), null);
  assertEquals(rateFromImageJson({ residential_total_php_per_kwh: null }, p), null);
});
