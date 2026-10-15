-- Big Bag: raises the number of distinct item slots per bag pocket (and in
-- the PC item storage) for the Gen 3 games. Stack sizes stay vanilla (99 per
-- slot, 999 berries / PC), so everything stays cartridge-shaped except the
-- slot count. A cartridge .sav export keeps the first N slots of each pocket
-- (N = the original size) and leaves the rest out.
return function(mod)
  mod.options:define({
    { key = "slots", label = "SLOTS PER POCKET", type = "choice", default = "999",
      choices = { { "999", "999" }, { "300", "300" }, { "100", "100" } } },
  })

  local VERSIONS = { "emerald", "ruby", "sapphire", "firered", "leafgreen" }

  local function engine(name)
    local ok, m = pcall(require, name)
    return ok and m or nil
  end

  local Profile = engine("src.core.game3.profile")
  local ItemsData = engine("src.core.game3.items_data")
  if not (Profile and ItemsData) then
    mod.log:info("game3 modules not available, nothing changed")
    return
  end

  -- original sizes, kept so a smaller setting never goes below vanilla
  local vanilla = {}

  local function apply()
    local slots = tonumber(mod.options:get("slots")) or 999
    for _, v in ipairs(VERSIONS) do
      local ok, row = pcall(Profile.of, v)
      local bag = ok and type(row) == "table" and row.bag or nil
      if type(bag) == "table" and type(bag.capacity) == "table" then
        if not vanilla[v] then
          local cap = {}
          for k, n in pairs(bag.capacity) do cap[k] = n end
          vanilla[v] = { capacity = cap, pcItems = bag.pcItems }
        end
        for k, n in pairs(vanilla[v].capacity) do bag.capacity[k] = math.max(n, slots) end
        if vanilla[v].pcItems then bag.pcItems = math.max(vanilla[v].pcItems, slots) end
        -- the active bag model copies capacity once; refresh it in place
        if ItemsData._bagModel == bag then
          for k in pairs(ItemsData.CAPACITY) do ItemsData.CAPACITY[k] = nil end
          for k, n in pairs(bag.capacity) do ItemsData.CAPACITY[k] = n end
        end
      end
    end
  end

  apply()
  mod.events:on("game.ready", function() apply() end)
  mod.events:on("map.entered", function() apply() end)
  mod.log:info("bag pockets and PC item storage raised")
end
