#!/usr/bin/env python3
"""Tape corpus sweep (tape standard: "Machine simulation ... time to the game's title at Normal, turbo").

Loads every tape in a directory the way a user would: answers "How Many Pages?" from the file name ({m2p3} or
[Mode 2, Page 3]), with 32 KB (the OSD default; "Mode 1" tapes such as Outlaw are larger than 16 KB), types CLOAD, types RUN when the motor stops, and
ends once the motor has stayed off for 10 s. Writes <out>/<speed>/<tape>/last.png, <out>/results.csv and one
contact sheet per speed.

  ./tape_sweep.py --out ../runs/sweep ../releases/tester/games/PC6001/MAME ../releases/tester/games/PC6001/TOSEC
"""
import argparse, csv, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

SIM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "obj_dir_headless", "Vtop")
# a turbo factor other than 7 (the default build) needs its own build: make TURBO=N headless -> obj_dir_headless_tN
SIMS = {f"{n}x": os.path.join(os.path.dirname(os.path.abspath(__file__)), f"obj_dir_headless_t{n}", "Vtop")
        for n in (2, 3, 4, 5, 6)}
ROM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rom")

# Typed before CLOAD, from the tape's instructions
SETUP = {"The Tank": "CLEAR 10,&HD7FF\\n{WAIT30}"}
# Page counts the file name gets wrong: Dual's line 30 is SCREEN 2,2,2 (?FC Error with 1 page); Steal's line 5
# CLEARs up to F9FF (?FC Error with 2 or 3 pages); Seven EXECs machine code inside its BASIC text (resets the
# machine with 1 page)
PAGES = {"Dual": 2, "Steal": 1, "Seven": 2}
# Tapes that need 16 KB (Dual: ?FC Error in 5 with 32 KB; Kaiten and Nostro hang at RUN with 32 KB)
RAM16 = ("Dual", "Kaiten", "Nostro")


def mode_page(name):
    m = re.search(r"\{m(\d)p(\d)", name) or re.search(r"Mode ?(\d) ?, ?Page ?(\d)", name)
    return (int(m.group(1)), int(m.group(2))) if m else (2, 2)


def run(job):
    path, speed, out = job
    name = os.path.splitext(os.path.basename(path))[0]
    mode, pages = mode_page(name)
    pages = next((v for k, v in PAGES.items() if name.startswith(k)), pages)
    d = os.path.join(out, speed, re.sub(r"[^A-Za-z0-9._-]+", "_", name))
    os.makedirs(d, exist_ok=True)
    done = os.path.join(d, "tape.txt")
    if os.path.exists(done):            # resume: this run finished before
        out_s, code = open(done).read(), 0
    else:
        out_s, code = None, 0
    # the whole tape at 100 bytes/s (700 at 7x), half again, plus a minute: a load that never ends stops here
    play = os.path.getsize(path) * 60 // 100 // (1 if speed == "Normal" else int(speed.rstrip("x")))
    cap = play * 3 // 2 + 6000
    setup = next((v for k, v in SETUP.items() if name.startswith(k)), "")
    args = [SIMS.get(speed, SIM), "--quiet", "--rom-dir", ROM, "--out", d, "--tape", path,
            "--type", f"155:{pages}\\n{{WAIT30}}{setup}CLOAD\\n", "--after-motor", "RUN\\n",
            "--nudge", "300", "--stop-after-motor", "600", "--stop-at-frame", str(cap)]
    if speed != "Normal":
        args.append("--tape-turbo")
    if name.startswith(RAM16):
        args.append("--ram16k")
    if out_s is None:
        r = subprocess.run(args, capture_output=True, text=True)
        out_s, code = r.stdout, r.returncode
        if code == 0 and "TAPE " in out_s:
            open(done, "w").write(out_s)
    m = re.search(r"TAPE (.*)", out_s)
    f = dict(kv.split("=") for kv in m.group(1).split()) if m else {}
    return {"tape": name, "speed": speed, "mode": mode, "pages": pages, "exit": code, **f, "dir": d}


def sheet(rows, path):
    from PIL import Image, ImageDraw
    w, h = 320, 240 + 14
    cols = 6
    img = Image.new("RGB", (cols * w, ((len(rows) + cols - 1) // cols) * h), (255, 255, 255))
    dr = ImageDraw.Draw(img)
    for i, r in enumerate(rows):
        x, y = (i % cols) * w, (i // cols) * h
        p = os.path.join(r["dir"], "last.png")
        if os.path.exists(p):
            img.paste(Image.open(p).convert("RGB").resize((320, 240)), (x, y + 14))
        dr.text((x + 2, y + 1), f"{i + 1}. {r['tape'][:48]}", fill=(0, 0, 0))
    img.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--speeds", default="7x,Normal")
    ap.add_argument("--only", help="file with tape names (one per line, no extension) to run")
    ap.add_argument("--jobs", type=int, default=13)
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args()
    tapes = sorted(os.path.join(d, f) for d in a.dirs for f in os.listdir(d) if f.lower().endswith((".cas", ".p6")))
    if a.only:
        want = {l.strip() for l in open(a.only) if l.strip()}
        tapes = [t for t in tapes if os.path.splitext(os.path.basename(t))[0] in want]
    jobs = [(t, s, a.out) for s in a.speeds.split(",") for t in tapes]
    rows = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for r in ex.map(run, jobs):
            rows.append(r)
            print(f"{r['speed']:6} {r.get('frames', '?'):>6} frames  {r['tape']}", flush=True)
    keys = ["tape", "speed", "mode", "pages", "exit", "end_frame", "frames", "motor_on_frames", "motor_stops", "nudges", "pos",
            "len", "dir"]
    with open(os.path.join(a.out, f"results_{a.speeds.replace(',', '_')}.csv"), "w", newline="") as fh:
        wr = csv.DictWriter(fh, keys, extrasaction="ignore")
        wr.writeheader()
        wr.writerows(rows)
    for s in a.speeds.split(","):
        sheet([r for r in rows if r["speed"] == s], os.path.join(a.out, f"sheet_{s}.png"))


if __name__ == "__main__":
    sys.exit(main())
