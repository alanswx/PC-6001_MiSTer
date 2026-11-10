#!/usr/bin/env python3
"""Game list: how to load each known tape, keyed by the CRC32 of the whole file (what the core downloads).

Scans directories of .p6/.cas/.p6t images and reads what their names and readmes say:
  - {mXpY ...} tags (Neo Kobe): mode X, pages Y, then keys: "clear ..." is typed before CLOAD; "mon r-0 G9000",
    "b exec &H9000" are the command (monitor tapes). {m6}: N66SR-BASIC.  [Mode X, Page Y] (TOSEC) the same.
  - the directory: MAME's pc6001mk2_cass / pc6001mk2sr_cass lists are mkII / SR tapes.
  - a Neo Kobe readme's machine list (動作環境 / 対応機種): the first machine it names.
  - "(mkII)" in a name; a directory named for a machine (6001, 6001mkII, 6001mkIISR, 6601).
  - the Mister Friendly set's tags: {p2}, {p2 - clear 10,&hd5ff}, {mode5p2 clear100,&h8fff mon R0 G9000}.
tools/gamelist_fixes.csv (crc32 or file name, then the fields to replace) wins over all of these: testers' notes.

  ./gamelist.py --out gamelist.csv --svh ../rtl/pc6001_gamelist.svh "PC6001 Mister Friendly v2" ../refs/software \\
      ../releases/tester/games

Where copies disagree the most pages win (fewer only saves memory; a tape that needs exactly N is in the
fixes), and otherwise the first directory given (gamelist_conflicts.txt lists them): put the tested set first.

Model: the earliest machine the tape runs on (60, mk2, 66, sr). Mode: 1 N60-BASIC 16 KB, 2 N60-BASIC 32 KB, 3/4
N60 Extended BASIC, 5 N60m-BASIC, 6 N66SR-BASIC. Append: hex bytes played after the image (a dump missing its
last bytes). Empty fields: the core's own guesses (rtl/tape_auto.sv).
"""
import argparse, csv, os, re, sys, zlib

EXTS = (".p6", ".cas", ".p6t")
FIELDS = ["crc32", "size", "model", "mode", "pages", "before", "command", "append", "hint", "title", "file", "copies"]
MODELS = ["60", "mk2", "66", "sr"]


def crc32(path):
    with open(path, "rb") as f:
        return "%08x" % (zlib.crc32(f.read()) & 0xFFFFFFFF), os.path.getsize(path)


def readme_model(folder):
    """The first machine a Neo Kobe readme in the title's folder names, or ''."""
    for root, _, files in os.walk(folder):
        for n in files:
            if not n.lower().endswith(".txt"):
                continue
            try:
                t = open(os.path.join(root, n), "rb").read().decode("shift_jis", "ignore")
            except OSError:
                continue
            m = re.search(r"(動作環境|対応機種)(.{0,200})", t, re.S)
            if not m:
                continue
            s = m.group(2).replace("Ｐ", "P").replace("Ｃ", "C").replace("－", "-")
            s = re.sub(r"mk2|mkⅡ", "mkII", s, flags=re.I)
            found = []
            for k, pat in (("60", r"PC-6001(?!\s*mkII)(?![0-9A-Z])"), ("mk2", r"PC-6001\s*mkII(?!\s*SR)"),
                           ("66", r"PC-6601(?!\s*SR)"), ("sr", r"PC-6001\s*mkII\s*SR|PC-6601\s*SR")):
                if re.search(pat, s, re.I):
                    found.append(k)
            if found:
                return min(found, key=MODELS.index)
    return ""


def keys(words):
    """Tag words after the mode and pages -> (before CLOAD, command). Keys are joined with \\n (Return)."""
    before, cmd = [], []
    i = 0
    while i < len(words):
        w = words[i]
        m = re.match(r"clear(\S*)$", w, re.I)
        if m:
            arg = m.group(1) or (words[i + 1] if i + 1 < len(words) else "")
            (cmd if cmd else before).append("clear " + arg); i += 1 if m.group(1) else 2
        elif w.lower() == "exec" and i + 1 < len(words):
            cmd.append("exec " + words[i + 1]); i += 2
        else:
            cmd.append(w); i += 1
    return "\\n".join(before), "\\n".join(cmd)


