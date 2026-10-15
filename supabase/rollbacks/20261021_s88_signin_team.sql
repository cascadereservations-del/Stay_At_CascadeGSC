-- Compensating rollback for release s88_signin_team_20261021 (session 88).
-- The release added one function and nothing else; dropping it restores the previous state. staff_signin_list_v1 was never touched.
-- Roll the sign-in screen back first, or it loses its name list.
begin;
drop function if exists public.staff_signin_list_v2();
commit;
