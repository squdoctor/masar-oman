-- LOCAL TESTS ONLY — run after tests/supabase-shim.sql, 01 and 02 on a throw-away PostgreSQL database.
-- RLS behaviour tests. Each block prints PASS/FAIL through RAISE NOTICE.
\set ON_ERROR_STOP 0
insert into auth.users values ('11111111-1111-1111-1111-111111111111','reviewer@test'),('22222222-2222-2222-2222-222222222222','someone@test');
insert into public.mo_reviewers(user_id) values ('11111111-1111-1111-1111-111111111111');

create or replace function pg_temp.t(name text, ok boolean) returns void language plpgsql as $$ begin raise notice '% %', case when ok then 'PASS' else 'FAIL' end, name; end $$;

-- ===== anon =====
set role anon; select set_config('request.jwt.claim.sub','',false);
select pg_temp.t('anon can apply', (select true from (select public.mo_apply('aabc12345678','guide','{"name_ar":"مرشد تجريبي","name_en":"Test Guide"}','{"contact_email":"x@y.z","consent":"yes"}','{"authority":"MHT","number":"G-1","show_number":"yes"}',array['aabc12345678/licence.pdf'])) q));
do $$ begin perform public.mo_apply('aabc99999999','guide','{"name_ar":"س"}','{"consent":"no"}','{}',null); raise notice 'FAIL anon apply without consent rejected'; exception when others then raise notice 'PASS anon apply without consent rejected (%)', sqlerrm; end $$;
do $$ begin perform public.mo_apply('aabc66666666','guide','{"name_ar":"مرشد اختبار"}','{"consent":"no"}','{}',null); raise notice 'FAIL valid name but no consent rejected'; exception when others then raise notice 'PASS valid name but no consent rejected (%)', sqlerrm; end $$;
do $$ begin perform public.mo_apply('aabc88888888','guide','{"name_ar":"مرشد"}','{"consent":"yes"}','{}',array['otherref1/x.pdf']); raise notice 'FAIL file path outside own folder rejected'; exception when others then raise notice 'PASS file path outside own folder rejected (%)', sqlerrm; end $$;
do $$ begin perform public.mo_apply('bad','guide','{"name_ar":"مرشد"}','{"consent":"yes"}','{}',null); raise notice 'FAIL bad ref rejected'; exception when others then raise notice 'PASS bad ref rejected'; end $$;
select pg_temp.t('anon cannot read applications', (select count(*) from public.mo_applications) = 0);
do $$ begin insert into public.mo_applications(ref,kind,public_data,private_data) values ('aabc77777777','guide','{}','{}'); raise notice 'FAIL anon direct insert blocked'; exception when others then raise notice 'PASS anon direct insert blocked'; end $$;
do $$ begin insert into public.mo_listings(application_ref,kind,public_data) values ('aabc12345678','guide','{"name_en":"Fake"}'); raise notice 'FAIL anon cannot publish'; exception when others then raise notice 'PASS anon cannot publish'; end $$;
do $$ begin perform public.mo_approve('aabc12345678',true,true,'x'); raise notice 'FAIL anon cannot approve'; exception when others then raise notice 'PASS anon cannot approve (%)', sqlerrm; end $$;
select pg_temp.t('anon sees no listings before approval', (select count(*) from public.mo_listings) = 0);
select pg_temp.t('anon can report', (select true from (select public.mo_report('pabc12345678','#calendar','التاريخ خاطئ في هذه الفعالية','')) q));
select pg_temp.t('anon cannot read reports', (select count(*) from public.mo_reports) = 0);
insert into storage.objects(bucket_id,name) values ('mo-licences','aabc12345678/licence.pdf');
select pg_temp.t('anon upload into own ref folder allowed', true);
do $$ begin insert into storage.objects(bucket_id,name) values ('mo-licences','licence.pdf'); raise notice 'FAIL anon upload outside a ref folder blocked'; exception when others then raise notice 'PASS anon upload outside a ref folder blocked'; end $$;
select pg_temp.t('anon cannot list licence files', (select count(*) from storage.objects) = 0);
do $$ begin perform public.mo_set_status('aabc12345678','rejected','x'); raise notice 'FAIL anon cannot change status'; exception when others then raise notice 'PASS anon cannot change status'; end $$;
reset role;

-- ===== signed-in but not a reviewer =====
set role authenticated; select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
select pg_temp.t('non-reviewer cannot read applications', (select count(*) from public.mo_applications) = 0);
select pg_temp.t('non-reviewer cannot read reports', (select count(*) from public.mo_reports) = 0);
select pg_temp.t('non-reviewer cannot read licence files', (select count(*) from storage.objects) = 0);
do $$ begin perform public.mo_approve('aabc12345678',true,true,'x'); raise notice 'FAIL non-reviewer cannot approve'; exception when others then raise notice 'PASS non-reviewer cannot approve'; end $$;
do $$ begin insert into public.mo_reviewers(user_id) values ('22222222-2222-2222-2222-222222222222'); raise notice 'FAIL non-reviewer cannot add self as reviewer'; exception when others then raise notice 'PASS non-reviewer cannot add self as reviewer'; end $$;
reset role;

-- ===== reviewer =====
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select pg_temp.t('reviewer reads applications', (select count(*) from public.mo_applications) = 1);
select pg_temp.t('reviewer reads private contact', (select private_data->>'contact_email' from public.mo_applications where ref='aabc12345678') = 'x@y.z');
select pg_temp.t('reviewer reads reports', (select count(*) from public.mo_reports) = 1);
select pg_temp.t('reviewer reads licence files', (select count(*) from storage.objects where bucket_id='mo-licences') = 1);
select public.mo_approve('aabc12345678', true, true, 'licence checked with MHT');
select pg_temp.t('approval publishes one listing', (select count(*) from public.mo_listings) = 1);
select pg_temp.t('listing has no private data', (select public_data ? 'contact_email' or public_data::text like '%x@y.z%' from public.mo_listings) = false);
select pg_temp.t('licence verified + number shown (allowed by applicant)', (select licence_status='verified' and licence_number='G-1' from public.mo_listings));
do $$ begin perform public.mo_approve('aabc12345678',true,true,'again'); raise notice 'FAIL double approval blocked'; exception when others then raise notice 'PASS double approval blocked'; end $$;
select public.mo_handle_report('pabc12345678','fixed','corrected date');
select pg_temp.t('report handled', (select status from public.mo_reports) = 'fixed');
reset role;

-- ===== anon after approval =====
set role anon; select set_config('request.jwt.claim.sub','',false);
select pg_temp.t('anon sees the approved listing', (select count(*) from public.mo_listings) = 1);
select pg_temp.t('anon still cannot read the application', (select count(*) from public.mo_applications) = 0);
reset role;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select public.mo_set_listing_hidden('aabc12345678', true);
reset role;
set role anon; select set_config('request.jwt.claim.sub','',false);
select pg_temp.t('hidden (outdated) listing disappears for the public', (select count(*) from public.mo_listings) = 0);
reset role;

-- ===== licence not verified => no number, status not_checked =====
set role anon; select set_config('request.jwt.claim.sub','',false);
select public.mo_apply('aabc22222222','operator','{"name_ar":"شركة","name_en":"Co Two"}','{"consent":"yes"}','{"authority":"MHT","number":"T-9","show_number":"yes"}',null);
reset role;
set role authenticated; select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select public.mo_approve('aabc22222222', false, true, 'published without licence check');
select pg_temp.t('unverified licence never shows number or verified badge', (select licence_status='not_checked' and licence_number is null and licence_authority is null from public.mo_listings where application_ref='aabc22222222'));
reset role;
