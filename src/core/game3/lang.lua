-- EncounterCounter fork: the game language a save and its Pokémon carry.
-- pokeemerald/include/constants/global.h:20  LANGUAGE_ENGLISH 2, LANGUAGE_GERMAN 5
-- The German Smaragd dump plays as a German game, so Pokémon caught, hatched or
-- received in it are German (DEU in PKHeX / HOME), like on the cartridge.
local Lang = { JAPANESE = 1, ENGLISH = 2, FRENCH = 3, ITALIAN = 4, GERMAN = 5, SPANISH = 7 }

function Lang.game()
  local okV, GameVersion = pcall(require, "src.core.GameVersion")
  if okV and GameVersion.get and GameVersion.get() ~= "emerald" then return Lang.ENGLISH end
  local Syms = package.loaded["src.import.gba.syms"]
  if Syms and Syms.buildOf and Syms.buildOf("emerald") == "emerald_de" then return Lang.GERMAN end
  return Lang.ENGLISH
end

return Lang
