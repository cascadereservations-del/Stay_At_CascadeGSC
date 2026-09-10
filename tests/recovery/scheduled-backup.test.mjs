import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../../", import.meta.url);

async function source(path) {
  return readFile(new URL(path, root), "utf8");
}

test("backup records the snapshot ledger count before COMPLETE", async () => {
  const text = await source("scripts/recovery/p5/supabase-backup-over-alfred.sh");
  assert.match(text, /EXPECTED_LEDGER_ROWS/);
  assert.match(text, /ledger_count.*\^\[0-9\]\+\$/s);
  assert.ok(text.indexOf("EXPECTED_LEDGER_ROWS") < text.indexOf('> "$set_dir/COMPLETE"'));
});

test("restore can use the ledger count stored with the backup", async () => {
  const text = await source("scripts/recovery/p5/supabase-restore-check-on-alfred.sh");
  assert.match(text, /EXPECTED_LEDGER_ROWS/);
  assert.match(text, /expected migration ledger count is required/);
});

test("scheduled runner calls Git Bash and keeps secret values out of source", async () => {
  const text = await source("scripts/recovery/p5/Invoke-CascadeRecoverySchedule.ps1");
  assert.match(text, /Git\\bin\\bash\.exe/);
  assert.match(text, /CASCADE_SUPABASE_URL_FILE/);
  assert.match(text, /CASCADE_SUPABASE_PASSPHRASE_FILE/);
  assert.match(text, /EXPECTED_LEDGER_ROWS/);
  assert.doesNotMatch(text, /postgres(?:ql)?:\/\/[^\s'\"]+:[^\s'\"]+@/i);
});

test("installer registers weekly backup and first-Sunday monthly restore", async () => {
  const text = await source("scripts/recovery/p5/Install-CascadeRecoverySchedule.ps1");
  assert.match(text, /Cascade Supabase Weekly Backup/);
  assert.match(text, /Cascade Supabase Monthly Restore Drill/);
  assert.match(text, /DaysOfWeek Sunday/);
  assert.match(text, /-At '08:00'/);
  assert.match(text, /-At '09:00'/);
  assert.match(text, /-MonthlyGate/);
  assert.match(text, /StartWhenAvailable/);
  assert.match(text, /LogonType Interactive/);
});
