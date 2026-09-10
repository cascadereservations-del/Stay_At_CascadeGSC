-- Recovery-only prerequisites omitted from the historical public-schema dump.
-- This file contains only stateless extensions. pg_cron is deliberately absent:
-- its extension-managed rows are production scheduler state, and forward releases
-- detect its absence to skip production-only scheduler wiring in a rehearsal copy.
create extension if not exists vector with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_trgm with schema public;
