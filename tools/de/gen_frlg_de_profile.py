#!/usr/bin/env python3
"""German FireRed / LeafGreen address remap for the FRLG importer.

The FRLG importer is written against FireRed USA 1.0 addresses; LeafGreen
runs through editions/leafgreen_1_0.lua (FR address -> LG address). This
script writes the same kind of table for a German edition:

    FR US 1.0 address -> (LG US 1.0 address ->) German address

Usage:
  gen_frlg_de_profile.py OUT.lua EDITION_ID US.gba DE.gba rows.json US.sym [FR.sym]

  rows.json  demap.py output for US.gba -> DE.gba (symbols of US.sym),
             refined by textruns.py
  US.sym     pret symbols of the US ROM that DE is a translation of
  FR.sym     only for LeafGreen: pret FireRed symbols, the keys of the table
             are FireRed addresses (looked up by symbol name, like
             tools/gen_leafgreen_profile.py)

Every ROM address literal in the FRLG importer files is mapped:
  1. the 16 bytes at the address are unchanged next to an anchor segment
     -> that position (exact, also inside long data)
  2. else the enclosing symbol's German start + the same offset
Addresses only; no ROM content is written.
"""
import bisect
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import demap  # noqa: E402

B = 0x08000000
ROOT = Path(__file__).resolve().parents[2]
FILES = ["src/import/gba/versions_frlg.lua", "src/import/gba/versions_text.lua"] + [
    "src/import/gba/" + f + ".lua" for f in (
        "tileset_anim_pack", "battle_chrome_extract", "pokedex_chrome_extract",
        "seagallop_extract", "door_anim_extract", "text_chrome_extract",
        "help_extract", "quest_log_extract", "object_interactions_extract",
        "weather_extract", "battle_anim_extract", "extract_naming")]


# Hand-checked addresses the byte/symbol mapping cannot place, per edition
# (FireRed USA 1.0 address -> German address).
OVERRIDES = {
    # Test_Text_Empty: a lone EOS after Test_Text_ThisIsACoordEvent, 4-aligned
    "firered_de": {
        0x1C55C8: 0x1C971C,
        # sText_S / sText_IES: English plural suffixes, the German ROM has none
        0x3A72A0: 0x1C971C, 0x3A72A2: 0x1C971C,
        0x415D38: 0x415B18,  # gText_PickOk (demap one byte late)
        0x415FB3: 0x415D64,  # gText_NextDataCancel
        0x3FD8A2: 0x3FD78A,  # sText_EnigmaBerry
    },
    # same symbols in the German LeafGreen (keys stay FireRed USA addresses)
    "leafgreen_de": {
        0x1C55C8: 0x1C96F8,
        0x3A72A0: 0x1C96F8, 0x3A72A2: 0x1C96F8,
        0x415D38: 0x415954,
        0x415FB3: 0x415BA0,
        0x3FD8A2: 0x3FD5C6,
        0x489887: 0x487008,  # sText_MysteryGiftAlteringCave (no LG symbol hit)
    },
}


def literals():
    values = set()
    for rel in FILES:
        for line in (ROOT / rel).read_text().splitlines():
            line = re.sub(r'"[^"\n]*"|\'[^\'\n]*\'', "", line.split("--")[0])
            for lit in re.findall(r"0x[0-9A-Fa-f]+", line):
                v = int(lit, 16)
                if 0x10000 <= v < 0x1000000 or B < v < B + 0x1000000:
                    values.add(v)
    return sorted(values)


def load_sym(path):
    out = []
    for line in open(path):
        p = line.split()
        if len(p) < 4:
            continue
        a = int(p[0], 16)
        if B <= a < B + 0x1000000 and not p[3].startswith((".", "$")):
            out.append((a - B, int(p[2], 16), p[3]))
    out.sort()
    return out


