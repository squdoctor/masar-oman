-- ============================================================================================================
-- Masar Oman — review backend for Supabase (run once in the SQL editor; safe to re-run).
--
-- What it gives you
--   * mo_applications : registrations from companies, guides, teams, shops and rental offices (PRIVATE)
--   * mo_listings     : what is published after a reviewer approves (PUBLIC read, public fields only)
--   * mo_reports      : visitor reports of wrong information (PRIVATE)
--   * mo_reviewers    : the accounts allowed to review
--   * storage bucket "mo-licences" (PRIVATE): licence documents; visitors can upload, never read or list
--   * the existing caravan submissions (rv_submissions / rv-submissions bucket) become reviewable too
--
-- Security model (Row Level Security everywhere)
--   anon (the public key in the website) can ONLY call mo_apply() and mo_report() and upload a file into a
--   folder named after its own reference. It can read mo_listings rows that are approved and not hidden.
--   It can never read applications, private contacts, licence files, reports or other people's uploads.
--   Reviewers sign in (Supabase Auth, email + password) and must be listed in mo_reviewers.
--   Publishing happens only through mo_approve(), which copies the PUBLIC fields and never the private ones.
-- ============================================================================================================

-- ---------- reviewers ----------
create table if not exists public.mo_reviewers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.mo_reviewers enable row level security;
drop policy if exists "reviewer sees own row" on public.mo_reviewers;
create policy "reviewer sees own row" on public.mo_reviewers for select to authenticated using (user_id = auth.uid());

create or replace function public.mo_is_reviewer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.mo_reviewers where user_id = auth.uid());
$$;
revoke all on function public.mo_is_reviewer() from public;
grant execute on function public.mo_is_reviewer() to authenticated;

