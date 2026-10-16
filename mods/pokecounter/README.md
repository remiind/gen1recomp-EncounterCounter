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
- PC boxes (option "SEND PC BOXES", on by default): every 2 seconds outside
  battle the storage system is compared with what was sent; changed boxes go
  out as {"t":"box",...}, half a box per packet, for the display's Boxes tab.
- Auto-hunt (F10, option "AUTO-HUNT (F10)"): save in front of a static Pokémon
  (legendary, Snorlax ...), press F10. The game returns to the title screen,
  waits a random number of frames, presses A (B during FireRed's quest log
  replay) until the battle starts and resets again unless the Pokémon is
  shiny, as fast as the PC allows and muted. It never saves. A shiny stops it
  and the shiny pause holds the game; three resets in a row without a battle
  (2 minutes of game time each) stop it too. F10 again stops it by hand.
- Starter / gift hunt (F11): the same loop, but the result is the Pokémon
  that joins the party (starter, Lapras, Eevee, fossils, Castform, Beldum ...).
  Save where the gift is handed over - FireRed/LeafGreen: in Oak's lab facing
  the Poke Ball; Emerald/Ruby/Sapphire: on Route 101 facing Birch's bag - and
  press F11. Between the A presses the hunt presses the direction the player
  faced at F11. Option "STARTER (RSE)" picks the ball on Birch's bag screen
  (LINKS / MITTE / RECHTS). The party needs a free slot; wild battles are not
  counted during a gift hunt.
- Ships inside game.love of the fork's Windows and Android builds.
