-- Masar Oman — caravan site submissions (private until reviewed). Run once in the Supabase SQL editor.
-- Visitors (anon key) can only INSERT through rv_submit(); they can never read, list or change submissions.
create table if not exists public.rv_submissions (
  id bigserial primary key,
  ref text not null unique,
  kind text not null check (kind in ('listing','correction')),
  site_id text,
  data jsonb not null,
  files text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending','approved','rejected','spam')),
  reviewer_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
alter table public.rv_submissions enable row level security;
-- no policies for anon/authenticated => no direct table access at all

create or replace function public.rv_submit(p_kind text, p_site text, p_data jsonb, p_files text[], p_ref text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('listing','correction') then raise exception 'bad kind'; end if;
  if p_ref !~ '^r[a-z0-9]{8,20}$' then raise exception 'bad ref'; end if;
  if pg_column_size(p_data) > 20000 or coalesce(array_length(p_files,1),0) > 4 then raise exception 'too large'; end if;
  if (select count(*) from rv_submissions where created_at > now() - interval '1 hour') > 30 then raise exception 'rate limit'; end if;
  insert into rv_submissions(ref,kind,site_id,data,files) values (p_ref,p_kind,nullif(p_site,''),p_data,coalesce(p_files,'{}'));
end $$;
revoke all on function public.rv_submit(text,text,jsonb,text[],text) from public;
grant execute on function public.rv_submit(text,text,jsonb,text[],text) to anon;

-- private bucket for photos and proof documents: anon may upload (insert) only, never read or list
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rv-submissions','rv-submissions', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;
create policy "rv upload only" on storage.objects for insert to anon
  with check (bucket_id = 'rv-submissions' and (storage.foldername(name))[1] ~ '^r[a-z0-9]{8,20}$');

-- Moderation (in the Supabase dashboard, as the project owner):
--   select ref, kind, site_id, data, files, created_at from rv_submissions where status='pending' order by created_at;
--   update rv_submissions set status='approved', reviewed_at=now(), reviewer_note='checked CR + called operator' where ref='...';
-- Approved entries are added by hand to /home/claude/caravan/rv.json (with sources), rebuilt, tested and published.
