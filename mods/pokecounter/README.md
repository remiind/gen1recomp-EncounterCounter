# PokeCounter

Reports every wild encounter of the Gen 3 games to the PokeCounter display,
using the same UDP protocol as the EncounterCounter forks of mGBA and melonDS
(port 4210, JSON `{"t":"enc",...}`, repeated until the display answers `ok`).

- Display discovery: its reply, mDNS (`pokecounter.local`) or broadcast. A fixed
  IP can be set in the mod options ("DISPLAY IP").
- Shiny auto-pause (option "SHINY AUTO-PAUSE", on by default): once the display
  has confirmed the report (at most 1.5 s), the game and its audio stop. Hold
  START or SELECT for 2 seconds to continue. Button presses do not reach the
  game while it is paused.
- Team (option "SEND TEAM", on by default): after each battle and whenever the
  party changes, one packet per Pokémon ({"t":"mon",...}: IVs, EVs, stats,
  nature, ability, item, moves, names from the ROM) for the display's Team tab.
- Ships inside game.love of the fork's Windows and Android builds.
