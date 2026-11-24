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
--   * Reports are selected by when they were measured (`at`, from the phone's clock when it
--     is plausible), not when they arrived, so a report delivered late after being offline
--     counts in the period it describes.
--   * Scenes are keyed by app and scene name, so two apps with a scene of the same name never
--     share a percentile. Builds are keyed by app, version and channel (debug or release).
--   * Every group carries its denominators: frames, sessions, report windows, GPU coverage
--     (measured GPU samples per frame, capped at one) and CPU samples.
--   * The timeline can be narrowed to one scene and/or phone model (p_scene, p_scene_app,
--     p_device); everything else always covers the whole selection of app and period.

create index if not exists perf_reports_created_at_idx on public.perf_reports (created_at desc);

-- Defensive readers: a field that is missing, of the wrong type or out of range reads as null,
-- so a malformed report (for example one stored before the rules in hardening.sql existed) can
-- never make the dashboard fail.
-- These two run for every field of every report, so they are written to be inlined into the
-- dashboard query: no SET clause (a SET makes every call a separate function call, which on a
-- month of reports costs seconds). They only use built-in functions, which always resolve from
-- pg_catalog first, so leaving search_path alone opens nothing.
create or replace function public.octimonitor_num(v jsonb)
returns float8 language sql immutable parallel safe as $$
  select case when jsonb_typeof(v) = 'number' and abs((v::text)::numeric) < 1e15
              then (v::text)::float8 end
$$;

create or replace function public.octimonitor_int(v jsonb)
returns bigint language sql immutable parallel safe as $$
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

-- Older versions took (p_hours, p_app); the new parameters have defaults, so old callers keep working.
drop function if exists public.octimonitor_overview(int, text);

