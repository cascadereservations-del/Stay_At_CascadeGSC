-- Recovery-only prerequisites omitted from the historical public-schema dump.
-- This file contains extensions only; it creates no users, data, credentials or schedules.
create extension if not exists vector with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_trgm with schema public;
