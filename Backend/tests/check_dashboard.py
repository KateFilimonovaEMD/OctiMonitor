"""Ground-truth check for Backend/dashboard.sql.

Simulates phones the way the SDK measures them (every frame and GPU time known), writes the
reports the SDK would send, runs octimonitor_overview, and compares its answers with values
computed directly from all the frames.

    python3 Backend/tests/check_dashboard.py "postgresql://postgres@localhost/om"

Needs psycopg (pip install psycopg[binary]) and a database with schema.sql and
dashboard.sql loaded.
"""
import json, math, random, sys, uuid, datetime as dt
import psycopg

def bucket(ms):
    if ms <= 0: return 0
    if ms < 50: return int(ms / 0.25)
    if ms < 200: return 200 + int((ms - 50) / 2)
    if ms < 1000: return 275 + int((ms - 200) / 25)
    return 306

def width(i): return 0.25 if i < 200 else 2 if i < 275 else 25

def nearest_rank(values, p):
    v = sorted(values); return v[max(0, math.ceil(p * len(v)) - 1)]

def summary(values):
    if not values: return None
    return {"p50": nearest_rank(values, .5), "p95": nearest_rank(values, .95), "p99": nearest_rank(values, .99), "max": max(values), "n": len(values)}

def hist(values):
    h = {}
    for v in values: h[bucket(v)] = h.get(bucket(v), 0) + 1
    return [[b, c] for b, c in sorted(h.items())]

random.seed(7)
now = dt.datetime.now(dt.timezone.utc)
rows, truth = [], {"frames": [], "gpu": [], "seconds": 0, "hitch": 0, "by_scene": {}, "sessions_hot_min0": set(), "sessions_min0": set()}
devices = {"iPhone14,7": (16.67, 9.0), "iPhone16,1": (16.67, 6.0), "iPad14,3": (8.33, 4.0)}
for s_i in range(12):
    session = str(uuid.uuid4())
    device = list(devices)[s_i % 3]
    target = 120 if device == "iPad14,3" else 60
    slot = 1000 / target
    active = 0.0
    hot = s_i % 4 == 0
    for w in range(6):                         # six 30-second windows per session
        ended = now - dt.timedelta(minutes=50 - s_i * 2 - w * 0.5)
        scenes = []
        for scene in ("Spark", "Slime"):
            frames, gpu = [], []
            n = random.randint(800, 1700)
            measure_gpu = not (scene == "Slime" and s_i % 3 == 1)   # some windows never measure GPU
            for _ in range(n):
                late = random.random() < (0.04 if scene == "Spark" else 0.01)
                f = slot * (random.choice([2, 3]) if late else random.uniform(0.97, 1.03))
                frames.append(f)
                if measure_gpu: gpu.append(random.gauss(devices[device][1] * (1.6 if scene == "Spark" else 1), 1.2))
            gpu = [max(0.3, g) for g in gpu]
            secs = sum(frames) / 1000
            hitch_ms = sum(f - slot for f in frames if f > 1.5 * slot)
            truth["frames"] += frames; truth["gpu"] += gpu; truth["seconds"] += secs; truth["hitch"] += hitch_ms
            t = truth["by_scene"].setdefault(scene, {"frames": [], "gpu": []}); t["frames"] += frames; t["gpu"] += gpu
            scenes.append({"scene": scene, "target_fps": target, "frames": n, "seconds": round(secs, 2),
                           "fps": round(n / secs, 2), "frame_ms": summary(frames), "frame_hist": hist(frames),
                           "gpu_ms": summary(gpu), "gpu_samples": len(gpu), **({"gpu_hist": hist(gpu)} if gpu else {}),
                           "dropped_frames": sum(f > 1.5 * slot for f in frames), "hitch_ms": round(hitch_ms, 2),
                           "hitch_ms_per_s": round(hitch_ms / secs, 2), "draw_calls": n, "cpu_ms_avg": 2.0, "degraded_share": 0})
            active_start = active
        thermal = "serious" if hot and w >= 2 else "fair"
        if w < 2:   # first minute of drawing (windows starting at 0 s and 30 s)
            truth["sessions_min0"].add(session)
            if thermal in ("serious", "critical"): truth["sessions_hot_min0"].add(session)
        payload = {"schema": 2, "window_s": 30, "target_fps": target, "pacing": "screen",
                   "session_active_start_s": round(active, 2), "session_active_s": round(active + 30, 2),
                   "thermal_now": thermal, "thermal_worst": thermal, "memory_mb_peak": 300,
                   "ended_at": ended.isoformat(), "reports_dropped": 0, "scenes": scenes}
        active += 30
        rows.append(("com.test.app", "perf", session, device, "iOS 18.1", "1.0 (1)" if s_i < 6 else "1.1 (2)", "release", json.dumps(payload), ended))

with psycopg.connect(sys.argv[1]) as conn:
    conn.execute("delete from public.perf_reports")
    with conn.cursor() as cur:
        cur.executemany("insert into public.perf_reports (app, kind, session, device, os, app_version, build, payload, created_at) values (%s,%s,%s,%s,%s,%s,%s,%s,%s)", rows)
    d = conn.execute("select public.octimonitor_overview(24, null)").fetchone()[0]

fails = []
def check(name, got, want, tol):
    ok = got is not None and abs(got - want) <= tol
    print(f"{'PASS' if ok else 'FAIL'} {name}: got {got}, truth {want:.3f} (tolerance {tol:.3f})")
    if not ok: fails.append(name)

o = d["overall"]
p95 = nearest_rank(truth["frames"], .95)
check("overall frame p95 (all frames)", o["frame_p95"], p95, width(bucket(p95)) / 2 + 1e-6)
g95 = nearest_rank(truth["gpu"], .95)
check("overall GPU p95 (measured frames only)", o["gpu_p95"], g95, width(bucket(g95)) / 2 + 1e-6)
check("overall fps", o["fps"], len(truth["frames"]) / truth["seconds"], 0.06)
check("overall hitch ms/s", o["hitch"], truth["hitch"] / truth["seconds"], 0.01)
for sc in d["scenes"]:
    t = truth["by_scene"][sc["scene"]]
    v = nearest_rank(t["frames"], .95); check(f"{sc['scene']} frame p95", sc["frame_p95"], v, width(bucket(v)) / 2 + 1e-6)
    v = nearest_rank(t["gpu"], .95); check(f"{sc['scene']} GPU p95", sc["gpu_p95"], v, width(bucket(v)) / 2 + 1e-6)
    v = nearest_rank(t["gpu"], .50); check(f"{sc['scene']} GPU p50", sc["gpu_p50"], v, width(bucket(v)) / 2 + 1e-6)
m1 = next(x for x in d["session_minutes"] if x["minute"] == 1)
check("minute 1 share of sessions running hot", m1["hot_sessions_share"], 3 / 12, 0.001)
m0 = next(x for x in d["session_minutes"] if x["minute"] == 0)
check("minute 0 share of sessions running hot", m0["hot_sessions_share"], len(truth["sessions_hot_min0"]) / len(truth["sessions_min0"]), 0.001)
print("flags:", {k: o[k] for k in ("frame_p95_exact", "gpu_p95_exact", "target_fps", "mixed_targets")}, "quality:", d["quality"])
if not (o["frame_p95_exact"] and o["gpu_p95_exact"] and o["mixed_targets"]): fails.append("flags")
print("FAILED:", len(fails)); sys.exit(1 if fails else 0)
