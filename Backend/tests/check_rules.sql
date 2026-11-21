-- Ingestion rules, run as the public (anon) role. Each statement that must fail is wrapped
-- so the script continues; the final count tells whether everything behaved.
create temp table results (name text, ok boolean);
grant insert, select on results to anon;
insert into public.octimonitor_apps values ('com.example.game') on conflict do nothing;
set role anon;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.example.game','perf','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release',
          '{"schema":2,"window_s":30.01,"target_fps":60,"ended_at":"2026-11-21T03:00:00.000Z","reports_dropped":0,
            "scenes":[{"scene":"Spark","frames":1800,"seconds":30,"target_fps":60,"fps":60,"hitch_ms":0,"hitch_ms_per_s":0,
                       "dropped_frames":0,"draw_calls":1800,"degraded_share":0,"cpu_ms_avg":null,"gpu_ms":null,"gpu_samples":0,
                       "frame_ms":{"p50":16.67,"p95":17.4,"p99":18,"max":20,"n":1800},"frame_hist":[[66,1800]]}]}');
  insert into results values ('listed app inserts a full report', true);
exception when others then insert into results values ('listed app inserts a full report', false); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.example.game','metrickit','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release','{"timeStampBegin":"x"}');
  insert into results values ('MetricKit payload inserts', true);
exception when others then insert into results values ('MetricKit payload inserts', false); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.unknown.app','perf','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release','{"scenes":[{"scene":"x","frames":1}]}');
  insert into results values ('unlisted app rejected', false);
exception when others then insert into results values ('unlisted app rejected', true); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.example.game','perf','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release','{"scenes":[{"scene":"x","frames":99999999}]}');
  insert into results values ('implausible frame count rejected', false);
exception when others then insert into results values ('implausible frame count rejected', true); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.example.game','perf','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release','{"scenes":[{"scene":"x","frames":"1800"}]}');
  insert into results values ('number sent as text rejected', false);
exception when others then insert into results values ('number sent as text rejected', true); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.example.game','perf','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release','{"scenes":[{"scene":"x","frames":10,"frame_hist":[[999,5]]}]}');
  insert into results values ('histogram bucket out of range rejected', false);
exception when others then insert into results values ('histogram bucket out of range rejected', true); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.example.game','metrickit','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release','[1,2]');
  insert into results values ('non-object payload rejected', false);
exception when others then insert into results values ('non-object payload rejected', true); end $$;
do $$ begin
  perform count(*) from public.perf_reports;
  insert into results values ('raw table unreadable', false);
exception when others then insert into results values ('raw table unreadable', true); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  select 'com.example.game','perf','22222222-2222-2222-2222-222222222222','iPhone14,7','iOS 18','1.0 (1)','release',
         '{"scenes":[{"scene":"Spark","frames":10}]}'::jsonb from generate_series(1, 45);
  insert into results values ('flood from one session rejected with 429', false);
exception when others then
  -- PT429 is how PostgREST is told to answer HTTP 429, which the SDK retries later
  insert into results values ('flood from one session rejected with 429', sqlstate = 'PT429'); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  select 'com.example.game','perf','33333333-3333-3333-3333-333333333333','iPhone14,7','iOS 18','1.0 (1)','release',
         '{"scenes":[{"scene":"Spark","frames":10}]}'::jsonb from generate_series(1, 21);
  insert into results values ('offline backlog accepted', true);
exception when others then insert into results values ('offline backlog accepted', false); end $$;
do $$ begin
  perform public.octimonitor_overview(24, null);
  insert into results values ('dashboard function callable', true);
exception when others then insert into results values ('dashboard function callable', false); end $$;
reset role;

-- Rows stored before the rules existed are not re-checked. The dashboard must still work
-- with malformed ones: strings for numbers, fractions, broken times, bad histogram entries.
alter table public.perf_reports drop constraint perf_reports_payload_shape;
alter table public.perf_reports disable trigger octimonitor_rate_limit;
insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload) values
  ('com.example.game','perf','44444444-4444-4444-4444-444444444444','iPhone14,7','iOS 18','0.9 (1)','release',
   '{"ended_at":"2026-99-99T25:00:00Z","target_fps":"60","reports_dropped":"x","session_active_start_s":"soon",
     "scenes":[{"scene":"Spark","frames":1.5,"seconds":"30","target_fps":59.5,"dropped_frames":"many","hitch_ms":{"a":1},
                "frame_ms":{"p95":"slow"},"gpu_ms":{"n":"3","p95":[1]},"frame_hist":[[1,2],"x",[999,1],[-3,4],[5,"6"],[7]],
                "gpu_hist":{"b":1}}, 7, "scene"]}'),
  ('com.example.game','perf','44444444-4444-4444-4444-444444444444','iPhone14,7','iOS 18','0.9 (1)','release', '{"scenes":{"x":1}}'),
  ('com.example.game','perf','44444444-4444-4444-4444-444444444444','iPhone14,7','iOS 18','0.9 (1)','release', '{"scenes":[{"scene":"Big","frames":1e400,"seconds":1e300}]}'),
  ('com.example.game','perf','44444444-4444-4444-4444-444444444444','iPhone14,7','iOS 18','0.9 (1)','release', '[]');
alter table public.perf_reports enable trigger octimonitor_rate_limit;
alter table public.perf_reports add constraint perf_reports_payload_shape
  check (public.octimonitor_payload_ok(kind, payload)) not valid;
set role anon;
do $$ declare d jsonb; begin
  d := public.octimonitor_overview(24, null);
  insert into results values ('dashboard survives malformed stored rows',
    d->'overall' is not null and jsonb_typeof(d->'scenes') = 'array' and (d->'overall'->>'frames')::bigint >= 1800);
exception when others then
  raise warning 'dashboard failed: %', sqlerrm;
  insert into results values ('dashboard survives malformed stored rows', false); end $$;
reset role;

select name, case when ok then 'PASS' else 'FAIL' end from results;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'ingestion rules failed'; end if;
end $$;
