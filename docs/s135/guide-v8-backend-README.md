# Guide v8 backend (not applied)

| File | What |
|---|---|
| `20261206000000_guide_v8_messages_analytics.sql` | Tables `guide_threads`, `guide_sessions`, `guide_messages`, `guide_auth_attempts`, `guide_events`; guest RPCs `guide_session_v1`, `guide_thread_v1`, `guide_send_v1`, `guide_track_v1`; staff RPCs `staff_guide_threads_v1`, `staff_guide_thread_v1`, `staff_guide_reply_v1`, `staff_guide_resolve_v1`, `staff_guide_usage_v1`; push trigger to `notify-staff-inbox`; `guide_sweep_v1`. Additive, guarded. |
| `rollback_20261206_guide_v8.sql` | Drops all of it. |
| `verify_20261206_guide_v8.sql` | 8 read-only forward checks (`begin transaction read only`). |

Tested 2026-11-24 on local Postgres 16 with stubs for `verify_booking`, `current_staff_authorized`, `calendar_events`, `auth`: migration applies, guest flow (mint, wrong initial, too early, send, duplicate send, empty send, read), analytics batch (bad event skipped, 4 of 5 stored), staff gate refuses without access, staff list/reply/usage, mint throttle after 8 failures, anon cannot read tables, verify 8/8 true, rollback leaves 0 tables, re-apply clean.

## Release path (Lloyd)
1. Copy the migration into `stay-site/supabase/migrations/`, the rollback into `supabase/rollbacks/`, write the release contract JSON like the s13x releases, rehearse on the backup copy with pgTAP.
2. Apply with `apply-release-on-host.sh`, then run `verify_20261206_guide_v8.sql` through `run-sql-on-host.sh` (all `t`).
3. Add `select public.guide_sweep_v1();` to the weekly sweep (or a pg_cron job `guide-sweep-weekly`).
4. Check that `notify-staff-inbox` accepts `{kind:'guest_wrote', psid:'guide:<uuid>'}` from the database caller (cron-secret path). If it only accepts that kind from the service-role caller, add the database path there (waves repo).

Until step 2 the guide works as before: the Messages tab shows the Airbnb / Messenger / call / e-mail options and analytics calls fail silently (queued on the phone, dropped after 200 events).

## Staff app follow-up (separate lane, Cascade-Staff repo)
Conversations/Inbox gains a "Guide" source next to Messenger:
- list: `rpc('staff_guide_threads_v1')` → guest_label, stay dates, channel pill (Airbnb / Direct), unread count, last line.
- thread: `rpc('staff_guide_thread_v1', {p_thread_id})` (marks read), reply box → `rpc('staff_guide_reply_v1', {p_thread_id, p_body, p_client_msg_id})`, Resolve → `staff_guide_resolve_v1`.
- Insights: a "Guest guide" card from `rpc('staff_guide_usage_v1', {p_days: 30})`: devices, verified stays, opens per day, top sections with average seconds, top 10 taps, verify funnel, messages, empty delivery searches.
- Rule for staff: never send a door code or payment details in the guide chat; those stay in Airbnb messages.