# a directory naming the machine (the Mister Friendly set: @Tapes/6001mkII/...)
FOLDER = [(r"6001\s*m[kl]\s*(ii|2)\s*sr|6601\s*sr|66sr", "sr"), (r"6001\s*m[kl]\s*(ii|2)", "mk2"),
          (r"6601", "66"), (r"6001", "60")]


def from_name(path):
    e = {}
    name = os.path.basename(path)
    m = re.search(r"\{([^}]*)\}", name)
    tag = m.group(1) if m else ""
    tag = re.sub(r"\bmode ?(\d) ?,? ?page ?(\d)", r"m\1p\2", tag, flags=re.I)
    tag = re.sub(r"\s+-\s+", " ", tag).replace("16KB", "").strip()
    m = re.match(r"(?:m(\d))?(?:p(\d))?(?:\s+(.*))?$", tag, re.I)
    if tag and m and (m.group(1) or m.group(2)) and not re.search(r"\bm\d", m.group(3) or "", re.I):
        e["mode"], e["pages"] = m.group(1) or "", m.group(2) or ""
        e["before"], e["command"] = keys((m.group(3) or "").split())
    else:
        m = re.search(r"\[Mode ?(\d) ?, ?Page ?(\d)\]", name)
        if m:
            e["mode"], e["pages"] = m.group(1), m.group(2)
    mode = e.get("mode", "")
    if mode == "6":
        e["model"] = "sr"
    elif mode in ("3", "4", "5"):
        e["model"] = "mk2"
    p = path.replace("\\", "/")
    if "pc6001mk2sr_cass" in p:
        e.setdefault("model", "sr")
    elif "pc6001mk2_cass" in p or re.search(r"\(mkii\)", name, re.I):
        e.setdefault("model", "mk2")
    for d in p.split("/")[:-1]:
        for pat, model in FOLDER:
            if re.fullmatch(pat, d, re.I):
                e["model"] = model
                break
    return e


def title_of(path):
    p = path.replace("\\", "/")
    m = re.search(r"/NEC PC-6001/([^/]+)/", p)
    t = m.group(1) if m else os.path.splitext(os.path.basename(p))[0]
    return re.sub(r"\s*\{[^}]*\}", "", t).strip()


def script(g):
    """The keys to type after the mode and pages (rtl/tape_auto.sv, as a P6T footer's): 0Dh Return, 0Ah Return
    then wait for the tape relay to close and open (a command that loads). Empty: the core's own command."""
    before = [t for t in g.get("before", "").split("\\n") if t]
    cmd = [t for t in g.get("command", "").split("\\n") if t]
    # MON, R0 alone is the core's own command for a monitor tape (which adds G and the start for Hudson's loader)
    if not before and (not cmd or [t.lower().replace("-", "") for t in cmd] == ["mon", "r0"]):
        return b""
    if not cmd:
        cmd = ["CLOAD", "RUN"]
    out = b""
    for t in before + cmd:
        loads = re.fullmatch(r"cload.*|r-?0?", t, re.I) is not None
        out += t.upper().encode("ascii") + (b"\x0a" if loads else b"\x0d")
    assert len(out) <= 64, (g["file"], out)
    return out


def hint_lines(g):
    """Up to two lines of 24 characters, upper case."""
    words, lines = g.get("hint", "").upper().split(), [""]
    for w in words:
        if len(lines[-1]) + len(w) + (1 if lines[-1] else 0) > 24:
            lines.append("")
        lines[-1] += (" " if lines[-1] else "") + w
    assert len(lines) <= 2, (g["file"], lines)
    return [l for l in lines if l]


