"""Edge cases for Backend/dashboard.sql, one small data set per case.

Each case empties the table, writes the reports it needs (as the table owner, so it can set
the arrival time), calls octimonitor_overview and checks the answer:

  * partial GPU coverage (100 GPU samples in 1,800 frames)
  * mixed target rates (30, 60 and 120 fps) judged per target
  * two apps with a scene of the same name stay apart
  * a report delivered two hours late counts when it was measured
  * the same version in debug and release are different builds
  * one long run versus several sessions on a scene and phone
  * no GPU timing, draw-call pacing only
  * a 48-hour gap on the timeline
  * the timeline narrowed to one scene and phone
  * CPU time weighted by the frames drawn
  * the old two-argument call still works

    python3 Backend/tests/check_cases.py "postgresql://postgres@localhost/om"
"""
import json, sys, uuid, datetime as dt
import psycopg

conn = psycopg.connect(sys.argv[1], autocommit=True)
now = dt.datetime.now(dt.timezone.utc)
fails = []


def ok(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name}{(': ' + str(detail)) if detail != '' else ''}")
    if not cond:
        fails.append(name)


def scene(name, frames, ms=16.67, target=60, gpu_n=None, gpu_ms=6.0, cpu=None, draws=None, hist=True):
    """One scene of a report: every frame `ms` long, GPU time `gpu_ms` for `gpu_n` samples."""
    b = min(199, int(ms / 0.25)) if ms < 50 else 200 + int((ms - 50) / 2)
    gb = int(gpu_ms / 0.25)
    gpu_n = frames if gpu_n is None else gpu_n
    e = {"scene": name, "target_fps": target, "frames": frames, "seconds": round(frames * ms / 1000, 3),
         "fps": round(1000 / ms, 2), "hitch_ms": 0, "hitch_ms_per_s": 0, "dropped_frames": 0,
         "draw_calls": frames if draws is None else draws, "cpu_ms_avg": cpu, "degraded_share": 0,
         "frame_ms": {"p50": ms, "p95": ms, "p99": ms, "max": ms, "n": frames},
         "gpu_ms": {"p50": gpu_ms, "p95": gpu_ms, "p99": gpu_ms, "max": gpu_ms, "n": gpu_n} if gpu_n else None,
         "gpu_samples": gpu_n}
    if hist:
        e["frame_hist"] = [[b, frames]]
        if gpu_n:
            e["gpu_hist"] = [[gb, gpu_n]]
    return e


def report(app, scenes, ended, arrived=None, session=None, device="iPhone14,7", version="1.0 (1)", build="release", pacing="screen"):
    payload = {"schema": 2, "window_s": 30, "pacing": pacing, "ended_at": ended.isoformat(), "reports_dropped": 0, "scenes": scenes}
    return (app, "perf", session or str(uuid.uuid4()), device, "iOS 18.1", version, build, json.dumps(payload), arrived or ended)


def load(rows):
    conn.execute("truncate public.perf_reports")
    with conn.cursor() as cur:
        cur.executemany("insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload, created_at) "
                        "values (%s,%s,%s,%s,%s,%s,%s,%s,%s)", rows)


def overview(*args):
    placeholders = ", ".join(["%s"] * len(args))
    return conn.execute(f"select public.octimonitor_overview({placeholders})", args).fetchone()[0]


ago = lambda **kw: now - dt.timedelta(**kw)

# Partial GPU coverage
load([report("com.a", [scene("Menu", 1800, gpu_n=100)], ago(minutes=5))])
d = overview(24, None)
ok("partial GPU coverage is 100 of 1800 frames", abs(d["quality"]["gpu_measured_share"] - 0.056) < 0.001, d["quality"]["gpu_measured_share"])
ok("scene GPU coverage matches", abs(d["scenes"][0]["gpu_coverage"] - 0.056) < 0.001, d["scenes"][0]["gpu_coverage"])

# Mixed target rates
load([report("com.a", [scene("Menu", 900, ms=33.3, target=30)], ago(minutes=5)),
      report("com.a", [scene("Menu", 1800, ms=16.67, target=60)], ago(minutes=5)),
      report("com.a", [scene("Menu", 3600, ms=8.33, target=120)], ago(minutes=5))])
d = overview(24, None)
t = {x["target_fps"]: x for x in d["targets"]}
ok("mixed targets flagged", d["overall"]["mixed_targets"] is True)
ok("one row per target", sorted(t) == [30, 60, 120], sorted(t))
ok("each target keeps its own frame p95", abs(t[30]["frame_p95"] - 33.375) < 0.2 and abs(t[60]["frame_p95"] - 16.625) < 0.2 and abs(t[120]["frame_p95"] - 8.375) < 0.2,
   {k: v["frame_p95"] for k, v in t.items()})
tt = {x["target_fps"] for x in d["timeline_targets"]}
ok("timeline split by target when mixed", tt == {30, 60, 120}, tt)

# Two apps, one scene name
load([report("com.a", [scene("Menu", 1800, ms=10)], ago(minutes=5)),
      report("com.b", [scene("Menu", 1800, ms=30)], ago(minutes=5))])
d = overview(24, None)
menus = {x["app"]: x for x in d["scenes"] if x["scene"] == "Menu"}
ok("same scene name in two apps gives two rows", sorted(menus) == ["com.a", "com.b"], sorted(menus))
ok("their p95s don't mix", abs(menus["com.a"]["frame_p95"] - 10.125) < 0.2 and abs(menus["com.b"]["frame_p95"] - 31) < 1.1,
   {k: v["frame_p95"] for k, v in menus.items()})
