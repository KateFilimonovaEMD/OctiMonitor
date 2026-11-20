-- OctiMonitor public dashboard: one read-only function that returns aggregates only.
-- The raw table stays unreadable with the public key; this function runs as its owner
-- (security definer) and exposes counts, frame-weighted means and distributions,
-- never individual rows or session ids. Run once in the Supabase SQL Editor, after schema.sql.
--
-- Per-scene "p95" values are frame-weighted means of the 30-second windows' p95,
-- a standard approximation when only window summaries are stored.

create index if not exists perf_reports_created_at_idx on public.perf_reports (created_at desc);

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
  select pr.id, pr.created_at, pr.app, pr.session, pr.device, pr.app_version, pr.payload
  from public.perf_reports pr, params
  where pr.kind = 'perf'
    and pr.created_at > now() - make_interval(hours => params.hours)
    and (p_app is null or pr.app = p_app)
),
s as (
  select r.id, r.created_at, r.app, r.session, r.device, r.app_version,
         r.payload->>'thermal_worst'                as thermal,
         e->>'scene'                                as scene,
         coalesce((e->>'frames')::int, 0)           as frames,
         coalesce((e->>'seconds')::float8, 0)       as seconds,
         coalesce((e->'frame_ms'->>'p95')::float8, 0) as frame_p95,
         coalesce((e->'gpu_ms'->>'p50')::float8, 0) as gpu_p50,
         coalesce((e->'gpu_ms'->>'p95')::float8, 0) as gpu_p95,
         coalesce((e->>'hitch_ms_per_s')::float8, 0) as hitch,
         coalesce((e->>'dropped_frames')::int, 0)   as dropped,
         coalesce((e->>'degraded_share')::float8, 0) as degraded
  from r, jsonb_array_elements(coalesce(r.payload->'scenes', '[]'::jsonb)) e
),
first_seen as (
  select session, min(created_at) as first_at from r group by session
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
  'overall', (select jsonb_build_object(
      'frames', coalesce(sum(frames), 0),
      'seconds', round(coalesce(sum(seconds), 0)::numeric, 1),
      'fps', round((sum(frames) / nullif(sum(seconds), 0))::numeric, 1),
      'frame_p95', round((sum(frame_p95 * frames) / nullif(sum(frames), 0))::numeric, 2),
      'gpu_p95', round((sum(gpu_p95 * frames) / nullif(sum(frames), 0))::numeric, 2),
      'hitch', round((sum(hitch * seconds) / nullif(sum(seconds), 0))::numeric, 2),
      'dropped', coalesce(sum(dropped), 0)
    ) from s),
  'scenes', (select coalesce(jsonb_agg(x order by x->>'scene'), '[]'::jsonb) from (
      select jsonb_build_object(
        'scene', scene,
        'frames', sum(frames),
        'fps', round((sum(frames) / nullif(sum(seconds), 0))::numeric, 1),
        'frame_p95', round((sum(frame_p95 * frames) / nullif(sum(frames), 0))::numeric, 2),
        'gpu_p50', round((sum(gpu_p50 * frames) / nullif(sum(frames), 0))::numeric, 2),
        'gpu_p95', round((sum(gpu_p95 * frames) / nullif(sum(frames), 0))::numeric, 2),
        'hitch', round((sum(hitch * seconds) / nullif(sum(seconds), 0))::numeric, 2),
        'dropped', sum(dropped),
        'degraded', round((sum(degraded * frames) / nullif(sum(frames), 0))::numeric, 3)
      ) as x
      from s group by scene) t),
  'device_scene', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
      select jsonb_build_object(
        'device', device,
        'scene', scene,
        'frames', sum(frames),
        'gpu_p95', round((sum(gpu_p95 * frames) / nullif(sum(frames), 0))::numeric, 2),
        'frame_p95', round((sum(frame_p95 * frames) / nullif(sum(frames), 0))::numeric, 2)
      ) as x
      from s group by device, scene) t),
  'timeline', (select coalesce(jsonb_agg(x order by x->>'t'), '[]'::jsonb) from (
      select jsonb_build_object(
        't', bucket,
        'fps', round((sum(frames) / nullif(sum(seconds), 0))::numeric, 1),
        'frame_p95', round((sum(frame_p95 * frames) / nullif(sum(frames), 0))::numeric, 2),
        'hitch', round((sum(hitch * seconds) / nullif(sum(seconds), 0))::numeric, 2)
      ) as x
      from (
        select s.*, date_bin(
                 case when p.hours <= 1 then interval '1 minute'
                      when p.hours <= 24 then interval '10 minutes'
                      else interval '1 hour' end,
                 s.created_at, timestamptz '2000-01-01') as bucket
        from s, params p
      ) b group by bucket) t),
  'session_minutes', (select coalesce(jsonb_agg(x order by (x->>'minute')::int), '[]'::jsonb) from (
      select jsonb_build_object(
        'minute', minute,
        'fps', round((sum(frames) / nullif(sum(seconds), 0))::numeric, 1),
        'hitch', round((sum(hitch * seconds) / nullif(sum(seconds), 0))::numeric, 2),
        'hot_share', round((coalesce(sum(seconds) filter (where thermal in ('serious', 'critical')), 0)
                            / nullif(sum(seconds), 0))::numeric, 3),
        'sessions', count(distinct session)
      ) as x
      from (
        select s.*, floor(extract(epoch from (s.created_at - f.first_at)) / 60)::int as minute
        from s join first_seen f using (session)
      ) m
      where minute <= 60
      group by minute) t),
  'thermal', (select coalesce(jsonb_object_agg(thermal, n), '{}'::jsonb) from (
      select coalesce(payload->>'thermal_worst', 'unknown') as thermal, count(*) as n
      from r group by 1) t),
  'versions', (select coalesce(jsonb_agg(x order by x->>'app', x->>'version' desc), '[]'::jsonb) from (
      select jsonb_build_object(
        'app', app,
        'version', app_version,
        'sessions', count(distinct session),
        'fps', round((sum(frames) / nullif(sum(seconds), 0))::numeric, 1),
        'frame_p95', round((sum(frame_p95 * frames) / nullif(sum(frames), 0))::numeric, 2),
        'gpu_p95', round((sum(gpu_p95 * frames) / nullif(sum(frames), 0))::numeric, 2),
        'hitch', round((sum(hitch * seconds) / nullif(sum(seconds), 0))::numeric, 2)
      ) as x
      from s group by app, app_version) t),
  'recent', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
      select jsonb_build_object(
        'at', r.created_at,
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
        select e->>'scene' as scene, (e->>'fps')::float8 as fps,
               (e->'frame_ms'->>'p95')::float8 as frame_p95,
               (e->'gpu_ms'->>'p95')::float8 as gpu_p95
        from jsonb_array_elements(coalesce(r.payload->'scenes', '[]'::jsonb)) e
        order by (e->>'frames')::int desc nulls last
        limit 1
      ) top
      order by r.created_at desc
      limit 15) t)
);
$$;

revoke all on function public.octimonitor_overview(int, text) from public;
grant execute on function public.octimonitor_overview(int, text) to anon, authenticated;
