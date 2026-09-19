-- SPEC-15 phase 1: the Drive archive columns on cleaning_sessions. Catalogue-only on purpose: a fixture
-- row needs a property, and CI's baseline database has none (B103), so nothing here assumes a production row.
begin;
select plan(6);

select has_column('public', 'cleaning_sessions', 'session_folder_url', 'session_folder_url exists');
select col_type_is('public', 'cleaning_sessions', 'session_folder_url', 'text', 'session_folder_url is text');
select has_column('public', 'cleaning_sessions', 'drive_files', 'drive_files exists');
select col_type_is('public', 'cleaning_sessions', 'drive_files', 'jsonb', 'drive_files is jsonb');
select col_is_null('public', 'cleaning_sessions', 'drive_files', 'drive_files is nullable (null = unknown)');

select ok((select pg_get_constraintdef(oid) like '%jsonb_typeof(drive_files)%array%' from pg_constraint
            where conrelid = 'public.cleaning_sessions'::regclass
              and conname = 'cleaning_sessions_drive_files_is_array'),
  'drive_files must be a JSON array when set');

select * from finish();
rollback;
