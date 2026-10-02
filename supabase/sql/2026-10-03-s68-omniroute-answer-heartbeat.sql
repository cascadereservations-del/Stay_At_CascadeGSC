-- Session 68 (Lloyd 2026-10-03 "build 1-3"): Cascade OmniRoute (the third guest-reply rung) was dead for 2.5 days and only a log
-- line knew. system-verifier (waves 86cb7e7) now records a heartbeat 'omniroute-answer' each hour the combo really answers;
-- job-heartbeat-monitor sends ONE Finance alert per outage when there has been no answer for 1.5 x 7200 s = 3 h.
-- record_job_heartbeat refuses an unknown job_name, so this row is seeded before the deploy. Re-running changes nothing.
-- Run with stay-site/scripts/migrations/run-sql-on-host.sh (Git Bash, CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe).
begin;

insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('omniroute-answer', 7200, false, now())
on conflict (job_name) do nothing;

select job_name, expected_interval_seconds, ops_risk, last_succeeded_at from public.job_heartbeats where job_name = 'omniroute-answer';

commit;