-- ---------- applications (private) ----------
create table if not exists public.mo_applications (
  id bigserial primary key,
  ref text not null unique check (ref ~ '^a[a-z0-9]{8,20}$'),
  kind text not null check (kind in ('operator','guide','team','shop','rental')),
  public_data jsonb not null,                    -- may be published after approval
  private_data jsonb not null,                   -- contact person, private phone / e-mail: never published
  licence jsonb not null default '{}'::jsonb,    -- {authority, number, expiry, show_number}
  files text[] not null default '{}',            -- object paths in the private bucket "mo-licences"
  status text not null default 'pending' check (status in ('pending','needs_info','approved','rejected','spam')),
  licence_verified boolean not null default false,
  reviewer_note text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists mo_applications_status_idx on public.mo_applications (status, created_at);
alter table public.mo_applications enable row level security;
drop policy if exists "reviewers read applications" on public.mo_applications;
create policy "reviewers read applications" on public.mo_applications for select to authenticated using (public.mo_is_reviewer());
-- no insert / update / delete policies: anon writes only through mo_apply(), reviewers act through the functions below

-- ---------- published listings (public, approved only) ----------
create table if not exists public.mo_listings (
  id bigserial primary key,
  application_ref text not null unique references public.mo_applications(ref),
  kind text not null check (kind in ('operator','guide','team','shop','rental')),
  public_data jsonb not null,
  licence_status text not null default 'not_checked' check (licence_status in ('verified','not_checked','not_applicable')),
  licence_authority text,
  licence_number text,                            -- only when the applicant allowed it AND a reviewer verified it
  verified_on date,
  hidden boolean not null default false,          -- hide outdated data without deleting it
  published_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists mo_listings_name_uq on public.mo_listings (kind, lower(public_data->>'name_en')) where not hidden;
alter table public.mo_listings enable row level security;
drop policy if exists "public reads visible listings" on public.mo_listings;
create policy "public reads visible listings" on public.mo_listings for select to anon, authenticated using (hidden = false);
drop policy if exists "reviewers read all listings" on public.mo_listings;
create policy "reviewers read all listings" on public.mo_listings for select to authenticated using (public.mo_is_reviewer());

-- ---------- visitor reports (private) ----------
create table if not exists public.mo_reports (
  id bigserial primary key,
  ref text not null unique check (ref ~ '^p[a-z0-9]{8,20}$'),
  page text not null,
  message text not null,
  contact text,
  status text not null default 'new' check (status in ('new','in_review','fixed','dismissed','spam')),
  reviewer_note text,
  handled_by uuid references auth.users(id),
  handled_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.mo_reports enable row level security;
drop policy if exists "reviewers read reports" on public.mo_reports;
create policy "reviewers read reports" on public.mo_reports for select to authenticated using (public.mo_is_reviewer());

-- ---------- public entry points (the only things the public key can do) ----------
create or replace function public.mo_apply(p_ref text, p_kind text, p_public jsonb, p_private jsonb, p_licence jsonb, p_files text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_ref !~ '^a[a-z0-9]{8,20}$' then raise exception 'bad ref'; end if;
  if p_kind not in ('operator','guide','team','shop','rental') then raise exception 'bad kind'; end if;
  if jsonb_typeof(p_public) <> 'object' or jsonb_typeof(p_private) <> 'object' or jsonb_typeof(coalesce(p_licence,'{}'::jsonb)) <> 'object' then raise exception 'bad payload'; end if;
  if coalesce(length(p_public->>'name_ar'),0) < 2 and coalesce(length(p_public->>'name_en'),0) < 2 then raise exception 'name required'; end if;
  if coalesce(p_private->>'consent','') <> 'yes' then raise exception 'consent required'; end if;
  if pg_column_size(p_public) + pg_column_size(p_private) + pg_column_size(coalesce(p_licence,'{}'::jsonb)) > 30000 then raise exception 'too large'; end if;
  if coalesce(array_length(p_files,1),0) > 3 then raise exception 'too many files'; end if;
  if exists (select 1 from unnest(coalesce(p_files,'{}')) f where f !~ ('^' || p_ref || '/[A-Za-z0-9._-]{1,80}$')) then raise exception 'bad file path'; end if;
  if (select count(*) from mo_applications where created_at > now() - interval '1 hour') > 40 then raise exception 'rate limit'; end if;
  insert into mo_applications(ref, kind, public_data, private_data, licence, files)
  values (p_ref, p_kind, p_public, p_private, coalesce(p_licence,'{}'::jsonb), coalesce(p_files,'{}'));
end $$;
revoke all on function public.mo_apply(text,text,jsonb,jsonb,jsonb,text[]) from public;
grant execute on function public.mo_apply(text,text,jsonb,jsonb,jsonb,text[]) to anon, authenticated;

create or replace function public.mo_report(p_ref text, p_page text, p_message text, p_contact text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_ref !~ '^p[a-z0-9]{8,20}$' then raise exception 'bad ref'; end if;
  if coalesce(length(trim(p_message)),0) < 5 or length(p_message) > 3000 then raise exception 'bad message'; end if;
  if length(coalesce(p_page,'')) > 300 or length(coalesce(p_contact,'')) > 200 then raise exception 'too long'; end if;
  if (select count(*) from mo_reports where created_at > now() - interval '1 hour') > 60 then raise exception 'rate limit'; end if;
  insert into mo_reports(ref, page, message, contact) values (p_ref, coalesce(p_page,''), p_message, nullif(trim(coalesce(p_contact,'')),''));
end $$;
revoke all on function public.mo_report(text,text,text,text) from public;
grant execute on function public.mo_report(text,text,text,text) to anon, authenticated;

-- ---------- reviewer actions ----------
create or replace function public.mo_approve(p_ref text, p_licence_verified boolean, p_show_number boolean, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare a mo_applications;
begin
  if not mo_is_reviewer() then raise exception 'not a reviewer'; end if;
  select * into a from mo_applications where ref = p_ref for update;
  if not found then raise exception 'not found'; end if;
  if a.status = 'approved' then raise exception 'already approved'; end if;
  insert into mo_listings(application_ref, kind, public_data, licence_status, licence_authority, licence_number, verified_on)
  values (a.ref, a.kind, a.public_data,
          case when p_licence_verified then 'verified' when a.kind in ('team') then 'not_applicable' else 'not_checked' end,
          case when p_licence_verified then nullif(a.licence->>'authority','') end,
          case when p_licence_verified and p_show_number and coalesce(a.licence->>'show_number','') = 'yes' then nullif(a.licence->>'number','') end,
          case when p_licence_verified then current_date end);
  update mo_applications set status = 'approved', licence_verified = coalesce(p_licence_verified,false), reviewer_note = p_note, reviewed_by = auth.uid(), reviewed_at = now() where ref = p_ref;
end $$;

create or replace function public.mo_set_status(p_ref text, p_status text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not mo_is_reviewer() then raise exception 'not a reviewer'; end if;
  if p_status not in ('needs_info','rejected','spam','pending') then raise exception 'bad status'; end if;
  update mo_applications set status = p_status, reviewer_note = p_note, reviewed_by = auth.uid(), reviewed_at = now() where ref = p_ref and status <> 'approved';
  if not found then raise exception 'not found or already approved'; end if;
end $$;

create or replace function public.mo_set_listing_hidden(p_ref text, p_hidden boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not mo_is_reviewer() then raise exception 'not a reviewer'; end if;
  update mo_listings set hidden = p_hidden, updated_at = now() where application_ref = p_ref;
  if not found then raise exception 'not found'; end if;
end $$;

create or replace function public.mo_handle_report(p_ref text, p_status text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not mo_is_reviewer() then raise exception 'not a reviewer'; end if;
  if p_status not in ('new','in_review','fixed','dismissed','spam') then raise exception 'bad status'; end if;
  update mo_reports set status = p_status, reviewer_note = p_note, handled_by = auth.uid(), handled_at = now() where ref = p_ref;
  if not found then raise exception 'not found'; end if;
end $$;

create or replace function public.rv_set_status(p_ref text, p_status text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not mo_is_reviewer() then raise exception 'not a reviewer'; end if;
  if p_status not in ('pending','approved','rejected','spam') then raise exception 'bad status'; end if;
  update rv_submissions set status = p_status, reviewer_note = p_note, reviewed_at = now() where ref = p_ref;
  if not found then raise exception 'not found'; end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['mo_approve(text,boolean,boolean,text)','mo_set_status(text,text,text)','mo_set_listing_hidden(text,boolean)','mo_handle_report(text,text,text)','rv_set_status(text,text,text)'] loop
    execute 'revoke all on function public.' || f || ' from public';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- ---------- caravan submissions (created by docs/caravan-submissions.sql) become reviewable ----------
create table if not exists public.rv_submissions (
  id bigserial primary key, ref text not null unique, kind text not null check (kind in ('listing','correction')), site_id text,
  data jsonb not null, files text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending','approved','rejected','spam')),
  reviewer_note text, created_at timestamptz not null default now(), reviewed_at timestamptz
);
alter table public.rv_submissions enable row level security;
drop policy if exists "reviewers read rv submissions" on public.rv_submissions;
create policy "reviewers read rv submissions" on public.rv_submissions for select to authenticated using (public.mo_is_reviewer());

-- ---------- storage: private licence bucket ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('mo-licences','mo-licences', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;
drop policy if exists "mo licences upload only" on storage.objects;
create policy "mo licences upload only" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'mo-licences' and (storage.foldername(name))[1] ~ '^a[a-z0-9]{8,20}$');
drop policy if exists "reviewers read licence files" on storage.objects;
create policy "reviewers read licence files" on storage.objects for select to authenticated
  using (bucket_id in ('mo-licences','rv-submissions') and public.mo_is_reviewer());

-- ---------- after running ----------
-- 1) Authentication > Users > Add user (your reviewer e-mail + a strong password).
-- 2) insert into public.mo_reviewers(user_id) select id from auth.users where email = 'REVIEWER@EXAMPLE.COM';
-- 3) Send the Project URL and the anon public key (Settings > API). Never send the service_role key.
