# Image asset manifest — Task 6 (partial, this session)

This session had **no image-processing tooling** (no sharp/imagemagick
pipeline, no rights-cleared source files beyond what is already hotlinked
from Google Drive in `index.html`). So this pass only:

- Added `<picture>` / `srcset` markup around the hero's no-JS fallback
  image, pointing at the **existing** Google Drive thumbnail URLs at
  `sz=w640` / `sz=w1280` / `sz=w1920` (Drive's own thumbnail resizer —
  not new files).
- Left a broken-image regression test (`tests/responsive.spec.mjs`,
  "conversion-critical images decode successfully") that asserts
  `naturalWidth > 0` for the hero and gallery lead images after they
  scroll into view.

**Not done yet — needs Lloyd + a real image pipeline:**

1. Derive same-origin AVIF (primary) and WebP (fallback) files at 640 /
   1280 / 1920px for every conversion-critical image below, and commit
   them under `assets/images/`. Google Drive thumbnail URLs are a
   reasonable temporary CDN but are not same-origin, not AVIF/WebP, and
   are not guaranteed stable long-term.
2. Once derivatives exist, replace every remaining hotlinked
   `drive.google.com/thumbnail?id=...` `<img>` in `index.html` — the
   dynamically-built hero slideshow (JS-generated, not just the no-JS
   fallback), the gallery mosaic (32 photos), the amenities/about
   proof photo, and the GCash/UnionBank QR images — with the same
   `<picture>` pattern already used for the hero fallback.
3. Re-run `npm run test:e2e -- --grep "images"` and confirm LCP ≤2.5s
   at p75 with the new same-origin assets (Task 4 performance target).

## Drive image IDs currently in use (source → intended local filename)

| Drive file ID | Section | Suggested local filename |
|---|---|---|
| `1wzkooPfoOsa2GzWcixHuZ6xYBf54munt` | Hero (LCP) | `hero-{640,1280,1920}.{avif,webp}` |
| `1kIwtCJt7EUyNhkm_n3yuboZUcWhrl-ED` | About / proof photo | `about-proof-{640,1280}.{avif,webp}` |
| `1iZwQzGq8_yYhihgg2et13eUhre5q4143` | Gallery mosaic (lead) | `gallery-01-{640,1280}.{avif,webp}` |
| `1jIsHRgph5HjgACl3tM2u0E8ybzYx974s` | Gallery mosaic | `gallery-02-{640,1280}.{avif,webp}` |
| `12_MSXiPDg2g5iv0xzvuoYSdIaWIHrSuR` | Gallery mosaic | `gallery-03-{640,1280}.{avif,webp}` |
| `1b66VVq8egMtHQGdMkopN2TN5KN8tauW_` | Gallery mosaic | `gallery-04-{640,1280}.{avif,webp}` |
| `1vCN3fAoAxr-7RLIbFvdHag__DktOQXMY` | Gallery mosaic | `gallery-05-{640,1280}.{avif,webp}` |
| `1qIKNaRvmEbcRHXZ6d4ppLkAOmDDGPquZ` … (32 total) | Full gallery carousel | `gallery-06..32-{640,1280}.{avif,webp}` |
| `1J2t6G-3iRIY1_HiSY_tRlh3huNHl4n6v` | GCash QR | `qr-gcash.{avif,webp,png}` (keep PNG fallback — QR codes should stay lossless) |
| `1XxnM2Pt9xnLRYlhufn2lCjpj2Q0mN3fs` | UnionBank QR | `qr-unionbank.{avif,webp,png}` |

Run `rg -n "drive.google.com/thumbnail?id=" ../../index.html` for the
complete, current list before starting derivation — new photos may have
been added to the gallery carousel since this manifest was written.
