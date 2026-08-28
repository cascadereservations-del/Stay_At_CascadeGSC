# Recovered Edge Function Source Hashes

**Recovery date:** 2026-08-28

**Method:** Supabase CLI 2.116.0 `functions download <slug> --project-ref qkgfhsdppslwunarczeq --use-api`.

The deployment hash is Supabase's bundle hash from the safe production inventory. The local hash is SHA-256 of the downloaded `index.ts`. These hash different representations and are recorded independently; equality is neither expected nor claimed. No downloaded function was deployed, activated, reformatted or behaviorally changed during recovery.

| Function | Version | JWT | Deployment bundle SHA-256 | Downloaded `index.ts` SHA-256 | Status |
|---|---:|---:|---|---|---|
| `airbnb-email-sync` | 17 | off | `608092595006892b4ae97221692f126e3fd36eb9d846a758f870ed9336d7df05` | `7cad6216f5686b12cccd46855cea3a8684a7b1f0000195133ac9ef0917317d71` | recovered |
| `daily-digest` | 24 | off | `41a62e3685ccc32bccdce8dcb7d96727121f52fdf736e0ba455ff5c9069aa798` | `89cc0b9b2479be9790b938b90a90c0f8bbb46a2dc4c46ead56d3ee2219cda83e` | recovered |
| `last-readings` | 22 | off | `8b11d6acea5f96d9efb44da529d237c170ee0fc3d77f09d5c68db039a6fe106d` | `b799c0246882fa9ef5636c394c0bcbf667f61506ec7a25d202c8fca8d65d5a0e` | recovered |
| `missed-cleaning-alert` | 6 | off | `85fd54db8378f2cc71f7e4b3efefb2555c5d78aade119edd57e00d31d3d9a709` | `f1c8ffa8ea26b3c7a9463d2bdd0832452f729d8560166c7d23fec934302530d1` | recovered |
| `notify-cleaner-payment` | 6 | off | `e704e96bfeb9efd4c528fe9526f6f98b85508402a8d16a6c25d2c6e780001eb6` | `541aa9c49308e093fc246440114bcdb427956a1c0a56276e227237841b8402d9` | recovered |
| `ocr-receipt` | 19 | on | `37ffe8e8d5224684dcd4c77dda6c4ea70f63594633b829de3c2442dcf5337fde` | `c82e9673bff7c45e3036a098bf039539203eb6aff1114be576018d23b8ec023a` | recovered |
| `rain-alert` | 13 | off | `712ed4470d294abc3ddd72a2ef1cea5c15c68973d2c7b80461316087e6b935bc` | `cab8c446fe855a6b3697269b60829ec60adfc6464382967ac54ae6ab2c6fa527` | recovered |
| `submit-cleaning` | 32 | off | `4ee85eac5a0a65314b87c4b08f4170ea09df36dfe9841e4afb94923c7f3b4036` | `242b3d762fe7272d9041894c617588a23b156431637d229f48414c2798bfd1ef` | recovered |
| `telegram-expense` | 61 | off | `ff1c1f7f07bfb2dc04b2b6f726241c23099ec50e833b77d798109dd505cb8eff` | `f40e72823c327b58ecfc9d41630999273e13b0e98c463933c4e8cda392b03717` | recovered |
| `turnover-verifier` | 6 | off | `2b2a8fb984cba044ddaa62a0f427bfd081c3f771abb4418f14193aa89d56ea5b` | `e98f6273231e58f3089088f67c06e8731bed404512549a4eaa6768a74754cf28` | recovered |
| `upload-photo` | 22 | off | `8add6a45694bba6978cd5226113dba97ca10d3fb9e2cebd4d7d3be8f7b589137` | `a3d1e4ccaf7f6830ea56e6eb4cde21d025bcfe723c05b514db94039932d06d18` | recovered |
| `weather-proxy` | 12 | off | `5e677903228803317cbc9d638f91eb5e0cb9645d9854085fb0db063b13ab6b2e` | `e98a745de0b21bd2ed83b529a6f5b29d3dc753c93b4e8e871b63cbe965ff9647` | recovered |

## Verification result

- The production-contract checker reports 12 `recovered`, 9 `versioned`, 0 `missing-source`.
- `turnover-verifier` passes Deno 2.9.5 type-checking when npm auto-install is enabled.
- `telegram-expense` exposes two existing `Uint8Array` overload errors at its Telegram photo-download calls.
- `submit-cleaning` exposes 19 existing type errors after the floating `jsr:@supabase/supabase-js@2` import resolves to 2.112.4. They are concentrated in untyped query rows and generic `ReturnType<typeof createClient>` parameters.
- The failed checks are preserved as evidence of deployed-source/toolchain drift. They are corrected in a separate, test-first compatibility commit so this recovery commit remains an unmodified source capture.
- A later security task evaluates authentication and hard-coded configuration; recovery itself preserves deployed behavior without silently fixing it.

Task 0.2a applies only type-level compatibility annotations. The exact downloaded forms remain reproducible from commit `afab977` and the recorded local hashes above.

After Task 0.2a, Deno 2.9.5 checks pass for `telegram-expense`, `submit-cleaning` and `turnover-verifier`; the latter two use npm auto-install because Supabase's runtime declarations reference npm packages.
