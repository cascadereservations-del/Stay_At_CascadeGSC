-- Session 72 (SPEC-42 9c): remove the three test rows from client_errors so Settings > Health starts clean.
-- Two are labelled "synthetic test, build session 49"; the third is a track-site-event 400 from the agent's own
-- in-app browser in the same session. Keyed by fingerprint, so nothing else can match. Expect "DELETE 3".
begin;
delete from public.client_errors
 where fingerprint in ('163b7727718f2de061c07b998644bed6', 'c74f529668f7a65edcd0afe83f1e0594', '11edd91b8ca98b97303cd4500da3932c');
commit;
