-- Masar Oman — 03 give an existing Supabase Auth user the reviewer role.
-- 1) Authentication > Users > Add user > Create new user: enter the reviewer e-mail and a strong password there
--    (tick "Auto Confirm User"). The password stays in Supabase; it is never written in this file or in GitHub.
-- 2) Replace the e-mail below with that reviewer e-mail, then run this in the SQL editor.
insert into public.mo_reviewers (user_id)
select id from auth.users where lower(email) = lower('REVIEWER@EXAMPLE.COM')
on conflict (user_id) do nothing;

-- Check: must return exactly one row with the reviewer e-mail.
select u.email, r.added_at from public.mo_reviewers r join auth.users u on u.id = r.user_id;

-- Remove a reviewer later:
-- delete from public.mo_reviewers where user_id = (select id from auth.users where lower(email) = lower('OLD@EXAMPLE.COM'));
