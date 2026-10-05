-- Compensating rollback for release staff_signin_list_20261005 (session 71, D-303.2).
-- The release added one function and nothing else, so dropping it restores the previous state. The Cascade Staff sign-in screen then
-- cannot fill its name list and falls back to typing a name or e-mail; roll the app back too if you want the old screen.
begin;
drop function if exists public.staff_signin_list_v1();
commit;
