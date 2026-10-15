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

# German FireRed / LeafGreen remap tables

The FRLG importer works on FireRed USA 1.0 addresses (LeafGreen goes through
`editions/leafgreen_1_0.lua`). The German "Feuerrote Edition" (SHA-1
`18a3758ceeef2c77b315144be2c3910d6f1f69fe`) and "Blattgrüne Edition"
(`0802d1fb185ee3ed48d9a22afb25e66424076dac`) get `editions/firered_de.lua`
and `editions/leafgreen_de.lua`: every address literal of the importer,
FireRed USA 1.0 address -> German address. Built from pret's `.sym` files of
pokefirered / pokeleafgreen (`make firered leafgreen`, `*.sym`):

    # syms in demap's Lua format (any script that writes the
    # `objs`/`data` blocks of src/import/gba/syms/*.lua will do)
    python3 tools/de/demap.py fr_us.gba fr_de.gba fr_data.lua fr_funcs.lua
    python3 tools/de/textruns.py fr_us.gba fr_de.gba rows.json rows_runs.json
    python3 tools/de/gen_frlg_de_profile.py src/import/gba/editions/firered_de.lua \
        firered_de fr_us.gba fr_de.gba rows_runs.json pokefirered.sym
    # LeafGreen: same with the LG ROMs/syms, then
    python3 tools/de/gen_frlg_de_profile.py src/import/gba/editions/leafgreen_de.lua \
        leafgreen_de lg_us.gba lg_de.gba rows_runs.json pokeleafgreen.sym pokefirered.sym

`textruns.py` lays out runs of adjacent strings one after another (German
keeps the order, only lengths change); the few addresses that need a hand
check are `OVERRIDES` in `gen_frlg_de_profile.py`.
