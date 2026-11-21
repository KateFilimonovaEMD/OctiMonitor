-- OctiMonitor upgrade 002: exact percentiles, per-target budgets, ingestion rules.
-- For projects created with the first schema.sql. Paste everything into the Supabase SQL Editor and press Run once.
-- Generated from Backend/hardening.sql and Backend/dashboard.sql; safe to re-run.

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

-- Existing project: every app that has already sent reports stays allowed, so nothing stops
-- arriving after this upgrade. Check the list (select * from public.octimonitor_apps;) and add
-- apps that haven't reported yet.
insert into public.octimonitor_apps (app)
select distinct app from public.perf_reports where app <> 'unknown'
on conflict do nothing;

-- OctiMonitor dashboard: one read-only function that returns the numbers for the public
-- dashboard. The raw table stays unreadable with the public key; this function runs as its
-- owner (security definer) and returns totals, distributions and anonymous per-window
-- summaries (no session ids). Run in the Supabase SQL Editor after schema.sql; safe to re-run.
--
-- Accuracy
--   * Percentiles come from merged histograms (SDK schema 2): the bucket counts of every
--     window in a group are added up and the percentile is read from the sum, so a p95 over
--     a day is the p95 of all of that day's frames, accurate to half a bucket (0.125 ms below
--     50 ms). Groups that include older reports without histograms fall back to the
--     frame-weighted mean of window p95s and are flagged `*_exact: false`.
--   * GPU time is aggregated only over windows that measured it, weighted by GPU samples.
--     Missing GPU timing is null, never zero.
--   * Each group reports the frame budget it should be judged against (`target_fps`, the
--     most common target in the group; `mixed_targets` when several occur).
--   * Hitch time and fps are sums divided by sums, so they are exact for any group.

create index if not exists perf_reports_created_at_idx on public.perf_reports (created_at desc);

-- Defensive readers: a field that is missing, of the wrong type or out of range reads as null,
-- so a malformed report (for example one stored before the rules in hardening.sql existed) can
-- never make the dashboard fail.
create or replace function public.octimonitor_num(v jsonb)
returns float8 language sql immutable parallel safe set search_path = '' as $$
  select case when jsonb_typeof(v) = 'number' and abs((v::text)::numeric) < 1e15
              then (v::text)::float8 end
$$;

create or replace function public.octimonitor_int(v jsonb)
returns bigint language sql immutable parallel safe set search_path = '' as $$
  select floor(public.octimonitor_num(v))::bigint
$$;

-- ISO 8601 time from the phone, or null if it isn't one.
create or replace function public.octimonitor_ts(v text)
returns timestamptz language plpgsql stable parallel safe set search_path = '' as $$
begin
  if v is null or v !~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' then return null; end if;
  return v::timestamptz;
exception when others then
  return null;
end
$$;

-- Middle of histogram bucket i, in milliseconds. Mirrors DurationHistogram in PerfStats.swift.
create or replace function public.octimonitor_bucket_mid(i int)
returns float8 language sql immutable parallel safe set search_path = '' as $$
  select case
    when i < 200 then (i + 0.5) * 0.25
    when i < 275 then 50 + (i - 200 + 0.5) * 2
    else 200 + (i - 275 + 0.5) * 25
  end
$$;

-- Nearest-rank percentile from bucket/count pairs (duplicates are added up first).
create or replace function public.octimonitor_pct(buckets int[], counts bigint[], p float8)
returns float8 language sql immutable parallel safe set search_path = '' as $$
  with h as (
    select b, sum(c) as c from unnest(buckets, counts) as u(b, c) where b is not null group by b
  ), t as (
    select b, c, sum(c) over (order by b) as cum, sum(c) over () as total from h
  )
  select round(public.octimonitor_bucket_mid(b)::numeric, 3)::float8
  from t where cum >= greatest(1, ceil(p * total)) order by b limit 1
$$;

