-- Concierge duplicate-webhook guard (session 33, SPEC-06 section 4). Meta retries a webhook it thinks
-- was too slow, and messenger-concierge processes synchronously BEFORE returning 200 - one model call
-- can take 25 s, two with a fallback. Nothing dedupes today: `mid` appears nowhere in index.ts, so a
-- retry is answered a second time and the guest sees the reply twice.
--
-- The fix is one nullable column holding the last message id this thread processed. Additive: existing
-- rows read null and the guard simply does not fire for them.
--
-- ponytail: last id only. If Meta is ever seen replaying out of order, widen it to a small recent-ids
-- array rather than adding a table.
begin;

alter table public.concierge_threads add column if not exists last_mid text;

comment on column public.concierge_threads.last_mid is
  'Meta message id (mid) of the last non-echo message processed for this thread (session 33, SPEC-06). A webhook retry carrying the same mid is ignored. Null means no message has been processed since the column was added.';

commit;
