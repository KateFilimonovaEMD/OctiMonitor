-- OctiMonitor ingestion rules: who may write and what a report may look like.
-- Included by schema.sql for new projects and by migrations/002 for existing ones; safe to re-run.

-- 1. Only listed apps can report. Add yours: insert into public.octimonitor_apps values ('com.example.app');
create table if not exists public.octimonitor_apps (app text primary key);
alter table public.octimonitor_apps enable row level security;   -- not readable or writable through the API
insert into public.octimonitor_apps (app) values
  ('com.evamariadreams.opalcaress'), ('com.evamariadreams.octisculpt')
on conflict do nothing;

create or replace function public.octimonitor_app_allowed(p_app text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.octimonitor_apps a where a.app = p_app)
$$;
revoke all on function public.octimonitor_app_allowed(text) from public;
grant execute on function public.octimonitor_app_allowed(text) to anon, authenticated;

drop policy if exists "apps insert reports" on public.perf_reports;
create policy "apps insert reports" on public.perf_reports
  for insert to anon with check (public.octimonitor_app_allowed(app));

-- 2. A report must look like one. NOT VALID: rows already stored are not re-checked.
create or replace function public.octimonitor_payload_ok(p_kind text, p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case when p_kind <> 'perf' then jsonb_typeof(p) = 'object'
  else jsonb_typeof(p->'scenes') = 'array'
       and jsonb_array_length(p->'scenes') between 1 and 33
       and coalesce((p->>'window_s')::float8 between 0 and 86400, true)
       and not exists (
         select 1 from jsonb_array_elements(p->'scenes') e
         where jsonb_typeof(e) <> 'object'
            or length(coalesce(e->>'scene', '')) not between 1 and 64
            or coalesce((e->>'frames')::float8, 0) not between 0 and 1000000
            or coalesce((e->>'seconds')::float8, 0) not between 0 and 86400
            or coalesce((e->>'target_fps')::float8, 60) not between 1 and 240
            or coalesce((e->>'hitch_ms_per_s')::float8, 0) not between 0 and 1000
            or coalesce(jsonb_array_length(case when jsonb_typeof(e->'frame_hist') = 'array' then e->'frame_hist' end), 0) > 307
            or coalesce(jsonb_array_length(case when jsonb_typeof(e->'gpu_hist') = 'array' then e->'gpu_hist' end), 0) > 307)
  end
$$;
alter table public.perf_reports drop constraint if exists perf_reports_payload_shape;
alter table public.perf_reports add constraint perf_reports_payload_shape
  check (public.octimonitor_payload_ok(kind, payload)) not valid;

-- 3. Rate limits: one phone can't flood the table. A real session sends one report every
--    30 s (plus a backlog of at most 20 after being offline); an app sends what its players do.
create index if not exists perf_reports_session_created_idx on public.perf_reports (session, created_at desc);

create or replace function public.octimonitor_rate_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.perf_reports
      where session = new.session and created_at > now() - interval '1 minute') >= 40 then
    raise exception 'OctiMonitor: too many reports from this session' using errcode = 'P0001';
  end if;
  if (select count(*) from public.perf_reports
      where app = new.app and created_at > now() - interval '1 minute') >= 2000 then
    raise exception 'OctiMonitor: too many reports for this app' using errcode = 'P0001';
  end if;
  return new;
end
$$;
drop trigger if exists octimonitor_rate_limit on public.perf_reports;
create trigger octimonitor_rate_limit before insert on public.perf_reports
  for each row execute function public.octimonitor_rate_limit();

-- 4. Least privilege: inserting into an identity column needs no sequence rights.
do $$ begin
  if to_regclass('public.perf_reports_id_seq') is not null then
    revoke usage on sequence public.perf_reports_id_seq from anon;
  end if;
end $$;
