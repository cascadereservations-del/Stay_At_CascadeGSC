import { assert } from 'jsr:@std/assert@1';

// s90: the staff app calls this through supabase-js functions.invoke, which sends x-client-info; a missing header drops the POST after the preflight.
Deno.test('ocr-receipt CORS allows every header functions.invoke sends', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  const line = src.split('\n').find((l) => l.includes("'Access-Control-Allow-Headers'")) ?? '';
  for (const h of ['authorization', 'apikey', 'content-type', 'x-client-info']) assert(line.includes(h), h);
});