ok("scene × phone also keyed by app", len([x for x in d["device_scene"] if x["scene"] == "Menu"]) == 2)

# Late delivery: measured two hours ago, arrived now
load([report("com.a", [scene("Menu", 1800)], ended=ago(hours=2), arrived=now),
      report("com.a", [scene("Menu", 600)], ended=ago(minutes=20), arrived=ago(minutes=19))])
ok("late report stays out of the last hour", overview(1, None)["overall"]["frames"] == 600, overview(1, None)["overall"]["frames"])
d = overview(24, None)
ok("late report counts in the last day", d["overall"]["frames"] == 2400, d["overall"]["frames"])
first = dt.datetime.fromisoformat(d["timeline"][0]["t"])
ok("late report sits at its measured time", abs((first - ago(hours=2)).total_seconds()) < 700, d["timeline"][0]["t"])
load([report("com.a", [scene("Menu", 1800)], ended=ago(days=4), arrived=ago(minutes=3))])
ok("implausible phone clock falls back to arrival", overview(1, None)["overall"]["frames"] == 1800)

# Debug and release of one version
load([report("com.a", [scene("Menu", 1800)], ago(minutes=5), build="debug"),
      report("com.a", [scene("Menu", 1800)], ago(minutes=5), build="release")])
d = overview(24, None)
ok("debug and release are separate builds", sorted(v["build"] for v in d["versions"]) == ["debug", "release"], [v.get("build") for v in d["versions"]])
ok("per-phone build rows split too", len(d["version_devices"]) == 2)
ok("debug share reported", abs(d["quality"]["debug_share"] - 0.5) < 0.001, d["quality"]["debug_share"])

# One long run versus several sessions
long_run = str(uuid.uuid4())
load([report("com.a", [scene("Boss", 2000)], ago(minutes=40 - i), session=long_run, device="iPhone12,1") for i in range(10)] +
     [report("com.a", [scene("Boss", 2000)], ago(minutes=40 - i), device="iPhone14,7") for i in range(10)])
d = overview(24, None)
pairs = {x["device"]: x for x in d["device_scene"]}
ok("one long run counts as one session", pairs["iPhone12,1"]["sessions"] == 1 and pairs["iPhone12,1"]["windows"] == 10)
ok("ten sessions count as ten", pairs["iPhone14,7"]["sessions"] == 10)

# No GPU timing, draw-call pacing
load([report("com.a", [scene("Menu", 1800, gpu_n=0)], ago(minutes=5), pacing="draw")])
d = overview(24, None)
ok("no GPU timing reads as null, not zero", d["overall"]["gpu_p95"] is None and d["scenes"][0]["gpu_p95"] is None)
ok("GPU coverage zero", d["quality"]["gpu_measured_share"] == 0)
ok("screen timing share zero for draw pacing", d["quality"]["screen_timing_share"] == 0)

# A 48-hour gap
load([report("com.a", [scene("Menu", 1800)], ago(hours=50)), report("com.a", [scene("Menu", 1800)], ago(hours=2))])
d = overview(72, None)
ts = [dt.datetime.fromisoformat(x["t"]) for x in d["timeline"]]
ok("timeline keeps real times across a gap", len(ts) == 2 and abs((ts[1] - ts[0]).total_seconds() - 48 * 3600) <= 3600, [x["t"] for x in d["timeline"]])
ok("timeline step reported", d["timeline_step_s"] == 3600)

# Timeline narrowed to a scene and phone
load([report("com.a", [scene("Menu", 1000), scene("Boss", 3000)], ago(minutes=30), device="iPhone12,1"),
      report("com.b", [scene("Menu", 500)], ago(minutes=30), device="iPhone12,1"),
      report("com.a", [scene("Menu", 700)], ago(minutes=30), device="iPhone14,7")])
d = overview(24, None, "Menu", "iPhone12,1", "com.a")
ok("scoped timeline follows scene, app and phone", sum(x["frames"] for x in d["timeline"]) == 1000, sum(x["frames"] for x in d["timeline"]))
ok("the rest stays unscoped", d["overall"]["frames"] == 5200)
ok("scope echoed", d["scope"] == {"scene": "Menu", "scene_app": "com.a", "device": "iPhone12,1"}, d["scope"])
d = overview(24, None, None, "iPhone12,1")
ok("phone-only scope", sum(x["frames"] for x in d["timeline"]) == 4500)

# CPU weighted by frames drawn
load([report("com.a", [scene("Menu", 100, cpu=2.0, draws=100)], ago(minutes=6)),
      report("com.a", [scene("Menu", 300, cpu=4.0, draws=300)], ago(minutes=5))])
d = overview(24, None)
ok("CPU per frame weighted by draws", abs(d["scenes"][0]["cpu_ms"] - 3.5) < 0.001 and d["scenes"][0]["cpu_samples"] == 400, d["scenes"][0]["cpu_ms"])

# Old callers
ok("two-argument call still works", conn.execute("select public.octimonitor_overview(24, null::text)").fetchone()[0]["api"] == 3)

conn.execute("truncate public.perf_reports")
print("FAILED:", len(fails))
sys.exit(1 if fails else 0)
