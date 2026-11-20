-- OctiMonitor reports table for Supabase (Postgres). Run once in the SQL Editor.

create table public.perf_reports (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  app         text not null check (length(app) < 128),
  kind        text not null check (kind in ('perf', 'metrickit', 'diagnostic')),
  session     uuid not null,
  device      text not null check (length(device) < 64),
  os          text not null check (length(os) < 32),
  app_version text not null check (length(app_version) < 32),
  build       text not null check (build in ('debug', 'release')),
  payload     jsonb not null check (pg_column_size(payload) < 262144)
);
create index on public.perf_reports (app, created_at desc);

alter table public.perf_reports enable row level security;
-- The app key can only insert. Reading goes through aggregated views, not the raw table.
create policy "apps insert reports" on public.perf_reports
  for insert to anon with check (true);