def write_svh(path, games):
    """Entries {crc32, model, mode, pages, record} and a byte pool of records: the script, 00h, the hint (lines
    joined by 0Ah), 00h, the number of bytes to append, the bytes."""
    code = {"60": 1, "mk2": 2, "66": 3, "sr": 4}
    ents, pool = [], bytearray(b"\0")
    for g in sorted(games, key=lambda g: g["crc32"]):
        model, mode, pages = code.get(g.get("model", ""), 0), int(g.get("mode") or 0), int(g.get("pages") or 0)
        sc, hl = script(g), hint_lines(g)
        app = bytes.fromhex(g.get("append", "") or "")
        rec = 0
        if sc or hl or app:
            rec = len(pool)
            pool += sc + b"\0" + "\n".join(hl).encode("ascii") + b"\0" + bytes([len(app)]) + app
        if model or mode or pages or rec:
            ents.append((int(g["crc32"], 16), model, mode, pages, rec))
    assert len(ents) < 1024 and len(pool) < 4096, (len(ents), len(pool))
    with open(path, "w") as f:
        f.write("// Generated by tools/gamelist.py from the tape collections' names and readmes and\n"
                "// tools/gamelist_fixes.csv. Do not edit.\n")
        f.write(f"localparam GL_N = {len(ents)};\n")
        f.write("// {crc32, model (1 PC-6001, 2 mkII, 3 PC-6601, 4 mkIISR), mode, pages, record}\n")
        f.write("function automatic [52:0] gl_entry(input [9:0] i);\n\tcase (i)\n")
        for n, (crc, model, mode, pages, rec) in enumerate(ents):
            f.write(f"\t\t10'd{n}: gl_entry = {{32'h{crc:08x}, 3'd{model}, 3'd{mode}, 3'd{pages}, 12'd{rec}}};\n")
        f.write("\t\tdefault: gl_entry = 53'd0;\n\tendcase\nendfunction\n")
        f.write("function automatic [7:0] gl_byte(input [11:0] a);\n\tcase (a)\n")
        for n, b in enumerate(pool):
            if b:
                f.write(f"\t\t12'd{n}: gl_byte = 8'h{b:02x};\n")
        f.write("\t\tdefault: gl_byte = 8'h00;\n\tendcase\nendfunction\n")
    print(f"{path}: {len(ents)} entries, {len(pool)} bytes of records")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="gamelist.csv")
    ap.add_argument("--svh", help="also write the core's list (rtl/pc6001_gamelist.svh)")
    ap.add_argument("--fixes", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "gamelist_fixes.csv"))
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args()

    games, readmes, conflicts = {}, {}, []
    for d in a.dirs:
        for root, _, files in os.walk(d):
            for n in sorted(files):
                if not n.lower().endswith(EXTS) or n.startswith("._"):
                    continue
                path = os.path.join(root, n)
                crc, size = crc32(path)
                e = from_name(path)
                m = re.search(r"^(.*/NEC PC-6001/[^/]+)/", path.replace("\\", "/"))
                if m and "model" not in e:
                    if m.group(1) not in readmes:
                        readmes[m.group(1)] = readme_model(m.group(1))
                    if readmes[m.group(1)]:
                        e["model"] = readmes[m.group(1)]
                g = games.setdefault(crc, {"crc32": crc, "size": size, "title": title_of(path), "file": n, "copies": 0})
                g["copies"] += 1
                # a tag or a list from another copy fills what this one lacks; the first directory given wins
                for k, v in e.items():
                    if v and not g.get(k):
                        g[k] = v
                    elif v and k == "pages" and v > g[k]:
                        g[k] = v          # more pages only costs free memory
                    elif v and g[k] != v and k != "pages":
                        conflicts.append(f"{crc} {k}: {g[k]!r} ({g['file']}) vs {v!r} ({path})")

    if os.path.exists(a.fixes):
        for f in csv.DictReader(open(a.fixes, encoding="utf-8")):
            hit = [g for g in games.values() if f["match"] in (g["crc32"], g["file"])]
            if not hit:
                print(f"fix matches nothing: {f['match']}", file=sys.stderr)
            for g in hit:
                g.update({k: v for k, v in f.items() if k in FIELDS and v})

    with open(a.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, FIELDS)
        w.writeheader()
        for g in sorted(games.values(), key=lambda g: (g["title"].lower(), g["file"].lower())):
            w.writerow({k: g.get(k, "") for k in FIELDS})
    with open(os.path.splitext(a.out)[0] + "_conflicts.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(conflicts) + "\n")
    if a.svh:
        write_svh(a.svh, games.values())
    n = len(games)
    have = lambda k: sum(1 for g in games.values() if g.get(k))
    print(f"{n} tapes; model {have('model')}, mode {have('mode')}, pages {have('pages')}, "
          f"before {have('before')}, command {have('command')}, hint {have('hint')}")


if __name__ == "__main__":
    main()
