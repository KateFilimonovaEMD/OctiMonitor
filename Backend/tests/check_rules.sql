-- Ingestion rules, run as the public (anon) role. Each statement that must fail is wrapped
-- so the script continues; the final count tells whether everything behaved.
create temp table results (name text, ok boolean);
grant insert, select on results to anon;
set role anon;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.evamariadreams.opalcaress','perf','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release',
          '{"schema":2,"scenes":[{"scene":"Spark","frames":1800,"seconds":30,"target_fps":60,"frame_hist":[[66,1800]]}]}');
  insert into results values ('listed app inserts', true);
exception when others then insert into results values ('listed app inserts', false); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.unknown.app','perf','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release','{"scenes":[{"scene":"x","frames":1}]}');
  insert into results values ('unlisted app rejected', false);
exception when others then insert into results values ('unlisted app rejected', true); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  values ('com.evamariadreams.opalcaress','perf','11111111-1111-1111-1111-111111111111','iPhone14,7','iOS 18','1.0 (1)','release','{"scenes":[{"scene":"x","frames":99999999}]}');
  insert into results values ('implausible report rejected', false);
exception when others then insert into results values ('implausible report rejected', true); end $$;
do $$ begin
  perform count(*) from public.perf_reports;
  insert into results values ('raw table unreadable', false);
exception when others then insert into results values ('raw table unreadable', true); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  select 'com.evamariadreams.opalcaress','perf','22222222-2222-2222-2222-222222222222','iPhone14,7','iOS 18','1.0 (1)','release',
         '{"scenes":[{"scene":"Spark","frames":10}]}'::jsonb from generate_series(1, 45);
  insert into results values ('flood from one session rejected', false);
exception when others then insert into results values ('flood from one session rejected', true); end $$;
do $$ begin
  insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload)
  select 'com.evamariadreams.opalcaress','perf','33333333-3333-3333-3333-333333333333','iPhone14,7','iOS 18','1.0 (1)','release',
         '{"scenes":[{"scene":"Spark","frames":10}]}'::jsonb from generate_series(1, 21);
  insert into results values ('offline backlog accepted', true);
exception when others then insert into results values ('offline backlog accepted', false); end $$;
do $$ begin
  perform public.octimonitor_overview(24, null);
  insert into results values ('dashboard function callable', true);
exception when others then insert into results values ('dashboard function callable', false); end $$;
reset role;
select name, case when ok then 'PASS' else 'FAIL' end from results;
do $$ begin
  if exists (select 1 from results where not ok) then raise exception 'ingestion rules failed'; end if;
end $$;