class Index:
    """Innermost symbol containing an offset (size-0 labels span to the next)."""

    def __init__(self, rows):
        starts = sorted(set(r[0] for r in rows))
        self.rows = []
        for off, size, name in rows:
            if size == 0:
                k = bisect.bisect_right(starts, off)
                size = (starts[k] if k < len(starts) else off + 4) - off
            self.rows.append((off, size, name))
        self.rows.sort()
        self.starts = [r[0] for r in self.rows]

    def find(self, off):
        k = bisect.bisect_right(self.starts, off) - 1
        best = None
        while k >= 0 and k > bisect.bisect_right(self.starts, off) - 400:
            s, size, name = self.rows[k]
            if s <= off < s + size and (best is None or size < best[1]):
                best = (s, size, name)
            k -= 1
        return best


def main():
    out_path, edition, us_path, de_path, rows_path, us_sym = sys.argv[1:7]
    fr_sym = sys.argv[7] if len(sys.argv) > 7 else None
    en, de = demap.load_rom(us_path), demap.load_rom(de_path)
    segs = demap.build_segments(demap.find_anchors(demap.normalize(en), demap.normalize(de)))
    M = demap.Mapper(en, de, segs)
    rows = json.load(open(rows_path))
    de_of = {}
    for r in rows:
        if r["de"] is not None:
            de_of.setdefault((r["name"], r["off"]), r["de"])
    us_idx = Index(load_sym(us_sym))
    # keys are FireRed addresses; for LeafGreen translate FR -> LG by symbol name
    fr_idx = Index(load_sym(fr_sym)) if fr_sym else None
    # local names repeat across objects (sBg_Pal ...); FR and LG keep almost the
    # same layout, so the LG copy nearest the FR address is the same object's
    lg_by_name = {}
    if fr_sym:
        for off, size, name in us_idx.rows:
            lg_by_name.setdefault(name, []).append(off)
    aliases = {"sFlames_Pal": "sLeaves_Pal", "sFlames_Gfx": "sLeaves_Gfx", "sBlankFlames_Gfx": "sStreak_Gfx"}

    lines = [f"-- Generated by tools/de/gen_frlg_de_profile.py ({edition}).",
             "-- Addresses only; no ROM content. FireRed USA 1.0 address -> German address.",
             "return {"]
    stats = {"exact": 0, "symbol": 0, "missing": 0}
    missing = []
    overrides = OVERRIDES.get(edition, {})
    for value in literals():
        addr = value - B if value >= B else value
        if addr in overrides:
            y = overrides[addr]
            stats["override"] = stats.get("override", 0) + 1
            lines.append(f"  [0x{value:X}] = 0x{(y if value < B else y + B):X}, -- override")
            continue
        # FireRed address -> address in the US ROM of this edition
        us = addr
        label = ""
        if fr_idx:
            hit = fr_idx.find(addr)
            if not hit:
                missing.append((value, "no FR symbol"))
                stats["missing"] += 1
                continue
            s, size, name = hit
            cands = lg_by_name.get(aliases.get(name, name))
            lg = min(cands, key=lambda o: abs(o - s)) if cands else None
            if lg is None:
                missing.append((value, "no LG symbol " + name))
                stats["missing"] += 1
                continue
            us = lg + (addr - s)
        y = M.map_exact(us, 16)
        how = "exact"
        hit = us_idx.find(us)
        sym_y = de_of[(hit[2], hit[0])] + (us - hit[0]) if hit and (hit[2], hit[0]) in de_of else None
        if y is not None and sym_y is not None and y != sym_y:
            # a byte match far outside the symbol's German copy is a look-alike
            # (same palette/graphics elsewhere): trust the symbol
            start = de_of[(hit[2], hit[0])]
            if not (start <= y < start + 2 * max(hit[1], 16) + 64):
                y = None
        if y is None and sym_y is not None:
            y, how, label = sym_y, "symbol", hit[2]
        if y is None:
            missing.append((value, "unmapped"))
            stats["missing"] += 1
            continue
        stats[how] += 1
        mapped = y if value < B else y + B
        if not label:
            hit = us_idx.find(us)
            label = hit[2] if hit else "?"
        lines.append(f"  [0x{value:X}] = 0x{mapped:X}, -- {label} ({how})")
    lines.append("}")
    Path(out_path).write_text("\n".join(lines) + "\n")
    print(f"{out_path}: {stats}")
    for v, why in missing[:40]:
        print(f"  MISSING 0x{v:X}: {why}")


if __name__ == "__main__":
    main()