create or replace function public.octimonitor_overview(p_hours int default 24, p_app text default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with params as (
  select least(greatest(coalesce(p_hours, 24), 1), 720) as hours
),
r as (
  -- `at` is when the window ended on the phone; reports delivered late (offline, saved queue)
  -- still land in the right place on the timeline. Implausible phone clocks fall back to
  -- the arrival time.
  select pr.id, pr.app, pr.session, pr.device, pr.app_version, pr.payload, pr.created_at,
         case when public.octimonitor_ts(pr.payload->>'ended_at') between pr.created_at - interval '2 days'
                                                                       and pr.created_at + interval '5 minutes'
              then public.octimonitor_ts(pr.payload->>'ended_at') else pr.created_at end as at
  from public.perf_reports pr, params
  where pr.kind = 'perf'
    and pr.created_at > now() - make_interval(hours => params.hours)
    and (p_app is null or pr.app = p_app)
),
s as (
  select r.id, r.at, r.app, r.session, r.device, r.app_version,
         r.payload->>'thermal_worst'                                   as thermal,
         coalesce(r.payload->>'pacing', 'draw')                        as pacing,
         public.octimonitor_num(r.payload->'session_active_start_s')   as active_start,
         coalesce(e->>'scene', 'unknown')                              as scene,
         coalesce(case when public.octimonitor_int(e->'target_fps') between 1 and 240 then public.octimonitor_int(e->'target_fps') end,
                  case when public.octimonitor_int(r.payload->'target_fps') between 1 and 240 then public.octimonitor_int(r.payload->'target_fps') end,
                  60)                                                  as target,
         greatest(0, coalesce(public.octimonitor_int(e->'frames'), 0)) as frames,
         greatest(0, coalesce(public.octimonitor_num(e->'seconds'), 0)) as seconds,
         greatest(0, coalesce(public.octimonitor_num(e->'hitch_ms'),
                  public.octimonitor_num(e->'hitch_ms_per_s') * public.octimonitor_num(e->'seconds'), 0)) as hitch_ms,
         greatest(0, coalesce(public.octimonitor_int(e->'dropped_frames'), 0)) as dropped,
         least(1, greatest(0, coalesce(public.octimonitor_num(e->'degraded_share'), 0))) as degraded,
         public.octimonitor_num(e->'frame_ms'->'p95')                  as frame_p95_w,
         -- GPU: measured windows only. Older reports sent zeros with n = 0 for "not measured".
         greatest(0, coalesce(public.octimonitor_int(e->'gpu_ms'->'n'), 0)) as gpu_n,
         case when public.octimonitor_int(e->'gpu_ms'->'n') > 0
              then public.octimonitor_num(e->'gpu_ms'->'p50') end      as gpu_p50_w,
         case when public.octimonitor_int(e->'gpu_ms'->'n') > 0
              then public.octimonitor_num(e->'gpu_ms'->'p95') end      as gpu_p95_w,
         case when jsonb_typeof(e->'frame_hist') = 'array' then e->'frame_hist' end as frame_hist,
         case when jsonb_typeof(e->'gpu_hist') = 'array' then e->'gpu_hist' end     as gpu_hist
  from r, jsonb_array_elements(case when jsonb_typeof(r.payload->'scenes') = 'array'
                                    then r.payload->'scenes' else '[]'::jsonb end) e
  where jsonb_typeof(e) = 'object'
),
first_seen as (
  select session, min(at) as first_at from r group by session
),
step as (
  select case when hours <= 1 then interval '1 minute'
              when hours <= 24 then interval '10 minutes'
              else interval '1 hour' end as width
  from params
),
-- One row per (window, scene, bucket) for frame and GPU histograms
fh as (
  select * from (
    select s.id, s.scene, s.device, s.app, s.app_version, s.at,
           public.octimonitor_int(h->0)::int as b, public.octimonitor_int(h->1) as c
    from s, jsonb_array_elements(s.frame_hist) h where s.frame_hist is not null and jsonb_typeof(h) = 'array'
  ) x where b between 0 and 306 and c > 0
),
gh as (
  select * from (
    select s.id, s.scene, s.device, s.app, s.app_version,
           public.octimonitor_int(h->0)::int as b, public.octimonitor_int(h->1) as c
    from s, jsonb_array_elements(s.gpu_hist) h where s.gpu_hist is not null and jsonb_typeof(h) = 'array'
  ) x where b between 0 and 306 and c > 0
)
select jsonb_build_object(
  'generated_at', now(),
  'hours', (select hours from params),
  'apps', (select coalesce(jsonb_agg(distinct pr.app), '[]'::jsonb)
           from public.perf_reports pr where pr.kind = 'perf'),
  'totals', (select jsonb_build_object(
      'reports', count(*),
      'sessions', count(distinct session),
      'devices', count(distinct device),
      'live_sessions', count(distinct session) filter (where created_at > now() - interval '2 minutes'),
      'last_report_at', max(created_at)
    ) from r),
  'quality', (select jsonb_build_object(
      'reports_dropped', coalesce((select sum(greatest(0, public.octimonitor_int(payload->'reports_dropped'))) from r), 0),
      'screen_timing_share', round((coalesce(sum(frames) filter (where pacing = 'screen'), 0) / nullif(sum(frames), 0)::numeric), 3),
      'histogram_share', round((coalesce(sum(frames) filter (where frame_hist is not null), 0) / nullif(sum(frames), 0)::numeric), 3),
      'gpu_measured_share', round((coalesce(sum(frames) filter (where gpu_n > 0), 0) / nullif(sum(frames), 0)::numeric), 3)
    ) from s),
  'overall', (select jsonb_build_object(
      'frames', coalesce(sum(frames), 0),
      'seconds', round(coalesce(sum(seconds), 0)::numeric, 1),
      'fps', round((sum(frames) / nullif(sum(seconds), 0))::numeric, 1),
      'hitch', round((sum(hitch_ms) / nullif(sum(seconds), 0))::numeric, 2),
      'dropped', coalesce(sum(dropped), 0),
      'target_fps', mode() within group (order by target),
      'mixed_targets', count(distinct target) > 1,
      'frame_p95_exact', bool_and(frame_hist is not null),
      'frame_p95', case when bool_and(frame_hist is not null)
                        then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from fh)
                        else round((sum(frame_p95_w * frames) / nullif(sum(frames) filter (where frame_p95_w is not null), 0))::numeric, 2)::float8 end,
      'gpu_samples', coalesce(sum(gpu_n), 0),
      'gpu_p95_exact', coalesce(bool_and(gpu_hist is not null) filter (where gpu_n > 0), true),
      'gpu_p95', case when coalesce(bool_and(gpu_hist is not null) filter (where gpu_n > 0), true)
                      then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from gh)
                      else round((sum(gpu_p95_w * gpu_n) / nullif(sum(gpu_n) filter (where gpu_p95_w is not null), 0))::numeric, 2)::float8 end
    ) from s),
  'scenes', (select coalesce(jsonb_agg(x order by x->>'scene'), '[]'::jsonb) from (
      select jsonb_build_object(
        'scene', g.scene,
        'frames', sum(g.frames),
        'fps', round((sum(g.frames) / nullif(sum(g.seconds), 0))::numeric, 1),
        'hitch', round((sum(g.hitch_ms) / nullif(sum(g.seconds), 0))::numeric, 2),
        'dropped', sum(g.dropped),
        'degraded', round((sum(g.degraded * g.frames) / nullif(sum(g.frames), 0))::numeric, 3),
        'target_fps', mode() within group (order by g.target),
        'mixed_targets', count(distinct g.target) > 1,
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from fh where fh.scene = g.scene)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_samples', sum(g.gpu_n),
        'gpu_p95_exact', coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true),
        'gpu_p50', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.50) from gh where gh.scene = g.scene)
                        else round((sum(g.gpu_p50_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p50_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_p95', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from gh where gh.scene = g.scene)
                        else round((sum(g.gpu_p95_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.scene) t),
  'device_scene', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object(
        'device', g.device,
        'scene', g.scene,
        'frames', sum(g.frames),
        'target_fps', mode() within group (order by g.target),
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from fh where fh.scene = g.scene and fh.device = g.device)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_samples', sum(g.gpu_n),
        'gpu_p95_exact', coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true),
        'gpu_p95', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from gh where gh.scene = g.scene and gh.device = g.device)
                        else round((sum(g.gpu_p95_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.device, g.scene) t),
  'devices', (select coalesce(jsonb_agg(x order by x->>'device'), '[]'::jsonb) from (
      select jsonb_build_object(
        'device', g.device,
        'frames', sum(g.frames),
        'sessions', count(distinct g.session),
        'fps', round((sum(g.frames) / nullif(sum(g.seconds), 0))::numeric, 1),
        'hitch', round((sum(g.hitch_ms) / nullif(sum(g.seconds), 0))::numeric, 2),
        'target_fps', mode() within group (order by g.target),
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from fh where fh.device = g.device)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_samples', sum(g.gpu_n),
        'gpu_p95_exact', coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true),
        'gpu_p95', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from gh where gh.device = g.device)
                        else round((sum(g.gpu_p95_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.device) t),
  'timeline', (select coalesce(jsonb_agg(x order by x->>'t'), '[]'::jsonb) from (
      select jsonb_build_object(
        't', b.bucket,
        'fps', round((sum(b.frames) / nullif(sum(b.seconds), 0))::numeric, 1),
        'hitch', round((sum(b.hitch_ms) / nullif(sum(b.seconds), 0))::numeric, 2),
        'target_fps', mode() within group (order by b.target),
        'frame_p95_exact', bool_and(b.frame_hist is not null),
        'frame_p95', case when bool_and(b.frame_hist is not null)
                          then (select public.octimonitor_pct(array_agg(fh.b), array_agg(fh.c), 0.95)
                                from fh, step where date_bin(step.width, fh.at, timestamptz '2000-01-01') = b.bucket)
                          else round((sum(b.frame_p95_w * b.frames) / nullif(sum(b.frames) filter (where b.frame_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from (select s.*, date_bin(step.width, s.at, timestamptz '2000-01-01') as bucket from s, step) b
      group by b.bucket) t),
  'session_minutes', (select coalesce(jsonb_agg(x order by (x->>'minute')::int), '[]'::jsonb) from (
      select jsonb_build_object(
        'minute', minute,
        'fps', round((sum(frames) / nullif(sum(seconds), 0))::numeric, 1),
        'hitch', round((sum(hitch_ms) / nullif(sum(seconds), 0))::numeric, 2),
        -- share of sessions that were serious or critical at some point in this minute
        'hot_sessions_share', round((count(distinct session) filter (where thermal in ('serious', 'critical'))
                                     / nullif(count(distinct session), 0)::numeric), 3),
        -- share of measured time in windows whose worst state was serious or critical
        'hot_time_share', round((coalesce(sum(seconds) filter (where thermal in ('serious', 'critical')), 0)
                                 / nullif(sum(seconds), 0))::numeric, 3),
        'sessions', count(distinct session),
        'from_session_clock', bool_and(active_start is not null)
      ) as x
      from (
        -- minutes of drawing since the session started, from the phone's own clock (SDK
        -- schema 2); older reports fall back to the first report seen in the range
        select s.*, coalesce(floor(s.active_start / 60),
                             floor(extract(epoch from (s.at - f.first_at)) / 60))::int as minute
        from s join first_seen f using (session)
      ) m
      where minute <= 60
      group by minute) t),
  'thermal', (select coalesce(jsonb_object_agg(thermal, n), '{}'::jsonb) from (
      select coalesce(payload->>'thermal_worst', 'unknown') as thermal, count(*) as n
      from r group by 1) t),
  'versions', (select coalesce(jsonb_agg(x order by x->>'app', x->>'first_at'), '[]'::jsonb) from (
      select jsonb_build_object(
        'app', g.app,
        'version', g.app_version,
        'first_at', min(g.at),
        'last_at', max(g.at),
        'sessions', count(distinct g.session),
        'devices', count(distinct g.device),
        'frames', sum(g.frames),
        'seconds', round(sum(g.seconds)::numeric, 1),
        'fps', round((sum(g.frames) / nullif(sum(g.seconds), 0))::numeric, 1),
        'hitch', round((sum(g.hitch_ms) / nullif(sum(g.seconds), 0))::numeric, 2),
        'target_fps', mode() within group (order by g.target),
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from fh where fh.app = g.app and fh.app_version = g.app_version)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_p95', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) from gh where gh.app = g.app and gh.app_version = g.app_version)
                        else round((sum(g.gpu_p95_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.app, g.app_version) t),
  -- Per build and phone model, with merged histograms, so the dashboard can compare two
  -- builds on the phones both ran on (a change in the phone mix is not a regression)
  'version_devices', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object(
        'app', g.app, 'version', g.app_version, 'device', g.device,
        'sessions', count(distinct g.session),
        'frames', sum(g.frames),
        'seconds', round(sum(g.seconds)::numeric, 2),
        'hitch_ms', round(sum(g.hitch_ms)::numeric, 2),
        'gpu_samples', sum(g.gpu_n),
        'frame_hist', case when bool_and(g.frame_hist is not null) then
            (select jsonb_agg(jsonb_build_array(b, c) order by b) from
              (select b, sum(c) as c from fh where fh.app = g.app and fh.app_version = g.app_version and fh.device = g.device group by b) q) end,
        'gpu_hist', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), false) then
            (select jsonb_agg(jsonb_build_array(b, c) order by b) from
              (select b, sum(c) as c from gh where gh.app = g.app and gh.app_version = g.app_version and gh.device = g.device group by b) q) end
      ) as x
      from s g group by g.app, g.app_version, g.device) t),
  -- Anonymous summaries of the latest 30-second windows: no session id, one row per window
  'recent', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
      select jsonb_build_object(
        'at', r.at,
        'app', r.app,
        'device', r.device,
        'version', r.app_version,
        'thermal', r.payload->>'thermal_worst',
        'scene', top.scene,
        'fps', top.fps,
        'frame_p95', top.frame_p95,
        'gpu_p95', top.gpu_p95
      ) as x
      from r
      cross join lateral (
        select e->>'scene' as scene, public.octimonitor_num(e->'fps') as fps,
               public.octimonitor_num(e->'frame_ms'->'p95') as frame_p95,
               case when public.octimonitor_int(e->'gpu_ms'->'n') > 0
                    then public.octimonitor_num(e->'gpu_ms'->'p95') end as gpu_p95
        from jsonb_array_elements(case when jsonb_typeof(r.payload->'scenes') = 'array'
                                       then r.payload->'scenes' else '[]'::jsonb end) e
        where jsonb_typeof(e) = 'object'
        order by public.octimonitor_int(e->'frames') desc nulls last
        limit 1
      ) top
      order by r.at desc
      limit 12) t)
);
$$;

revoke all on function public.octimonitor_overview(int, text) from public;
grant execute on function public.octimonitor_overview(int, text) to anon, authenticated;
