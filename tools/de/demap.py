#!/usr/bin/env python3
"""Map pokeemerald (US) symbol offsets onto a localized Emerald ROM.

Usage: demap.py EN.gba DE.gba syms_data.lua syms_funcs.lua [needed.txt] [pokebot_lang.yml]

1. Anchors: 16-byte windows that occur exactly once in both ROMs.
2. Segments: runs of anchors with the same EN->DE delta.
3. Per symbol:
   a. "same"  : the symbol's bytes sit unchanged at EN+delta of its segment
   b. "ptr"   : EN pointers to the symbol (literal pools, tables) are mapped
                through their own segments, the DE ROM is read there
   c. "shift" : start maps through a segment but the content differs (text)
4. Report coverage, check against pokebot's hand-made German addresses.
"""
import re
import sys
import json
import bisect
from collections import Counter, defaultdict

import numpy as np

W = 16  # window size


def load_rom(path):
    with open(path, "rb") as f:
        return f.read()


def load_syms(path):
    src = open(path, encoding="utf-8").read()
    objs = re.search(r"objs = \[==\[\n(.*?)\]==\]", src, re.S).group(1).split("\n")
    data = re.search(r"data = \[==\[\n(.*?)\]==\]", src, re.S).group(1)
    rows = []
    for line in data.split("\n"):
        m = re.match(r"(\S+) ([0-9a-f]+) (~?)([0-9a-f]+) ?(\d*)", line)
        if not m:
            continue
        name, off, span, size, obj = m.groups()
        rows.append({
            "name": name, "off": int(off, 16), "size": int(size, 16), "span": span == "~",
            "obj": objs[int(obj) - 1] if obj else None,
        })
    return rows


def window_hashes(rom):
    """64-bit hash of the 16 bytes starting at every offset (last W-1 offsets = 0)."""
    n = len(rom)
    buf = np.frombuffer(rom + b"\0" * 32, dtype=np.uint8)
    a = np.zeros(n, dtype=np.uint64)
    b = np.zeros(n, dtype=np.uint64)
    for s in range(8):
        cnt = (n - s) // 8
        va = np.frombuffer(buf[s:s + cnt * 8].tobytes(), dtype="<u8")
        vb = np.frombuffer(buf[s + 8:s + 8 + cnt * 8].tobytes(), dtype="<u8")
        a[s:s + cnt * 8:8] = va
        b[s:s + cnt * 8:8] = vb
    h = a * np.uint64(0x9E3779B97F4A7C15) ^ (b + np.uint64(0x632BE59BD9B4E019))
    h ^= h >> np.uint64(29)
    h[n - W + 1:] = 0
    return h


def low_entropy(rom, i):
    w = rom[i:i + W]
    return len(set(w)) <= 3


