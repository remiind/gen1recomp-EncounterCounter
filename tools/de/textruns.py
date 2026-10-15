#!/usr/bin/env python3
"""Second pass over demap.py's rows.json for runs of strings.

pret keeps code-referenced texts as consecutive `const u8 x[] = _("...")`
arrays; a localized ROM keeps the same arrays in the same order, only the
lengths change. demap places most of them, but a literal-pool vote can move
one onto its neighbour. For every run of directly adjacent EOS-terminated
symbols this pass picks the anchor whose sequential walk (string after
string) agrees best with the placeholders of the US strings, and lays the
whole run out from it.

Usage: textruns.py US.gba DE.gba rows.json OUT.json
"""
import json
import sys
from collections import Counter


def skeleton(rom, off, limit=1500):
    """placeholders/control codes of one string, None if it does not end"""
    out = []
    i = off
    while i < off + limit and i < len(rom):
        b = rom[i]
        if b == 0xFF:
            return Counter(out), i - off + 1
        if b in (0xFC, 0xFD):
            out.append((b, rom[i + 1]))
            i += 2
            continue
        i += 1
    return None, 0


def main():
    en_path, de_path, rows_path, out_path = sys.argv[1:5]
    en, de = open(en_path, "rb").read(), open(de_path, "rb").read()
    rows = json.load(open(rows_path))
    texts = []
    for r in rows:
        off, size = r["off"], r["size"]
        if r["func"] or not (1 <= size <= 1024) or off + size > len(en):
            continue
        body = en[off:off + size]
        if body[-1] != 0xFF or 0xFF in body[:-1]:
            continue
        texts.append(r)
    texts.sort(key=lambda r: r["off"])
    # unique symbol per offset (aliases share the row's mapping)
    by_off = {}
    for r in texts:
        by_off.setdefault(r["off"], []).append(r)
    offs = sorted(by_off)
    runs, cur = [], [offs[0]] if offs else []
    for a, b in zip(offs, offs[1:]):
        if b == a + by_off[a][0]["size"]:
            cur.append(b)
        else:
            runs.append(cur)
            cur = [b]
    if cur:
        runs.append(cur)

    def match(o, y):
        if y is None or not (0 <= y < len(de)):
            return 0
        se, le = skeleton(en, o)
        sd, ld = skeleton(de, y)
        if sd is None or ld > 4 * le + 64:
            return 0
        return 1 if se == sd else 0

    def layout_score(run, ys):
        """placeholder matches, minus places where the run does not go
        forward string by string (a German run keeps the US order)"""
        sc = sum(match(o, y) for o, y in zip(run, ys))
        prev = None
        for y in ys:
            if y is not None and prev is not None and y <= prev:
                sc -= 1
            if y is not None:
                prev = y
        return sc

    changed = checked = 0
    for run in runs:
        if len(run) < 2:
            continue
        cur_y = [by_off[o][0]["de"] for o in run]
        base_score = layout_score(run, cur_y)
        best = (base_score, None)
        covered = set()   # (index, y) already part of a tried layout
        for k, yk in enumerate(cur_y):
            if yk is None or (k, yk) in covered or not match(run[k], yk):
                continue
            pos = [None] * len(run)
            pos[k] = yk
            ok = True
            for j in range(k + 1, len(run)):      # forward
                _, ln = skeleton(de, pos[j - 1])
                if not ln:
                    ok = False
                    break
                pos[j] = pos[j - 1] + ln
            for j in range(k - 1, -1, -1):        # backward
                end = pos[j + 1] - 1               # EOS of string j
                if end < 1 or de[end] != 0xFF:
                    ok = False
                    break
                p = end - 1
                while p >= 0 and de[p] != 0xFF and end - p < 1500:
                    p -= 1
                pos[j] = p + 1
            if not ok:
                continue
            covered.update(enumerate(pos))
            sc = layout_score(run, pos)
            if sc > best[0]:
                best = (sc, pos)
        checked += 1
        if best[1] is None:
            continue
        for o, y in zip(run, best[1]):
            for r in by_off[o]:
                if r["de"] != y:
                    r["de"], r["how"] = y, "run"
                    changed += 1
    json.dump(rows, open(out_path, "w"))
    print(f"runs {checked}, rows changed {changed}")


if __name__ == "__main__":
    main()
