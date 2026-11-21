# Masar Oman — review backend (Supabase)

Status: **prepared, not connected.** The website forms (#join, #report) and the review dashboard (`admin.html`)
are live but switched off: they say so on screen and send nothing until a Supabase project is connected.

## What it does
| Piece | Who can use it |
| --- | --- |
| `mo_apply()` — companies, guides, teams, shops, rental offices register | Public website (anon key) |
| `mo_report()` — visitors report wrong information | Public website (anon key) |
| Private bucket `mo-licences` — licence documents | Public can upload into its own reference folder only; never read or list |
| `mo_applications`, `mo_reports`, `rv_submissions` | Reviewers only |
| `mo_approve()`, `mo_set_status()`, `mo_handle_report()`, `mo_set_listing_hidden()`, `rv_set_status()` | Reviewers only |
| `mo_listings` — what appears on the site after approval | Everyone can read rows that are approved and not hidden |

Nothing is ever published automatically. Approval copies only the public fields; private contact details and
licence files are never published. The "licence verified" badge appears only when a reviewer ticks
"I verified the licence with the issuing body"; the licence number is shown only if the applicant allowed it.

## Connect it (about 10 minutes)
1. Create a free project at supabase.com (region close to Oman).
2. SQL editor → run `docs/caravan-submissions.sql`, then `docs/supabase/masar-backend.sql` (safe to re-run).
3. Authentication → Users → Add user: the reviewer's e-mail and a strong password.
4. SQL editor: `insert into public.mo_reviewers(user_id) select id from auth.users where email = 'REVIEWER@EMAIL';`
5. Settings → API: copy the **Project URL** and the **anon public** key. Never share the `service_role` key
   (the build refuses it).
6. Rebuild with `MO_SB_URL=<url> MO_SB_KEY=<anon key> bash all.sh`, test, publish.

## Tested
`rls-test.sql` runs against a local PostgreSQL 16 with `supabase-shim.sql` (imitation of Supabase roles, `auth` and
`storage`; test only, never run it on Supabase): 34 checks covering what anon, a signed-in non-reviewer and a
reviewer can and cannot do.
