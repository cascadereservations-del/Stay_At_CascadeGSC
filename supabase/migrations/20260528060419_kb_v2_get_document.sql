-- Adds full-content retrieval so the KB is self-sufficient in Supabase (no GitHub needed)

-- Fetch one full document by path
create or replace function public.get_kb_document(p_path text)
returns table (
  path text, title text, content text, tags text[],
  applies_to text[], triggers text[], doc_type text, github_url text, updated_at timestamptz
)
language sql stable security invoker set search_path = '' as $$
  select d.path, d.title, d.content, d.tags, d.applies_to, d.triggers, d.doc_type, d.github_url, d.updated_at
  from public.kb_documents d
  where d.path = p_path and d.status = 'active';
$$;

-- Search and return full content inline for the top matches (one-call convenience)
create or replace function public.search_kb_full(
  query_text text,
  max_results int default 3
)
returns table (
  path text, title text, content text, rank real
)
language sql stable security invoker set search_path = '' as $$
  select d.path, d.title, d.content,
         ts_rank(d.fts, websearch_to_tsquery('english', query_text))::real as rank
  from public.kb_documents d
  where d.status = 'active'
    and d.fts @@ websearch_to_tsquery('english', query_text)
  order by rank desc
  limit max_results;
$$;

grant execute on function public.get_kb_document(text)     to authenticated;
grant execute on function public.search_kb_full(text, int) to authenticated;;
