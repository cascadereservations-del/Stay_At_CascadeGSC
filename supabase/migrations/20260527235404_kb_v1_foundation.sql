-- Cascade Knowledge Base — kb_v1_foundation
-- Adds: kb_documents table, pgvector, FTS via trigger, search/browse/upsert RPCs, RLS

-- 1. Enable pgvector
create extension if not exists vector with schema extensions;

-- 2. kb_documents table (fts maintained via trigger, not generated column)
create table if not exists public.kb_documents (
  id            uuid primary key default extensions.uuid_generate_v4(),
  path          text unique not null,
  title         text,
  tags          text[]   default '{}',
  applies_to    text[]   default '{}',
  triggers      text[]   default '{}',
  doc_type      text     default 'markdown',
  content       text     not null,
  summary       text,
  content_hash  text,
  fts           tsvector,
  embedding     extensions.vector(1536),
  github_sha    text,
  github_url    text,
  status        text default 'active',
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

-- 3. FTS trigger function — populates fts on insert/update
create or replace function public.kb_documents_update_fts()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.fts :=
    setweight(to_tsvector('english'::regconfig, coalesce(new.title, '')),                                'A') ||
    setweight(to_tsvector('english'::regconfig, array_to_string(coalesce(new.tags, '{}'),       ' ')),   'B') ||
    setweight(to_tsvector('english'::regconfig, array_to_string(coalesce(new.triggers, '{}'),   ' ')),   'B') ||
    setweight(to_tsvector('english'::regconfig, array_to_string(coalesce(new.applies_to, '{}'), ' ')),   'B') ||
    setweight(to_tsvector('english'::regconfig, coalesce(new.summary, '')),                              'B') ||
    setweight(to_tsvector('english'::regconfig, coalesce(new.content, '')),                              'C');
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists kb_documents_fts_trigger on public.kb_documents;
create trigger kb_documents_fts_trigger
  before insert or update of title, tags, applies_to, triggers, content, summary
  on public.kb_documents
  for each row execute function public.kb_documents_update_fts();

-- 4. Indexes
create index if not exists kb_documents_fts_idx        on public.kb_documents using gin(fts);
create index if not exists kb_documents_tags_idx       on public.kb_documents using gin(tags);
create index if not exists kb_documents_applies_to_idx on public.kb_documents using gin(applies_to);
create index if not exists kb_documents_path_idx       on public.kb_documents(path);
create index if not exists kb_documents_status_idx     on public.kb_documents(status);

-- 5. search_kb function
create or replace function public.search_kb(
  query_text         text,
  max_results        int     default 5,
  filter_tags        text[]  default null,
  filter_applies_to  text[]  default null
)
returns table (
  path text, title text, summary text, tags text[], applies_to text[],
  doc_type text, github_url text, rank real
)
language sql stable security invoker set search_path = '' as $$
  select d.path, d.title, d.summary, d.tags, d.applies_to, d.doc_type, d.github_url,
         ts_rank(d.fts, websearch_to_tsquery('english', query_text))::real as rank
  from public.kb_documents d
  where d.status = 'active'
    and d.fts @@ websearch_to_tsquery('english', query_text)
    and (filter_tags       is null or d.tags       && filter_tags)
    and (filter_applies_to is null or d.applies_to && filter_applies_to)
  order by rank desc
  limit max_results;
$$;

-- 6. browse_kb function
create or replace function public.browse_kb(
  filter_tags        text[]  default null,
  filter_applies_to  text[]  default null,
  max_results        int     default 20
)
returns table (
  path text, title text, summary text, tags text[], applies_to text[],
  doc_type text, github_url text, updated_at timestamptz
)
language sql stable security invoker set search_path = '' as $$
  select d.path, d.title, d.summary, d.tags, d.applies_to, d.doc_type, d.github_url, d.updated_at
  from public.kb_documents d
  where d.status = 'active'
    and (filter_tags       is null or d.tags       && filter_tags)
    and (filter_applies_to is null or d.applies_to && filter_applies_to)
  order by d.updated_at desc
  limit max_results;
$$;

-- 7. upsert_kb_document — sync helper
create or replace function public.upsert_kb_document(
  p_path text, p_title text, p_content text,
  p_tags text[] default '{}', p_applies_to text[] default '{}', p_triggers text[] default '{}',
  p_summary text default null, p_doc_type text default 'markdown',
  p_github_sha text default null, p_github_url text default null
)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid;
  v_hash text := encode(extensions.digest(p_content::bytea, 'sha256'), 'hex');
begin
  insert into public.kb_documents (
    path, title, content, tags, applies_to, triggers,
    summary, doc_type, github_sha, github_url, content_hash
  ) values (
    p_path, p_title, p_content, p_tags, p_applies_to, p_triggers,
    p_summary, p_doc_type, p_github_sha, p_github_url, v_hash
  )
  on conflict (path) do update set
    title=excluded.title, content=excluded.content, tags=excluded.tags,
    applies_to=excluded.applies_to, triggers=excluded.triggers, summary=excluded.summary,
    doc_type=excluded.doc_type, github_sha=excluded.github_sha, github_url=excluded.github_url,
    content_hash=excluded.content_hash, status='active'
  returning id into v_id;
  return v_id;
end;
$$;

-- 8. RLS
alter table public.kb_documents enable row level security;

drop policy if exists "auth read active kb" on public.kb_documents;
create policy "auth read active kb" on public.kb_documents
  for select to authenticated using (status = 'active');

-- 9. Grants
grant select on public.kb_documents to authenticated;
grant execute on function public.search_kb(text, int, text[], text[])    to authenticated;
grant execute on function public.browse_kb(text[], text[], int)          to authenticated;
grant execute on function public.upsert_kb_document(text, text, text, text[], text[], text[], text, text, text, text) to authenticated;;