def normalize(rom):
    """Replace every pointer-looking u32 (any alignment, 0x08xxxxxx/0x09xxxxxx with a
    plausible ROM target) by a fixed marker, so tables and scripts whose pointers
    moved still align."""
    a = np.frombuffer(rom, dtype=np.uint8).copy()
    n = len(a)
    b3 = a[3:]
    cand = np.nonzero((b3 == 0x08) | (b3 == 0x09))[0]
    out = a.copy()
    for i in cand.tolist():
        if i + 4 > n:
            continue
        v = int.from_bytes(rom[i:i + 4], "little")
        if 0x08000000 <= v < 0x09000000:
            out[i:i + 4] = (0xEE, 0xEE, 0xEE, 0xEE)
    # Thumb BL/BLX pairs: relative offsets change when code moves
    hw = np.frombuffer(rom[:n // 2 * 2], dtype="<u2")
    hi = (hw[:-1] & 0xF800) == 0xF000
    lo = (hw[1:] & 0xE800) == 0xE800
    for i in np.nonzero(hi & lo)[0].tolist():
        out[i * 2:i * 2 + 4] = (0xBB, 0xBB, 0xBB, 0xBB)
    return out.tobytes()


def find_anchors(en, de):
    he = window_hashes(en)
    hd = window_hashes(de)
    ce = Counter()
    # unique counts via numpy
    ue, ie, ne = np.unique(he, return_index=True, return_counts=True)
    ud, idd, nd = np.unique(hd, return_index=True, return_counts=True)
    uniq_e = dict(zip(ue[ne == 1].tolist(), ie[ne == 1].tolist()))
    uniq_d = dict(zip(ud[nd == 1].tolist(), idd[nd == 1].tolist()))
    pairs = []
    for h, eoff in uniq_e.items():
        if eoff % 4:
            continue
        doff = uniq_d.get(h)
        if doff is None or low_entropy(en, eoff):
            continue
        if en[eoff:eoff + W] != de[doff:doff + W]:
            continue
        pairs.append((eoff, doff))
    pairs.sort()
    return pairs


def build_segments(pairs, min_run=3):
    """Runs of consecutive anchors with an identical delta -> (en_start, en_end, delta)."""
    segs = []
    i = 0
    while i < len(pairs):
        d = pairs[i][1] - pairs[i][0]
        j = i
        while j + 1 < len(pairs) and pairs[j + 1][1] - pairs[j + 1][0] == d:
            j += 1
        if j - i + 1 >= min_run:
            segs.append([pairs[i][0], pairs[j][0] + W, d])
        i = j + 1
    # merge neighbours with equal delta
    merged = []
    for s in segs:
        if merged and merged[-1][2] == s[2]:
            merged[-1][1] = s[1]
        else:
            merged.append(s)
    return merged


class Mapper:
    def __init__(self, en, de, segs):
        self.en, self.de, self.segs = en, de, segs
        self.starts = [s[0] for s in segs]

    def delta_near(self, x):
        """Delta of the segment containing x, else of the nearest segment before it."""
        k = bisect.bisect_right(self.starts, x) - 1
        if k < 0:
            return None, False
        s = self.segs[k]
        return s[2], s[0] <= x < s[1]

    def map_exact(self, x, n, strict=False):
        """x maps if the n bytes there are identical at x+delta (segment before/after)."""
        n = max(1, min(n, 64))
        k = bisect.bisect_right(self.starts, x) - 1
        if k >= 0 and self.segs[k][0] <= x < self.segs[k][1]:
            d = self.segs[k][2]
            if self.en[x:x + n] == self.de[x + d:x + d + n]:
                return x + d
        if strict:
            return None
        for kk in (k, k + 1, k - 1):
            if 0 <= kk < len(self.segs):
                d = self.segs[kk][2]
                y = x + d
                if 0 <= y and self.en[x:x + n] == self.de[y:y + n]:
                    return y
        return None


def u32(rom, i):
    return int.from_bytes(rom[i:i + 4], "little")


def pointer_sites(en):
    """EN ROM: pointer value -> list of 4-aligned offsets holding it."""
    arr = np.frombuffer(en[:len(en) // 4 * 4], dtype="<u4")
    mask = (arr >= 0x08000000) & (arr < 0x09000000)
    idx = np.nonzero(mask)[0]
    sites = defaultdict(list)
    for i, v in zip(idx.tolist(), arr[idx].tolist()):
        sites[v].append(i * 4)
    return sites


def main():
    en_path, de_path, syms_path, funcs_path = sys.argv[1:5]
    needed_path = sys.argv[5] if len(sys.argv) > 5 else None
    pokebot_path = sys.argv[6] if len(sys.argv) > 6 else None
    en, de = load_rom(en_path), load_rom(de_path)
    print("EN", en[0xA0:0xB0], "DE", de[0xA0:0xB0])
    enN, deN = normalize(en), normalize(de)
    pairs = find_anchors(enN, deN)
    segs = build_segments(pairs)
    cov = sum(s[1] - s[0] for s in segs)
    print(f"anchors {len(pairs)}, segments {len(segs)}, EN bytes in segments {cov / len(en):.1%}")
    M = Mapper(enN, deN, segs)
    sites = pointer_sites(en)

    def map_sym(off, size, is_func):
        # a) unchanged bytes inside an aligned segment
        y = M.map_exact(off, size if size else 16, strict=True)
        if y is not None:
            return y, "same"
        # b) via pointers to it
        votes = Counter()
        for v in ((0x08000000 + off, 0x08000000 + off + 1) if is_func else (0x08000000 + off,)):
            for site in sites.get(v, ())[:64]:
                ys = None
                if site >= 8:
                    y8 = M.map_exact(site - 8, 8)
                    if y8 is not None:
                        ys = y8 + 8
                if ys is None:
                    y4 = M.map_exact(site + 4, 8)
                    if y4 is not None:
                        ys = y4 - 4
                if ys is None:
                    continue
                p = u32(de, ys)
                if 0x08000000 <= p < 0x09000000:
                    votes[(p & ~1) - 0x08000000 if is_func else p - 0x08000000] += 1
        if votes:
            (y, n), = votes.most_common(1)
            total = sum(votes.values())
            if n >= max(1, total * 0.6):
                return y, "ptr"
        # c) unchanged bytes next to a segment (only for longer symbols)
        if size >= 16:
            y = M.map_exact(off, size)
            if y is not None:
                return y, "near"
        return None, "missing"

    rows = []
    for path, is_func in ((syms_path, False), (funcs_path, True)):
        for r in load_syms(path):
            if r["name"].startswith("."):
                continue
            r["func"] = is_func
            r["key"] = (is_func, r["obj"], r["name"], r["off"])
            rows.append(r)
    byname = {}
    for r in rows:
        byname.setdefault(r["key"], r)
    rows = list(byname.values())
    found = {}   # name -> (de_off, how)
    for r in rows:
        y, how = map_sym(r["off"], r["size"], r["func"])
        if y is not None:
            found[r["key"]] = (y, how)
    # containers: EN data symbols sorted by offset, for pointer sites inside them
    data_rows = sorted((r for r in rows if not r["func"] and r["size"] > 0), key=lambda r: r["off"])
    cont_rows = sorted((r for r in rows if r["size"] > 0), key=lambda r: r["off"])
    starts = [r["off"] for r in cont_rows]

    def container(site):
        k = bisect.bisect_right(starts, site) - 1
        while k >= 0 and k > bisect.bisect_right(starts, site) - 6:
            r = cont_rows[k]
            if r["off"] <= site < r["off"] + r["size"] and r["key"] in found:
                return r
            k -= 1
        return None

    def drop_outliers():
        """Pointer votes can land on a look-alike elsewhere: drop mappings whose
        EN->DE delta is far from their neighbours' (sorted by EN offset)."""
        srt = sorted((r for r in rows if r["key"] in found), key=lambda r: r["off"])
        deltas = [found[r["key"]][0] - r["off"] for r in srt]
        dropped = 0
        for i, r in enumerate(srt):
            if found[r["key"]][1] not in ("ptr", "ptr2", "near", "win"):
                continue
            lo, hi = max(0, i - 8), min(len(srt), i + 9)
            neigh = sorted(deltas[lo:i] + deltas[i + 1:hi])
            if not neigh:
                continue
            med = neigh[len(neigh) // 2]
            if abs(deltas[i] - med) > 0x4000:
                del found[r["key"]]
                dropped += 1
        return dropped

    for it in range(12):
        if it in (1, 4):
            print(f"outliers dropped: {drop_outliers()}")
        added = 0
        for r in rows:
            if r["key"] in found:
                continue
            off, is_func = r["off"], r["func"]
            votes = Counter()
            for v in ((0x08000000 + off, 0x08000000 + off + 1) if is_func else (0x08000000 + off,)):
                for site in sites.get(v, ())[:64]:
                    c = container(site)
                    if not c:
                        continue
                    ys = found[c["key"]][0] + (site - c["off"])
                    p = u32(de, ys)
                    if 0x08000000 <= p < 0x09000000:
                        votes[(p & ~1) - 0x08000000 if is_func else p - 0x08000000] += 1
            if votes:
                (y, n), = votes.most_common(1)
                if n >= max(1, sum(votes.values()) * 0.6):
                    found[r["key"]] = (y, "ptr2")
                    added += 1
                    continue
        # sequential texts: B follows text A directly in EN -> follows A's DE text
        for i in range(1, len(data_rows)):
            a, b = data_rows[i - 1], data_rows[i]
            if b["key"] in found or a["key"] not in found:
                continue
            aend = a["off"] + a["size"]
            if not (0 <= b["off"] - aend < 4):
                continue
            ya = found[a["key"]][0]
            if en[aend - 1] != 0xFF or a["size"] <= 1:
                # not a text: if A has the same (masked) bytes in DE, B follows at the same distance
                if a["size"] and enN[a["off"]:aend] == deN[ya:ya + a["size"]]:
                    found[b["key"]] = (ya + (b["off"] - a["off"]), "seq")
                    added += 1
                continue
            # DE text of A ends at its 0xFF terminator
            z = de.find(b"\xff", ya)
            if z < 0 or z - ya > 4 * a["size"] + 64:
                continue
            yb = z + 1 + (b["off"] - aend)
            found[b["key"]] = (yb, "seq")
            added += 1
        # gaps of equal length: X between mapped A and B, and B-A is the same in
        # both ROMs (script bytecode keeps its length) -> same distance from A
        allrows = sorted(rows, key=lambda r: (r["off"], r["func"]))
        k = 0
        while k < len(allrows):
            r = allrows[k]
            if r["key"] in found:
                k += 1
                continue
            j = k
            while j < len(allrows) and allrows[j]["key"] not in found:
                j += 1
            a = allrows[k - 1] if k > 0 else None
            b = allrows[j] if j < len(allrows) else None
            if a and b and a["key"] in found and b["key"] in found:
                ya, yb = found[a["key"]][0], found[b["key"]][0]
                if yb - ya == b["off"] - a["off"] and b["off"] - a["off"] < 0x4000:
                    for q in range(k, j):
                        x = allrows[q]
                        found[x["key"]] = (ya + (x["off"] - a["off"]), "gap")
                        added += 1
                elif 0 < yb - ya < 0x20000:
                    # window search between A and B: each symbol's (pointer/BL-masked)
                    # start bytes, longest unique match first, in increasing order
                    lo = ya
                    for q in range(k, j):
                        x = allrows[q]
                        for n in (24, 16, 12, 8):
                            if x["size"] and x["size"] < n:
                                continue
                            pat = enN[x["off"]:x["off"] + n]
                            if len(set(pat)) <= 2:
                                continue
                            hits = []
                            pos = deN.find(pat, lo, yb + n)
                            while pos >= 0 and len(hits) < 2:
                                hits.append(pos)
                                pos = deN.find(pat, pos + 1, yb + n)
                            if len(hits) == 1:
                                found[x["key"]] = (hits[0], "win")
                                lo = hits[0] + 1
                                added += 1
                                break
            k = j + 1
        print(f"pass {it + 1}: +{added}")
        if not added and it >= 4:
            break
    # consistency: pointers stored inside mapped containers (tables, scripts,
    # literal pools) name their target's German address directly; when they
    # agree with each other but not with the current mapping, they win
    def container_votes():
        votes = defaultdict(Counter)
        for c in cont_rows:
            if c["key"] not in found:
                continue
            yc = found[c["key"]][0]
            for site in range((c["off"] + 3) & ~3, c["off"] + c["size"] - 3, 4):
                v = u32(en, site)
                if not (0x08000000 <= v < 0x09000000):
                    continue
                p = u32(de, yc + (site - c["off"]))
                if 0x08000000 <= p < 0x09000000:
                    votes[v][p] += 1
        return votes

    byaddr = defaultdict(list)
    for r in rows:
        byaddr[0x08000000 + r["off"] + (1 if r["func"] else 0)].append(r)
        if r["func"]:
            byaddr[0x08000000 + r["off"]].append(r)
    en_to_de = {}
    for r in rows:
        if r["key"] in found:
            en_to_de.setdefault(r["off"], found[r["key"]][0])

    def skeleton(rom, off):
        """control codes of a Gen 3 string (placeholders, line breaks), up to 0xFF"""
        out = []
        i = off
        while i < off + 1024 and i < len(rom):
            b = rom[i]
            if b == 0xFF:
                break
            if b in (0xFC, 0xFD):
                out.append((b, rom[i + 1]))
                i += 2
                continue
            if b in (0xFA, 0xFB, 0xFE):
                out.append((b,))
            i += 1
        return out, i - off

    def score(r, y):
        """how well German offset y fits the US symbol r (higher is better)"""
        if y is None or y < 0 or y >= len(de):
            return -1.0
        off, n = r["off"], max(4, min(r["size"] or 16, 256))
        if r["func"]:
            return 1.0 if enN[off:off + 16] == deN[y:y + 16] else 0.0
        ptr_ok = ptr_all = 0
        for site in range((off + 3) & ~3, off + n - 3, 4):
            v = u32(en, site)
            if 0x08000000 <= v < 0x09000000:
                t = en_to_de.get((v & ~1) - 0x08000000 if v & 1 else v - 0x08000000)
                if t is not None:
                    ptr_all += 1
                    if u32(de, y + (site - off)) in (0x08000000 + t, 0x08000000 + t + 1):
                        ptr_ok += 1
        eq = sum(1 for a, b in zip(enN[off:off + n], deN[y:y + n]) if a == b) / n
        sc = eq + (2.0 * ptr_ok / ptr_all if ptr_all else 0.0)
        if en[off:off + n].find(b"\xff") >= 0:
            ske, le = skeleton(en, off)
            skd, ld = skeleton(de, y)
            if 0 < ld <= 4 * le + 64:
                sc += 1.0 + (1.0 if ske == skd else 0.0)
        return sc

    fixed = kept_cur = 0
    for v, cnt in container_votes().items():
        (p, n), = cnt.most_common(1)
        if (n < 2 and len(cnt) > 1) or n < sum(cnt.values()) * 0.75:
            continue
        for r in byaddr.get(v, ()):
            want = (p & ~1) - 0x08000000 if r["func"] else p - 0x08000000
            cur = found.get(r["key"])
            if cur is not None and cur[0] == want:
                continue
            is_text = (not r["func"]) and 0 <= en.find(b"\xff", r["off"], r["off"] + max(r["size"], 1)) \
                and ("Text" in r["name"] or r["span"]) and "Script" not in r["name"] and "Movement" not in r["name"]
            if cur is None or (is_text and cur[1] != "same" and len(cnt) == 1) \
                    or score(r, want) > score(r, cur[0]) + 0.05:
                found[r["key"]] = (want, "fix")
                fixed += 1
            else:
                kept_cur += 1
    print(f"container consistency: {fixed} fixed, {kept_cur} kept")

    # aliases: German tables sometimes point one US symbol at two different
    # texts (e.g. separate May / Brendan lines). Reverse lookups need a name at
    # every address a table points to, so add the extra addresses as aliases.
    aliases = []
    for v, cnt in container_votes().items():
        for r in byaddr.get(v, ()):
            if r["func"] or r["key"] not in found:
                continue
            if not (0 <= en.find(b"\xff", r["off"], r["off"] + max(r["size"], 1))
                    and ("Text" in r["name"] or r["span"]) and "Script" not in r["name"]):
                continue
            for p in cnt:
                y = p - 0x08000000
                if y != found[r["key"]][0]:
                    aliases.append({"name": r["name"], "obj": r["obj"], "off": r["off"], "de": y})
    with open("aliases.json", "w") as f:
        json.dump(aliases, f)
    print(f"aliases: {len(aliases)}")

    keyed = {r["key"]: (r["off"], found.get(r["key"], (None, "missing"))[0],
                        found.get(r["key"], (None, "missing"))[1], r["func"]) for r in rows}
    results = {}
    for r in rows:   # by name (and obj:name), data before funcs
        for nm in (r["name"], (r["obj"] + ":" + r["name"]) if r["obj"] else None):
            if nm and (nm not in results or results[nm][3] and not r["func"]):
                results[nm] = keyed[r["key"]]
    with open("rows.json", "w") as f:
        json.dump([{**{k: r[k] for k in ("name", "off", "size", "span", "obj", "func")},
                    "de": found.get(r["key"], (None, None))[0], "how": found.get(r["key"], (None, "missing"))[1]}
                   for r in rows], f)

    def report(names, label):
        c = Counter()
        for n in names:
            c[results[n][2] if n in results else "unknown-name"] += 1
        tot = sum(c.values())
        ok = tot - c["missing"] - c["unknown-name"]
        print(f"{label}: {tot} symbols, mapped {ok} ({ok / max(tot, 1):.1%}) -> {dict(c)}")

    report(list(results), "all symbols")
    if needed_path:
        needed = [l.strip() for l in open(needed_path) if l.strip()]
        needed = [n if n in results else (n.split(":", 1)[1] if ":" in n else n) for n in needed]
        report(needed, "needed by importer")
        with open("missing_needed.txt", "w") as f:
            for n in needed:
                if n not in results or results[n][1] is None:
                    f.write(n + "\n")
    if pokebot_path:
        # pokebot language patch: NAME:\n  D: 0x...
        txt = open(pokebot_path).read()
        good = bad = unk = 0
        badl = []
        for m in re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*):\s*\n((?:\s+[A-Z]: .*\n)+)", txt, re.M):
            name, body = m.group(1), m.group(2)
            dm = re.search(r"\bD: (0x[0-9a-fA-F]+)", body)
            if not dm:
                continue
            addr = int(dm.group(1), 16)
            if not (0x08000000 <= addr < 0x0A000000):
                continue
            # pokebot names are upper-cased pret names
            cands = [k for k in results if k.upper() == name.upper()]
            if not cands:
                unk += 1
                continue
            got = results[cands[0]][1]
            if got is None:
                unk += 1
            elif got in ((addr & ~1) - 0x08000000, addr - 0x08000000):
                good += 1
            else:
                bad += 1
                badl.append((cands[0], hex(addr), hex(got + 0x08000000), results[cands[0]][2]))
        print(f"pokebot check (ROM symbols): correct {good}, wrong {bad}, not mapped/unknown {unk}")
        for b in badl[:20]:
            print("  WRONG", b)
    with open("mapping.json", "w") as f:
        json.dump({k: [v[0], v[1], v[2], v[3]] for k, v in results.items()}, f)


if __name__ == "__main__":
    main()
