# German Emerald symbol table (EncounterCounter fork)

`src/import/gba/syms/emerald_de.lua` and `emerald_de_funcs.lua` are the US
pokeemerald symbol tables located in the German "Smaragd-Edition"
(SHA-1 `61c2eb2b380b1a75f0c94b767a2d4c26cd7ce4e3`). pret does not build the
German Emerald, so the addresses were found by comparing the two ROMs:

1. anchors: 16-byte windows unique in both ROMs, with ROM pointers and Thumb
   BL offsets masked, grouped into segments of equal EN->DE delta
2. per symbol: unchanged bytes inside a segment, pointers to it from mapped
   code/data, text chains (a string ends at 0xFF, the next follows), gaps of
   equal length between mapped neighbours, windowed start-byte search
3. outliers (delta far from the neighbours') are dropped and re-derived;
   pointers stored in mapped tables win for texts; extra German targets of
   one US text become alias rows so reverse lookups find a name
4. `overrides.json`: localized data found by hand (contest result titles,
   credits table length, the "ENDE" screen tilemap that replaces THE END)

Regenerate (needs both ROMs; nothing ROM-derived beyond addresses is stored):

    python3 tools/de/demap.py us.gba de.gba src/import/gba/syms/emerald.lua \
        src/import/gba/syms/emerald_funcs.lua
    python3 tools/de/gen_de_syms.py src/import/gba/syms src/import/gba/syms \
        rows.json emerald_de tools/de/overrides.json
