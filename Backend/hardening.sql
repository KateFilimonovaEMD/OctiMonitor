-- OctiMonitor ingestion rules: who may write and what a report may look like.
-- Run after schema.sql (new projects); included in migrations/002 (existing ones). Safe to re-run.

-- 1. Only listed apps can report. Add each of yours (its bundle id):
--      insert into public.octimonitor_apps values ('com.example.app');
create table if not exists public.octimonitor_apps (app text primary key);
alter table public.octimonitor_apps enable row level security;   -- not readable or writable through the API

create or replace function public.octimonitor_app_allowed(p_app text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.octimonitor_apps a where a.app = p_app)
$$;
revoke all on function public.octimonitor_app_allowed(text) from public;
grant execute on function public.octimonitor_app_allowed(text) to anon, authenticated;

drop policy if exists "apps insert reports" on public.perf_reports;
create policy "apps insert reports" on public.perf_reports
  for insert to anon with check (public.octimonitor_app_allowed(app));

-- 2. A report must look like one: the shape the SDK sends, numbers where numbers belong, in
--    plausible ranges. NOT VALID: rows already stored are not re-checked (the dashboard
--    function reads every field defensively anyway).

-- True when v is absent, JSON null, or a JSON number between lo and hi.
create or replace function public.octimonitor_in(v jsonb, lo float8, hi float8)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select case when v is null or jsonb_typeof(v) = 'null' then true
              when jsonb_typeof(v) = 'number' then (v::text)::numeric between lo::numeric and hi::numeric
              else false end
$$;

-- True when v is absent, JSON null, or an array of [bucket, count] pairs that fit the histogram.
create or replace function public.octimonitor_hist_ok(v jsonb)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select case when v is null or jsonb_typeof(v) = 'null' then true
              when jsonb_typeof(v) <> 'array' then false
              when jsonb_array_length(v) > 307 then false
              else not exists (
                select 1 from jsonb_array_elements(v) h
                where case when jsonb_typeof(h) <> 'array' then true
                           else not (public.octimonitor_in(h->0, 0, 306) and public.octimonitor_in(h->1, 0, 10000000)
                                     and jsonb_typeof(h->0) = 'number' and jsonb_typeof(h->1) = 'number') end)
         end
$$;

create or replace function public.octimonitor_payload_ok(p_kind text, p jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select case
    when jsonb_typeof(p) <> 'object' then false
    when p_kind <> 'perf' then true
    when jsonb_typeof(p->'scenes') <> 'array' or jsonb_typeof(p->'scenes') is null then false
    when jsonb_array_length(p->'scenes') not between 1 and 33 then false
    else public.octimonitor_in(p->'window_s', 0, 86400)
     and public.octimonitor_in(p->'target_fps', 1, 240)
     and public.octimonitor_in(p->'session_active_start_s', 0, 1e9)
     and public.octimonitor_in(p->'session_active_s', 0, 1e9)
     and public.octimonitor_in(p->'memory_mb_peak', 0, 1e6)
     and public.octimonitor_in(p->'reports_dropped', 0, 1e6)
     and not exists (
       select 1 from jsonb_array_elements(p->'scenes') e
       where case when jsonb_typeof(e) <> 'object' then true
                  when jsonb_typeof(e->'scene') is distinct from 'string' then true
                  else length(e->>'scene') not between 1 and 64
                    or not public.octimonitor_in(e->'frames', 0, 1000000)
                    or not public.octimonitor_in(e->'seconds', 0, 86400)
                    or not public.octimonitor_in(e->'fps', 0, 1000)
                    or not public.octimonitor_in(e->'target_fps', 1, 240)
                    or not public.octimonitor_in(e->'hitch_ms_per_s', 0, 1000)
                    or not public.octimonitor_in(e->'hitch_ms', 0, 86400000)
                    or not public.octimonitor_in(e->'dropped_frames', 0, 1000000)
                    or not public.octimonitor_in(e->'draw_calls', 0, 10000000)
                    or not public.octimonitor_in(e->'degraded_share', 0, 1)
                    or not public.octimonitor_in(e->'gpu_samples', 0, 10000000)
                    or not public.octimonitor_in(e->'frame_ms'->'p95', 0, 100000)
                    or not public.octimonitor_in(e->'gpu_ms'->'p95', 0, 100000)
                    or not public.octimonitor_in(e->'gpu_ms'->'n', 0, 10000000)
                    or not public.octimonitor_hist_ok(e->'frame_hist')
                    or not public.octimonitor_hist_ok(e->'gpu_hist') end)
  end
$$;
alter table public.perf_reports drop constraint if exists perf_reports_payload_shape;
alter table public.perf_reports add constraint perf_reports_payload_shape
  check (public.octimonitor_payload_ok(kind, payload)) not valid;

-- 3. Rate limits: one phone can't flood the table. A real session sends one report every
--    30 s (plus a backlog of at most 20 after being offline); an app sends what its players do.
--    SQLSTATE PT429 makes the API answer HTTP 429, so the SDK keeps those rows and retries later.
create index if not exists perf_reports_session_created_idx on public.perf_reports (session, created_at desc);

create or replace function public.octimonitor_rate_limit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.perf_reports
      where session = new.session and created_at > now() - interval '1 minute') >= 40 then
    raise exception 'OctiMonitor: too many reports from this session' using errcode = 'PT429';
  end if;
  if (select count(*) from public.perf_reports
      where app = new.app and created_at > now() - interval '1 minute') >= 2000 then
    raise exception 'OctiMonitor: too many reports for this app' using errcode = 'PT429';
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
