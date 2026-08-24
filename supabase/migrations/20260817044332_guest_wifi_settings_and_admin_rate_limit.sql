-- Guest Wi-Fi moves into app_settings so it can be changed in one place
-- instead of four spots in index.html.
--
-- These keys are deliberately readable by anon: the property offers short-term
-- 24h Wi-Fi access to guests who cannot sign in, so the password is operational
-- convenience, not a secret. The existing "anon select public" policy already
-- excludes %token%/%secret%/%pin_hash%/%ical%/%chat_id%/users/email_recipients,
-- and 'wifi_ssid'/'wifi_password' match none of those, so they are readable
-- with no further policy change.

insert into app_settings (key, value)
values ('wifi_ssid', '"WelcomeToCascade-5G"'::jsonb),
       ('wifi_password', '"EnjoyYourStay@CH"'::jsonb)
on conflict (key) do update set value = excluded.value;

-- Rate limiting for the admin PIN check. Without this, moving the check
-- server-side would just relocate a guessable code to a public endpoint.
create table if not exists admin_auth_attempts (
  id          bigint generated always as identity primary key,
  ip_hash     text        not null,
  succeeded   boolean     not null default false,
  attempted_at timestamptz not null default now()
);

create index if not exists admin_auth_attempts_ip_time_idx
  on admin_auth_attempts (ip_hash, attempted_at desc);

alter table admin_auth_attempts enable row level security;

-- No anon/authenticated policy on purpose: only the Edge Function, which uses
-- the service role, may read or write this table.

comment on table admin_auth_attempts is
  'Throttles the guest-guide admin PIN check. Written only by the verify-admin Edge Function (service role). ip_hash is a salted hash, never a raw IP.';;
