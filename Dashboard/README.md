# Dashboard

A ready-made web dashboard for your own OctiMonitor data: the same page as the [live example](https://evamariadreams.com/octimonitor/), pointed at your backend. Two static files, no build step, no server code:

- `index.html`: the dashboard (frame pacing, hitch time, GPU time per scene, heat, memory, build comparison on matched phones, a downloadable report).
- `docs/index.html`: how every number on it is measured. The dashboard links to it.

## Setup (about 10 minutes)

1. **Create the backend.** In a new [Supabase](https://supabase.com) project, open the SQL Editor and run, in order, [`Backend/schema.sql`](../Backend/schema.sql), [`Backend/hardening.sql`](../Backend/hardening.sql) and [`Backend/dashboard.sql`](../Backend/dashboard.sql).
   Already have a backend from an earlier OctiMonitor version? Run [`Backend/migrations/003_diagnostics.sql`](../Backend/migrations/003_diagnostics.sql) instead (or `002` first if you started with the very first schema); the page also works with an older function, without the newer details.
2. **Allow your app** to report (one line per bundle id):
   ```sql
   insert into public.octimonitor_apps values ('com.example.mygame');
   ```
3. **Point your app at it.** In the app's Info.plist set `OctiMonitorEndpoint` to `https://<project>.supabase.co/rest/v1/perf_reports` and `OctiMonitorKey` to the project's publishable key. See the main [README](../README.md#backend-supabase).
4. **Point the dashboard at it.** Open `Dashboard/index.html` and change the settings block near the top of the script:
   ```js
   const SUPABASE_URL = "https://<project>.supabase.co";
   const PUBLIC_KEY = "sb_publishable_…";
   const APP_NAMES = { "com.example.mygame": "My Game" };   // optional display names
   ```
   Both values are in Supabase under Project Settings → API. Until they are set, the page says "Not set up" and makes no requests.
5. **Publish the folder** anywhere that serves static files: GitHub Pages, Netlify, Cloudflare Pages, or your own site. Keep `docs/` next to `index.html`. To try it locally: `python3 -m http.server` in this folder, then open http://localhost:8000.

Play your app for a minute: the first numbers arrive within 30 seconds of a session.

## Is the key safe to publish?

Yes. The publishable key is meant to be visible in web pages. With the three SQL files above it can only insert reports (for allowed apps, with plausible shapes, rate limited) and call the read-only `octimonitor_overview` function, which returns aggregates. It cannot read, change or delete the table. If junk reports ever get in, delete them by time range and rotate the key in Supabase.

## Customizing

- Text, colors and fonts are plain HTML and CSS in `index.html`; the color variables are at the top of the `<style>` block.
- The page loads [ECharts](https://echarts.apache.org) and the Archivo font from public CDNs. To host them yourself, change the two `<script>`/`<link>` tags.
- The frame budget follows each scene's reported target rate (60 or 120 fps), so nothing needs changing for ProMotion games.