create or replace function public.octimonitor_overview(
  p_hours int default 24, p_app text default null,
  p_scene text default null, p_device text default null, p_scene_app text default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
-- Room to group a month of histogram buckets in memory instead of sorting on disk
set work_mem = '32MB'
as $$
with params as (
  select least(greatest(coalesce(p_hours, 24), 1), 720) as hours
),
r as (
  -- `at` is when the window ended on the phone; implausible phone clocks fall back to the
  -- arrival time. Selection is by `at`: since `at` is at most 5 minutes after arrival, every
  -- report measured in the period arrived after its start minus 5 minutes.
  select * from (
    select pr.id, pr.app, pr.session, pr.device, pr.app_version, pr.build, pr.payload, pr.created_at,
           case when e.ended between pr.created_at - interval '2 days' and pr.created_at + interval '5 minutes'
                then e.ended else pr.created_at end as at
    from public.perf_reports pr
    cross join params
    cross join lateral (select public.octimonitor_ts(pr.payload->>'ended_at') as ended) e
    where pr.kind = 'perf'
      and pr.created_at > now() - make_interval(hours => params.hours) - interval '5 minutes'
      and (p_app is null or pr.app = p_app)
  ) x, params
  where x.at > now() - make_interval(hours => params.hours)
),
s as (
  select r.id, r.at, r.app, r.session, r.device, r.app_version, r.build,
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
         -- CPU time the app spent building each frame (what it passes to recordFrame), averaged
         -- over the frames it drew in the window. Not the whole main thread.
         case when public.octimonitor_num(e->'cpu_ms_avg') between 0 and 1000 then public.octimonitor_num(e->'cpu_ms_avg') end as cpu_ms,
         greatest(0, coalesce(public.octimonitor_int(e->'draw_calls'), 0)) as draws,
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
-- The part of s the timeline follows when a scene and/or phone model is selected
ss as (
  select * from s
  where (p_scene is null or (s.scene = p_scene and (p_scene_app is null or s.app = p_scene_app)))
    and (p_device is null or s.device = p_device)
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
-- Histogram entries are read once and summed straight away; every percentile below comes from
-- these sums, so the cost is one pass over the entries however many groups the dashboard shows.
-- Entries are grouped by a small integer key per (app, scene, phone, build, target) rather than
-- by those six columns: grouping hundreds of thousands of rows on integers is several times
-- faster. The readers are written out rather than calling octimonitor_int, the CASE guards the
-- casts (a filter's conditions may run in any order), and OFFSET 0 keeps the planner from
-- repeating the casts in the filter.
keys as (
  select row_number() over () as k, app, scene, device, app_version, build, target
  from (select distinct app, scene, device, app_version, build, target from s) d
),
sk as (
  select s.frame_hist, s.gpu_hist, s.at, keys.k
  from s join keys using (app, scene, device, app_version, build, target)
),
fkb0 as (
  select k, bucket, floor(bn)::int as b, sum(floor(cn))::bigint as c
  from (
    select sk.k, date_bin(step.width, sk.at, timestamptz '2000-01-01') as bucket,
           case when jsonb_typeof(h->0) = 'number' then (h->>0)::numeric end as bn,
           case when jsonb_typeof(h->1) = 'number' then (h->>1)::numeric end as cn
    from sk cross join step cross join lateral jsonb_array_elements(sk.frame_hist) h
    where sk.frame_hist is not null and jsonb_typeof(h) = 'array'
    offset 0
  ) x
  where bn between 0 and 306 and cn between 1 and 1e12
  group by k, bucket, floor(bn)::int
),
gk0 as (
  select k, floor(bn)::int as b, sum(floor(cn))::bigint as c
  from (
    select sk.k,
           case when jsonb_typeof(h->0) = 'number' then (h->>0)::numeric end as bn,
           case when jsonb_typeof(h->1) = 'number' then (h->>1)::numeric end as cn
    from sk cross join lateral jsonb_array_elements(sk.gpu_hist) h
    where sk.gpu_hist is not null and jsonb_typeof(h) = 'array'
    offset 0
  ) x
  where bn between 0 and 306 and cn between 1 and 1e12
  group by k, floor(bn)::int
),
fkb as (
  select keys.app, keys.scene, keys.device, keys.app_version, keys.build, keys.target, f.bucket, f.b, f.c
  from fkb0 f join keys using (k)
),
fk as (
  select keys.app, keys.scene, keys.device, keys.app_version, keys.build, keys.target, f.b, f.c
  from (select k, b, sum(c)::bigint as c from fkb0 group by k, b) f join keys using (k)
),
gk as (
  select keys.app, keys.scene, keys.device, keys.app_version, keys.build, g.b, g.c
  from gk0 g join keys using (k)
),
-- The timeline's buckets, narrowed to the selected scene and phone
ft as (
  select bucket, target, b, sum(c)::bigint as c from fkb
  where (p_scene is null or (scene = p_scene and (p_scene_app is null or app = p_scene_app)))
    and (p_device is null or device = p_device)
  group by bucket, target, b
),
pf_all as (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from fk),
pg_all as (select public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from gk),
pf_target as (select target, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from fk group by target),
pf_scene as (select app, scene, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from fk group by app, scene),
pg_scene as (select app, scene, public.octimonitor_pct(array_agg(b), array_agg(c), 0.50) as p50, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from gk group by app, scene),
pf_ds as (select app, device, scene, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from fk group by app, device, scene),
pg_ds as (select app, device, scene, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from gk group by app, device, scene),
pf_dev as (select device, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from fk group by device),
pg_dev as (select device, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from gk group by device),
pf_ver as (select app, app_version, build, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from fk group by app, app_version, build),
pg_ver as (select app, app_version, build, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from gk group by app, app_version, build),
hf_vd as (
  select app, app_version, build, device, jsonb_agg(jsonb_build_array(b, c) order by b) as hist
  from (select app, app_version, build, device, b, sum(c)::bigint as c from fk group by app, app_version, build, device, b) z
  group by app, app_version, build, device
),
hg_vd as (
  select app, app_version, build, device, jsonb_agg(jsonb_build_array(b, c) order by b) as hist
  from (select app, app_version, build, device, b, sum(c)::bigint as c from gk group by app, app_version, build, device, b) z
  group by app, app_version, build, device
),
pf_bucket as (select bucket, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from ft group by bucket),
pf_bucket_target as (select bucket, target, public.octimonitor_pct(array_agg(b), array_agg(c), 0.95) as p95 from ft group by bucket, target)
select jsonb_build_object(
  'generated_at', now(),
  'hours', (select hours from params),
  'api', 3,
  'scope', jsonb_build_object('scene', p_scene, 'scene_app', p_scene_app, 'device', p_device),
  'apps', (select coalesce(jsonb_agg(distinct pr.app), '[]'::jsonb)
           from public.perf_reports pr where pr.kind = 'perf'),
  'totals', (select jsonb_build_object(
      'reports', count(*),
      'sessions', count(distinct session),
      'devices', count(distinct device),          -- phone models, not physical phones
      'live_sessions', count(distinct session) filter (where created_at > now() - interval '2 minutes'),
      'last_report_at', max(created_at)
    ) from r),
  'quality', (select jsonb_build_object(
      'reports_dropped', coalesce((select sum(greatest(0, public.octimonitor_int(payload->'reports_dropped'))) from r), 0),
      'screen_timing_share', round((coalesce(sum(frames) filter (where pacing = 'screen'), 0) / nullif(sum(frames), 0)::numeric), 3),
      'histogram_share', round((coalesce(sum(frames) filter (where frame_hist is not null), 0) / nullif(sum(frames), 0)::numeric), 3),
      -- measured GPU samples per frame, at most one per frame
      'gpu_measured_share', round((coalesce(sum(least(gpu_n, frames)), 0) / nullif(sum(frames), 0)::numeric), 3),
      'debug_share', round((coalesce(sum(frames) filter (where build = 'debug'), 0) / nullif(sum(frames), 0)::numeric), 3)
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
                        then (select p95 from pf_all)
                        else round((sum(frame_p95_w * frames) / nullif(sum(frames) filter (where frame_p95_w is not null), 0))::numeric, 2)::float8 end,
      'gpu_samples', coalesce(sum(gpu_n), 0),
      'gpu_coverage', round((coalesce(sum(least(gpu_n, frames)), 0) / nullif(sum(frames), 0)::numeric), 3),
      'gpu_p95_exact', coalesce(bool_and(gpu_hist is not null) filter (where gpu_n > 0), true),
      'gpu_p95', case when coalesce(bool_and(gpu_hist is not null) filter (where gpu_n > 0), true)
                      then (select p95 from pg_all)
                      else round((sum(gpu_p95_w * gpu_n) / nullif(sum(gpu_n) filter (where gpu_p95_w is not null), 0))::numeric, 2)::float8 end
    ) from s),
  -- The same, per target frame rate: with several targets, each is judged against its own budget
  'targets', (select coalesce(jsonb_agg(x order by (x->>'target_fps')::int), '[]'::jsonb) from (
      select jsonb_build_object(
        'target_fps', g.target,
        'frames', sum(g.frames),
        'sessions', count(distinct g.session),
        'fps', round((sum(g.frames) / nullif(sum(g.seconds), 0))::numeric, 1),
        'hitch', round((sum(g.hitch_ms) / nullif(sum(g.seconds), 0))::numeric, 2),
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select p95 from pf_target q where q.target = g.target)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.target) t),
  'scenes', (select coalesce(jsonb_agg(x order by x->>'app', x->>'scene'), '[]'::jsonb) from (
      select jsonb_build_object(
        'app', g.app,
        'scene', g.scene,
        'frames', sum(g.frames),
        'sessions', count(distinct g.session),
        'windows', count(distinct g.id),
        'devices', count(distinct g.device),
        'fps', round((sum(g.frames) / nullif(sum(g.seconds), 0))::numeric, 1),
        'hitch', round((sum(g.hitch_ms) / nullif(sum(g.seconds), 0))::numeric, 2),
        'dropped', sum(g.dropped),
        'degraded', round((sum(g.degraded * g.frames) / nullif(sum(g.frames), 0))::numeric, 3),
        'target_fps', mode() within group (order by g.target),
        'mixed_targets', count(distinct g.target) > 1,
        'cpu_ms', round((sum(g.cpu_ms * g.draws) / nullif(sum(g.draws) filter (where g.cpu_ms is not null), 0))::numeric, 2),
        'cpu_samples', coalesce(sum(g.draws) filter (where g.cpu_ms is not null), 0),
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select p95 from pf_scene q where q.app = g.app and q.scene = g.scene)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_samples', sum(g.gpu_n),
        'gpu_coverage', round((sum(least(g.gpu_n, g.frames)) / nullif(sum(g.frames), 0)::numeric), 3),
        'gpu_p95_exact', coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true),
        'gpu_p50', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select p50 from pg_scene q where q.app = g.app and q.scene = g.scene)
                        else round((sum(g.gpu_p50_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p50_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_p95', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select p95 from pg_scene q where q.app = g.app and q.scene = g.scene)
                        else round((sum(g.gpu_p95_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.app, g.scene) t),
  'device_scene', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object(
        'app', g.app,
        'device', g.device,
        'scene', g.scene,
        'frames', sum(g.frames),
        'sessions', count(distinct g.session),
        'windows', count(distinct g.id),
        'first_at', min(g.at),
        'last_at', max(g.at),
        'fps', round((sum(g.frames) / nullif(sum(g.seconds), 0))::numeric, 1),
        'hitch', round((sum(g.hitch_ms) / nullif(sum(g.seconds), 0))::numeric, 2),
        'dropped', sum(g.dropped),
        'target_fps', mode() within group (order by g.target),
        'mixed_targets', count(distinct g.target) > 1,
        'builds', jsonb_agg(distinct g.build),
        'cpu_ms', round((sum(g.cpu_ms * g.draws) / nullif(sum(g.draws) filter (where g.cpu_ms is not null), 0))::numeric, 2),
        'cpu_samples', coalesce(sum(g.draws) filter (where g.cpu_ms is not null), 0),
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select p95 from pf_ds q where q.app = g.app and q.scene = g.scene and q.device = g.device)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_samples', sum(g.gpu_n),
        'gpu_coverage', round((sum(least(g.gpu_n, g.frames)) / nullif(sum(g.frames), 0)::numeric), 3),
        'gpu_p95_exact', coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true),
        'gpu_p95', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select p95 from pg_ds q where q.app = g.app and q.scene = g.scene and q.device = g.device)
                        else round((sum(g.gpu_p95_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.app, g.device, g.scene) t),
  'devices', (select coalesce(jsonb_agg(x order by x->>'device'), '[]'::jsonb) from (
      select jsonb_build_object(
        'device', g.device,
        'frames', sum(g.frames),
        'sessions', count(distinct g.session),
        'windows', count(distinct g.id),
        'fps', round((sum(g.frames) / nullif(sum(g.seconds), 0))::numeric, 1),
        'hitch', round((sum(g.hitch_ms) / nullif(sum(g.seconds), 0))::numeric, 2),
        'target_fps', mode() within group (order by g.target),
        'mixed_targets', count(distinct g.target) > 1,
        'cpu_ms', round((sum(g.cpu_ms * g.draws) / nullif(sum(g.draws) filter (where g.cpu_ms is not null), 0))::numeric, 2),
        'cpu_samples', coalesce(sum(g.draws) filter (where g.cpu_ms is not null), 0),
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select p95 from pf_dev q where q.device = g.device)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_samples', sum(g.gpu_n),
        'gpu_coverage', round((sum(least(g.gpu_n, g.frames)) / nullif(sum(g.frames), 0)::numeric), 3),
        'gpu_p95_exact', coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true),
        'gpu_p95', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select p95 from pg_dev q where q.device = g.device)
                        else round((sum(g.gpu_p95_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.device) t),
  -- Buckets with data only; the dashboard draws gaps where buckets are missing.
  'timeline_step_s', (select extract(epoch from width)::int from step),
  'timeline', (select coalesce(jsonb_agg(x order by x->>'t'), '[]'::jsonb) from (
      select jsonb_build_object(
        't', b.bucket,
        'frames', sum(b.frames),
        'sessions', count(distinct b.session),
        'fps', round((sum(b.frames) / nullif(sum(b.seconds), 0))::numeric, 1),
        'hitch', round((sum(b.hitch_ms) / nullif(sum(b.seconds), 0))::numeric, 2),
        'target_fps', mode() within group (order by b.target),
        'mixed_targets', count(distinct b.target) > 1,
        'frame_p95_exact', bool_and(b.frame_hist is not null),
        'frame_p95', case when bool_and(b.frame_hist is not null)
                          then (select p95 from pf_bucket q where q.bucket = b.bucket)
                          else round((sum(b.frame_p95_w * b.frames) / nullif(sum(b.frames) filter (where b.frame_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from (select ss.*, date_bin(step.width, ss.at, timestamptz '2000-01-01') as bucket from ss, step) b
      group by b.bucket) t),
  -- With several target rates in view, frame time and fps per target, so each line can be
  -- drawn against its own budget. Empty when there is only one target.
  'timeline_targets', (select coalesce(jsonb_agg(x order by x->>'t', (x->>'target_fps')::int), '[]'::jsonb) from (
      select jsonb_build_object(
        't', b.bucket,
        'target_fps', b.target,
        'frames', sum(b.frames),
        'fps', round((sum(b.frames) / nullif(sum(b.seconds), 0))::numeric, 1),
        'frame_p95_exact', bool_and(b.frame_hist is not null),
        'frame_p95', case when bool_and(b.frame_hist is not null)
                          then (select p95 from pf_bucket_target q where q.bucket = b.bucket and q.target = b.target)
                          else round((sum(b.frame_p95_w * b.frames) / nullif(sum(b.frames) filter (where b.frame_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from (select ss.*, date_bin(step.width, ss.at, timestamptz '2000-01-01') as bucket from ss, step) b
      where (select count(distinct target) from ss) > 1
      group by b.bucket, b.target) t),
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
        'build', g.build,
        'first_at', min(g.at),
        'last_at', max(g.at),
        'sessions', count(distinct g.session),
        'devices', count(distinct g.device),
        'frames', sum(g.frames),
        'seconds', round(sum(g.seconds)::numeric, 1),
        'fps', round((sum(g.frames) / nullif(sum(g.seconds), 0))::numeric, 1),
        'hitch', round((sum(g.hitch_ms) / nullif(sum(g.seconds), 0))::numeric, 2),
        'target_fps', mode() within group (order by g.target),
        'mixed_targets', count(distinct g.target) > 1,
        'frame_p95_exact', bool_and(g.frame_hist is not null),
        'frame_p95', case when bool_and(g.frame_hist is not null)
                          then (select p95 from pf_ver q where q.app = g.app and q.app_version = g.app_version and q.build = g.build)
                          else round((sum(g.frame_p95_w * g.frames) / nullif(sum(g.frames) filter (where g.frame_p95_w is not null), 0))::numeric, 2)::float8 end,
        'gpu_p95', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), true)
                        then (select p95 from pg_ver q where q.app = g.app and q.app_version = g.app_version and q.build = g.build)
                        else round((sum(g.gpu_p95_w * g.gpu_n) / nullif(sum(g.gpu_n) filter (where g.gpu_p95_w is not null), 0))::numeric, 2)::float8 end
      ) as x
      from s g group by g.app, g.app_version, g.build) t),
  -- Per build (version and channel) and phone model, with merged histograms, so the dashboard
  -- can compare two builds of the same channel on the phones both ran on
  'version_devices', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object(
        'app', g.app, 'version', g.app_version, 'build', g.build, 'device', g.device,
        'sessions', count(distinct g.session),
        'frames', sum(g.frames),
        'seconds', round(sum(g.seconds)::numeric, 2),
        'hitch_ms', round(sum(g.hitch_ms)::numeric, 2),
        'gpu_samples', sum(g.gpu_n),
        'frame_hist', case when bool_and(g.frame_hist is not null) then
            (select hist from hf_vd q where q.app = g.app and q.app_version = g.app_version and q.build = g.build and q.device = g.device) end,
        'gpu_hist', case when coalesce(bool_and(g.gpu_hist is not null) filter (where g.gpu_n > 0), false) then
            (select hist from hg_vd q where q.app = g.app and q.app_version = g.app_version and q.build = g.build and q.device = g.device) end
      ) as x
      from s g group by g.app, g.app_version, g.build, g.device) t),
  -- Anonymous summaries of the latest 30-second windows: no session id, one row per window
  'recent', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
      select jsonb_build_object(
        'at', r.at,
        'app', r.app,
        'device', r.device,
        'version', r.app_version,
        'build', r.build,
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

revoke all on function public.octimonitor_overview(int, text, text, text, text) from public;
grant execute on function public.octimonitor_overview(int, text, text, text, text) to anon, authenticated;
