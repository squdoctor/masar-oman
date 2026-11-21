-- LOCAL TESTS ONLY — never run this on Supabase. Imitates Supabase roles, auth and storage on a plain PostgreSQL.
-- Minimal local imitation of the Supabase pieces the backend relies on (TEST ONLY, never run on Supabase).
do $$ begin if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if; if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end $$;
create schema auth; create schema storage;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated; grant execute on function auth.uid() to anon, authenticated;
create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id bigserial primary key, bucket_id text references storage.buckets(id), name text not null, owner uuid);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'),1)-1] $$;
grant usage on schema storage to anon, authenticated; grant all on storage.objects to anon, authenticated; grant usage on all sequences in schema storage to anon, authenticated;
grant execute on function storage.foldername(text) to anon, authenticated;
-- Supabase default privileges: anon/authenticated get table privileges in public; RLS decides
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
