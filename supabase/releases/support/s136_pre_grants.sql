-- Rehearsal baseline: a --no-acl restore leaves PUBLIC/anon execute on every function (the Postgres default); production has them revoked.
-- Approximation: no PUBLIC or anon execute, authenticated and service_role keep execute. Narrower claims (authenticated only, service_role only) are not modelled.
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
