-- PokeCounter: reports wild encounters to the PokeCounter display and pauses
-- the game on a shiny.
--
-- Same UDP protocol as the EncounterCounter emulators (mGBA, melonDS):
--   {"t":"enc","sp":263,"lv":3,"g":"M","shiny":false,"pid":...,"eid":...,
--    "ivs":...,"ab":53,"it":0,"tsv":...,"src":"BPED"}
-- to port 4210 of the display. The display is found by its reply (learned
-- address), an mDNS query for pokecounter.local, or broadcast. Each report is
-- repeated until the display answers with "ok" (eid makes repeats harmless).
--
-- Shiny: the game keeps running until the display confirmed the report (or
-- 1.5 s passed, so its melody plays right away), then the simulation and the
-- audio stop. Holding START or SELECT for 2 seconds resumes.
return function(mod)
  local PORT = 4210
  local RETRY_S = 0.4      -- first retries; slows down to RETRY_MAX_S
  local RETRY_MAX_S = 2.0
  local OUTAGE_S = 8       -- no answer this long: tell the player (once)
  local SHINY_WAIT_S = 1.5
  local RESUME_HOLD_S = 2.0
  local QUEUE_MAX = 500    -- reports wait here until the display confirms them

  mod.options:define({
    { key = "autopause", label = "SHINY AUTO-PAUSE", type = "toggle", default = true },
    { key = "host", label = "DISPLAY IP", type = "text", default = "", maxLen = 15 },
    { key = "status", label = "STATUS MESSAGES", type = "toggle", default = true },
    { key = "team", label = "SEND TEAM", type = "toggle", default = true },
    { key = "boxes", label = "SEND PC BOXES", type = "toggle", default = true },
    { key = "evs", label = "EV-ANZEIGE", type = "toggle", default = true },
    { key = "hunt", label = "AUTO-HUNT (F10/F11)", type = "toggle", default = true },
    { key = "starter", label = "STARTER (RSE)", type = "choice", default = "1",
      choices = { { "0", "LINKS" }, { "1", "MITTE" }, { "2", "RECHTS" } } },
  })

  local function now()
    return love.timer.getTime()
  end

  local function log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    msg = ok and msg or tostring(fmt)
    if mod.log and mod.log.info then mod.log:info(msg) else print("[pokecounter] " .. msg) end
  end

  -- ------------------------------------------------------------ bit helpers
  local function band16(x) return x % 65536 end
  local function hi16(x) return math.floor(x / 65536) % 65536 end
  local function bxor(a, b)
    local r, bitv = 0, 1
    while a > 0 or b > 0 do
      local x, y = a % 2, b % 2
      if x ~= y then r = r + bitv end
      a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
    end
    return r
  end

  -- -------------------------------------------------------- engine lookups
  local function engine(name)
    local ok, m = pcall(require, name)
    if ok then return m end
    return nil
  end

  local Pokemon = engine("src.core.game3.pokemon")
  local ItemsData = engine("src.core.game3.items_data")

  local function session()
    local Runtime = engine("src.core.game3.runtime")
    return Runtime and Runtime.getSession and Runtime.getSession() or nil
  end

  -- Cartridge game code (first three letters pick the edition on the display,
  -- the fourth is the language).
  local CODES = { emerald = "BPE", firered = "BPR", leafgreen = "BPG", ruby = "AXV", sapphire = "AXP" }
  local LANG_LETTER = { [1] = "J", [2] = "E", [3] = "F", [4] = "I", [5] = "D", [7] = "S" }

  local function gameCode()
    local s = session()
    local GV = engine("src.core.GameVersion")
    local version = s and s.version or (GV and GV.get and GV.get()) or "emerald"
    local prefix = CODES[version] or "BPE"
    local Lang = engine("src.core.game3.lang")
    local lang = Lang and Lang.game and Lang.game() or 2
    return prefix .. (LANG_LETTER[lang] or "E")
  end

  local function national(species)
    species = tonumber(species)
    if not species then return nil end
    if Pokemon and Pokemon.national then
      local ok, n = pcall(Pokemon.national, species)
      if ok and n then return n end
    end
    if species <= 251 then return species end
    return nil
  end

  local function itemId(item)
    if item == nil or item == 0 or item == "" or item == "ITEM_NONE" then return 0 end
    if type(item) == "number" then return item end
    if ItemsData and ItemsData.toNumericId then
      local ok, n = pcall(ItemsData.toNumericId, item)
      if ok and n then return n end
    end
    return tonumber(item) or 0
  end

  -- ---------------------------------------------------------- status line
  -- Short messages at the bottom of the game picture, so the player can see
  -- whether the display is reachable without a log.
  local toasts = {}
  local function toast(text)
    log("%s", text)
    if mod.options:get("status") == false then return end
    toasts[#toasts + 1] = { text = text, untilT = now() + 4 }
    while #toasts > 3 do table.remove(toasts, 1) end
  end

  -- ---------------------------------------------------------------- network
  local socket = engine("socket")
  local udp
  local netTried = false
  local learnedIp, mdnsIp, mdnsAt = nil, nil, -1e9
  local localIp = nil
  local subnetBroadcast = nil -- a.b.c.255 of the local address (some Wi-Fi stacks drop 255.255.255.255)
  local pingAt = -1e9
  local startedAt = now()
  local warnedMissing = false
  local queue = {}
  local ACK_GAP_S = 0.3
  local dirty = false          -- queue changed, write it to mod.storage
  local outageSince, outageWarned = nil, false

  local MDNS_QUERY = string.char(
    0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
    11) .. "pokecounter" .. string.char(5) .. "local" .. string.char(0, 0, 1, 0x80, 1)

  local function netInit()
    if netTried then return udp ~= nil end
    netTried = true
    if not socket or not socket.udp then
      toast("PokeCounter: kein Netzwerk (LuaSocket fehlt)")
      return false
    end
    -- IPv4 explicitly: a plain udp() bound to "*" can become an IPv6 socket
    -- (Android lists :: first), and then every IPv4 sendto fails
    local newUdp = socket.udp4 or socket.udp
    local u, uerr = newUdp()
    if not u then
      toast("PokeCounter: UDP-Socket nicht moeglich (" .. tostring(uerr) .. ")")
      return false
    end
    u:settimeout(0)
    -- bind first: SO_BROADCAST on a socket without a descriptor fails
    local ok, berr = u:setsockname("0.0.0.0", 0)
    if not ok then
      toast("PokeCounter: UDP-Socket nicht moeglich (" .. tostring(berr) .. ")")
      pcall(function() u:close() end)
      return false
    end
    if not u:setoption("broadcast", true) then log("broadcast not allowed, using mDNS only") end
    -- local address without sending anything: a connected UDP socket knows
    -- which interface it would use
    pcall(function()
      local probe = newUdp()
      probe:setpeername("192.0.2.1", 9)
      local ip = probe:getsockname()
      probe:close()
      local a, b, c = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
      if a and ip ~= "0.0.0.0" and a ~= "127" then
        localIp = ip
        subnetBroadcast = a .. "." .. b .. "." .. c .. ".255"
        log("local address %s, subnet broadcast %s", ip, subnetBroadcast)
      end
    end)
    udp = u
    return true
  end

  local function configuredHost()
    local h = mod.options:get("host")
    if type(h) == "string" then
      h = h:gsub("%s", "")
      if h:match("^%d+%.%d+%.%d+%.%d+$") then return h end
    end
    return nil
  end

  -- sendto with the error on screen (once per kind), so a blocked network
  -- shows up as a reason instead of a silent "no answer"
  local sendErrors = {}
  local function send(data, ip, port, quiet)
    local ok, err = udp:sendto(data, ip, port)
    if not ok then
      local key = ip .. "|" .. tostring(err)
      if not sendErrors[key] then
        sendErrors[key] = true
        log("sendto %s:%d failed: %s", ip, port, tostring(err))
        if not quiet then toast("PokeCounter: Senden an " .. ip .. " fehlgeschlagen (" .. tostring(err) .. ")") end
      end
    end
    return ok
  end

  local function sendMdns()
    mdnsAt = now()
    if udp then send(MDNS_QUERY, "224.0.0.251", 5353, true) end
  end

  local function sendDatagram(json)
    local to = configuredHost() or learnedIp or mdnsIp
    if to then
      send(json, to, PORT)
      return
    end
    send(json, "255.255.255.255", PORT)
    if subnetBroadcast then send(json, subnetBroadcast, PORT) end
  end

  local function pump()
    if not udp then return end
    for _ = 1, 32 do
      local data, ip, port = udp:receivefrom()
      if not data then break end
      port = tonumber(port)
      if port == 5353 then
        -- mDNS answer: QR bit set and at least one answer record
        if #data > 12 and not mdnsIp then
          local flags, an1, an2 = data:byte(3), data:byte(7), data:byte(8)
          if flags >= 0x80 and (an1 > 0 or an2 > 0) then
            mdnsIp = ip
            log("pokecounter.local -> %s", ip)
          end
        end
      elseif port == PORT then
        if not learnedIp then toast("PokeCounter verbunden (" .. tostring(ip) .. ")") end
        learnedIp = ip
        local head = queue[1]
        -- A reply only confirms the head once the head itself went out, and
        -- not right after a ping (could be the ping's answer). Late answers
        -- to a report's repeats arrive while the next one is held back
        -- (ACK_GAP_S) and are ignored. The display drops repeats by eid, so
        -- an extra send never counts twice.
        local pingReply = head and head.firstSent and head.firstSent - pingAt < 0.5 and now() - pingAt < 0.5
        if head and head.firstSent and not pingReply and data:find('"ok"', 1, true) then
          table.remove(queue, 1)
          dirty = true
          local t = now()
          if outageWarned then
            outageWarned = false
            toast("PokeCounter: wieder verbunden, " .. (#queue + 1) .. " Meldung(en) nachgeliefert")
          end
          outageSince = nil
          if queue[1] then
            queue[1].nextAt = math.max(queue[1].nextAt or 0, t + ACK_GAP_S)
          end
        end
      end
    end
    local t = now()
    if not learnedIp and not mdnsIp and not configuredHost() and t - mdnsAt > 5 then
      sendMdns()
    end
    -- find the display before the first encounter: a ping answers like a
    -- report but counts nothing
    if not learnedIp and #queue == 0 and t - pingAt > 4 then
      pingAt = t
      sendDatagram('{"t":"ping"}')
    end
    if not learnedIp and not warnedMissing and t - startedAt > 20 then
      warnedMissing = true
      toast("PokeCounter: Display nicht gefunden (gleiches WLAN? sonst IP in den Mod-Optionen)")
    end
    local p = queue[1]
    if not p or t < p.nextAt then return end
    -- Never give up on a report: Wi-Fi on handhelds drops out for seconds
    -- (power save, background scans), and the display counts a late report
    -- just as well. Retries slow down while it stays quiet.
    if p.firstSent and t - p.firstSent > OUTAGE_S then
      if not outageSince then outageSince = p.firstSent end
      if not outageWarned then
        outageWarned = true
        toast("PokeCounter: Display antwortet nicht, Meldungen werden nachgeschickt (" .. #queue .. ")")
      end
      -- a display that came back with a new address is found again
      if not configuredHost() and t - outageSince > 15 then learnedIp = nil end
    end
    sendDatagram(p.json)
    p.firstSent = p.firstSent or t
    p.tries = p.tries + 1
    p.nextAt = t + math.min(RETRY_MAX_S, RETRY_S * (1 + math.floor(p.tries / 6)))
  end

  local function enqueue(json, label, slotKey)
    if not netInit() then return end
    -- a newer state of the same team slot replaces one that has not gone out yet
    if slotKey then
      for i = #queue, 2, -1 do
        if queue[i].slotKey == slotKey and not queue[i].firstSent then table.remove(queue, i) end
      end
    end
    if #queue >= QUEUE_MAX then table.remove(queue, 1) end
    local entry = { json = json, tries = 0, nextAt = 0, label = label, slotKey = slotKey }
    local isBox = slotKey and slotKey:sub(1, 3) == "box"
    local at = #queue + 1
    if not isBox then
      -- encounters and team ahead of box packets still waiting: a whole PC
      -- upload must not hold back a report (or the shiny pause behind it)
      for i = 2, #queue do
        local k = queue[i].slotKey
        if k and k:sub(1, 3) == "box" and not queue[i].firstSent then at = i; break end
      end
    end
    table.insert(queue, at, entry)
    if not slotKey then dirty = true end
    pump() -- first try right away
  end

  -- ------------------------------------------------------------ shiny hold
  local shinyAt = nil      -- shiny reported, waiting for the display / timeout
  local held = false       -- simulation stopped
  local pausedSources = nil
  local resumeSince = nil  -- START/SELECT held since
  local shinyName = nil

  local function startHold()
    held = true
    shinyAt = nil
    resumeSince = nil
    local ok, sources = pcall(love.audio.pause)
    pausedSources = ok and sources or nil
    log("shiny! game paused, hold START or SELECT for 2 seconds to resume")
  end

  local function endHold()
    held = false
    shinyAt = nil
    resumeSince = nil
    if pausedSources then pcall(love.audio.play, pausedSources) end
    pausedSources = nil
    log("resumed after shiny")
  end

  local function resumeDown(game)
    local input = game and game.input
    if input and input.keyBindings and love.keyboard then
      for key, btn in pairs(input.keyBindings) do
        if (btn == "start" or btn == "select") and love.keyboard.isDown(key) then return true end
      end
    elseif love.keyboard and love.keyboard.isDown("escape", "tab", "kpenter", "lshift", "rshift") then
      return true
    end
    if love.joystick then
      for _, js in ipairs(love.joystick.getJoysticks()) do
        local ok, down = pcall(function()
          return js:isGamepad() and (js:isGamepadDown("start") or js:isGamepadDown("back"))
        end)
        if ok and down then return true end
      end
    end
    -- touch controls feed the engine's input state directly
    if input and input.isDown then
      local ok, down = pcall(function() return input:isDown("start") or input:isDown("select") end)
      if ok and down then return true end
    end
    return false
  end

  -- ---------------------------------------------------------- encounters
  local encSeq, lastShiny = 0, false   -- every reported wild Pokémon (auto-hunt)
  local hunt = nil                     -- running auto-hunt (see below)

  local function packIvs(ivs)
    if type(ivs) ~= "table" then return 0 end
    local function iv(k) return math.max(0, math.min(31, tonumber(ivs[k]) or 0)) end
    return iv("hp") + iv("atk") * 32 + iv("def") * 1024 + iv("spe") * 32768
      + iv("spa") * 1048576 + iv("spd") * 33554432
  end

  local function report(mon)
    local sp = national(mon.species or mon.speciesId)
    if not sp then
      log("unknown species %s, not reported", tostring(mon.species))
      return
    end
    local pid = tonumber(mon.personality) or 0
    local tid, sid = tonumber(mon.otId) or 0, tonumber(mon.otSecretId)
    if not sid then tid, sid = band16(tid), hi16(tid) end
    local tsv = bxor(tid, sid)
    local shiny = bxor(tsv, bxor(hi16(pid), band16(pid))) < 8
    local g = mon.gender
    g = (g == "M" or g == "F") and g or "N"
    local json = string.format(
      '{"t":"enc","sp":%d,"lv":%d,"g":"%s","shiny":%s,"pid":%.0f,"eid":%.0f,'
        .. '"ivs":%.0f,"ab":%d,"it":%d,"tsv":%d,"src":"%s"}',
      sp, tonumber(mon.level) or 0, g, shiny and "true" or "false", pid,
      love.math.random(1, 2147483646), packIvs(mon.ivs), tonumber(mon.abilityId or mon.ability) or 0,
      itemId(mon.item or mon.heldItem), tsv, gameCode())
    log("wild encounter: %s", json)
    encSeq = encSeq + 1
    lastShiny = shiny
    if shiny and mod.options:get("autopause") ~= false then
      shinyAt = now()
      shinyName = mon.name or mon.nickname
    end
    enqueue(json, (shiny and "SHINY " or "") .. "#" .. sp)
  end

  -- which EVs the wild Pokémon gives, at the start of the battle (bottom left)
  local EV_NAMES = { hp = "KP", atk = "Angriff", def = "Verteidigung", spa = "Sp.-Angriff", spd = "Sp.-Verteidigung", spe = "Initiative" }
  local EV_ORDER = { "hp", "atk", "def", "spa", "spd", "spe" }
  local function showEvs(mon)
    if mod.options:get("evs") == false or hunt or not (Pokemon and Pokemon.evYield) then return end
    local ok, y = pcall(Pokemon.evYield, mon)
    if not ok or type(y) ~= "table" then return end
    local parts = {}
    for _, k in ipairs(EV_ORDER) do
      local v = tonumber(y[k]) or 0
      if v > 0 then parts[#parts + 1] = "+" .. v .. " " .. EV_NAMES[k] end
    end
    if #parts == 0 then return end
    toasts[#toasts + 1] = { text = "EVs: " .. table.concat(parts, ", "), untilT = now() + 4 }
    while #toasts > 3 do table.remove(toasts, 1) end
  end

  mod.events:on("battle.started", function(ev)
    if type(ev) ~= "table" or ev.kind ~= "wild" then return end
    if hunt and hunt.mode == "gift" then return end   -- gift hunt: only the new party Pokémon counts
    local st = ev.battle
    local mon = st and st.enemy and st.enemy.mon
    if type(mon) ~= "table" then return end
    pcall(showEvs, mon)
    local ok, err = pcall(report, mon)
    if not ok then log("report failed: %s", tostring(err)) end
  end)

  -- ------------------------------------------------------------- team
  -- The party as the game sees it (IVs, EVs, stats, moves ...) for the
  -- display's web page; the games themselves never show IVs or EVs. One
  -- packet per Pokémon ({"t":"mon",...}), sent when that slot changed: after
  -- a battle, a level-up, vitamins, EV berries, evolution, a swap. Checked
  -- once a second outside battle; unchanged slots are not sent again.
  local function jstr(v)
    v = tostring(v or "")
    return '"' .. v:gsub('[%c"\\]', function(c)
      if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  local function jarr(t, fmt)
    local out = {}
    for i, v in ipairs(t) do out[i] = fmt and fmt(v) or string.format("%d", tonumber(v) or 0) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local STAT_KEYS = { "hp", "atk", "def", "spa", "spd", "spe" }  -- order on the wire
  local function six(t)
    local out = {}
    for i, k in ipairs(STAT_KEYS) do out[i] = tonumber(type(t) == "table" and t[k]) or 0 end
    return out
  end
  local function name(fn, id)
    if not fn or not id or id == 0 then return "" end
    local ok, n = pcall(fn, id)
    return ok and type(n) == "string" and n or ""
  end

  local function monJson(mon, slot, count)
    local sp = national(mon.species or mon.speciesId) or 0
    local pid = tonumber(mon.personality) or 0
    local tid, sid = tonumber(mon.otId) or 0, tonumber(mon.otSecretId)
    if not sid then tid, sid = band16(tid), hi16(tid) end
    local shiny = bxor(bxor(tid, sid), bxor(hi16(pid), band16(pid))) < 8
    local g = mon.gender
    g = (g == "M" or g == "F") and g or "N"
    local moves, pp, ppMax, moveNames = {}, {}, {}, {}
    for i = 1, 4 do
      local m = type(mon.moves) == "table" and mon.moves[i] or nil
      if type(m) == "table" then m = m.id or m.move end
      m = tonumber(m) or 0
      moves[i] = m
      pp[i] = tonumber(type(mon.pp) == "table" and mon.pp[i]) or 0
      ppMax[i] = tonumber(type(mon.maxPp) == "table" and mon.maxPp[i]) or 0
      moveNames[i] = m > 0 and name(Pokemon and Pokemon.moveName, m) or ""
    end
    local item = itemId(mon.item or mon.heldItem)
    local ab = tonumber(mon.abilityId or mon.ability) or 0
    local nick = ""
    if Pokemon and Pokemon.displayMonName then
      local ok, n = pcall(Pokemon.displayMonName, mon)
      nick = ok and n or ""
    end
    local stats = {
      tonumber(mon.maxHp) or 0, tonumber(mon.attack or mon.atk) or 0, tonumber(mon.defense or mon.def) or 0,
      tonumber(mon.spAtk or mon.spa) or 0, tonumber(mon.spDef or mon.spd) or 0, tonumber(mon.speed or mon.spe) or 0,
    }
    local status = mon.status
    if type(status) == "table" then status = status.name or status.id end
    return table.concat({
      '{"t":"mon","src":', jstr(gameCode()),
      ',"slot":', tostring(slot), ',"n":', tostring(count),
      ',"pid":', string.format("%.0f", pid), ',"sp":', tostring(sp), ',"lv":', tostring(tonumber(mon.level) or 0),
      ',"nick":', jstr(nick), ',"g":"', g, '","shiny":', shiny and "true" or "false",
      ',"nat":', tostring(tonumber(mon.nature) or (pid % 25)),
      ',"ab":', tostring(ab), ',"abn":', jstr(name(Pokemon and Pokemon.abilityName, ab)),
      ',"it":', tostring(item), ',"itn":', jstr(item > 0 and name(ItemsData and ItemsData.displayName, item) or ""),
      ',"ivs":', jarr(six(mon.ivs)), ',"evs":', jarr(six(mon.evs)), ',"st":', jarr(stats),
      ',"hp":', tostring(tonumber(mon.hp) or 0), ',"stat":', jstr(status or ""),
      ',"mv":', jarr(moves), ',"mvn":', jarr(moveNames, jstr), ',"pp":', jarr(pp), ',"ppm":', jarr(ppMax),
      ',"fr":', tostring(tonumber(mon.friendship or mon.happiness) or 0),
      ',"pkrs":', tostring(tonumber(mon.pokerus) or 0), ',"exp":', string.format("%.0f", tonumber(mon.exp) or 0),
      ',"ball":', tostring(tonumber(mon.pokeball) or 0), '}',
    })
  end

  local lastTeam = {}     -- slot -> json last queued
  local lastCount = -1
  local teamCheckAt = 0
  local function teamTick()
    if mod.options:get("team") == false then return end
    local t = now()
    if t < teamCheckAt then return end
    teamCheckAt = t + 1
    local Battle = engine("src.core.game3.battle")
    if Battle and Battle.isActive and Battle.isActive() then return end
    local s = session()
    local party = s and s.party
    if type(party) ~= "table" then return end
    local count = 0
    for i = 1, 6 do if type(party[i]) == "table" then count = i end end
    local sizeChanged = count ~= lastCount
    for i = 1, count do
      local mon = party[i]
      if mon.isEgg or mon.egg then
        -- eggs carry no stats worth showing; still keep the slot in order
        local json = '{"t":"mon","src":' .. jstr(gameCode()) .. ',"slot":' .. i .. ',"n":' .. count .. ',"egg":true}'
        if json ~= lastTeam[i] then lastTeam[i] = json; enqueue(json, nil, "mon" .. i) end
      else
        local ok, json = pcall(monJson, mon, i, count)
        if ok and (json ~= lastTeam[i] or sizeChanged) then
          lastTeam[i] = json
          enqueue(json, nil, "mon" .. i)
        elseif not ok then
          log("team slot %d: %s", i, tostring(json))
        end
      end
    end
    for i = count + 1, 6 do lastTeam[i] = nil end
    lastCount = count
  end

  -- ------------------------------------------------------------ PC boxes
  -- The storage system as the game holds it right now, for the display's
  -- Boxes tab: {"t":"box",...} with half a box per packet (one datagram),
  -- [slot,sp,lv,fl,pid,ivs,it,ab,"nick",ball] per Pokémon, fl = shiny | gender<<1 | egg<<3.
  -- Checked every 2 seconds outside battle; only changed halves are sent.
  local lastBox = {}      -- "b:h" -> json last queued
  local boxCheckAt = 0
  local function boxMonJson(mon, slot)
    local sp = national(mon.species or mon.speciesId)
    if not sp or sp < 1 then return nil end
    local pid = tonumber(mon.personality) or 0
    local tid, sid = tonumber(mon.otId) or 0, tonumber(mon.otSecretId)
    if not sid then tid, sid = band16(tid), hi16(tid) end
    local shiny = bxor(bxor(tid, sid), bxor(hi16(pid), band16(pid))) < 8
    local egg = mon.isEgg or mon.egg
    local g = mon.gender
    local fl = (shiny and 1 or 0) + ((g == "M" and 0) or (g == "F" and 1) or 2) * 2 + (egg and 8 or 0)
    local nick = ""
    if not egg and Pokemon and Pokemon.displayMonName then
      local ok, n = pcall(Pokemon.displayMonName, mon)
      nick = ok and type(n) == "string" and n or ""
    end
    return string.format('[%d,%d,%d,%d,%.0f,%.0f,%d,%d,%s,%d]', slot, sp, egg and 0 or (tonumber(mon.level) or 0), fl, pid,
      packIvs(mon.ivs), itemId(mon.item or mon.heldItem), tonumber(mon.abilityId or mon.ability) or 0, jstr(nick),
      tonumber(mon.pokeball) or 0)
  end

  local function boxTick()
    if mod.options:get("boxes") == false or hunt then return end
    local t = now()
    if t < boxCheckAt then return end
    boxCheckAt = t + 2
    local Battle = engine("src.core.game3.battle")
    if Battle and Battle.isActive and Battle.isActive() then return end
    local s = session()
    local storage = s and s.storage
    if type(storage) ~= "table" or type(storage.boxes) ~= "table" then return end
    local nb = math.min(#storage.boxes, 18)
    if nb < 1 then return end
    local cur = math.max(1, math.min(nb, tonumber(storage.currentBox) or 1))
    local src = gameCode()
    for b = 1, nb do
      local box = storage.boxes[b] or {}
      local mons = type(box.mons) == "table" and box.mons or {}
      local name = type(box.name) == "string" and box.name or ("BOX " .. b)
      for h = 0, 1 do
        local items = {}
        for slot = h * 15 + 1, h * 15 + 15 do
          local mon = mons[slot]
          if type(mon) == "table" then
            local ok, m = pcall(boxMonJson, mon, slot)
            if ok and m then items[#items + 1] = m elseif not ok then log("box %d slot %d: %s", b, slot, tostring(m)) end
          end
        end
        local json = table.concat({
          '{"t":"box","src":', jstr(src), ',"b":', b, ',"h":', h, ',"nb":', nb, ',"cur":', cur,
          ',"name":', jstr(name), ',"m":[', table.concat(items, ","), ']}',
        })
        local key = b .. ":" .. h
        if json ~= lastBox[key] then
          lastBox[key] = json
          enqueue(json, nil, "box" .. key)
        end
      end
    end
  end

  -- Reports still waiting survive closing the app: kept in mod.storage
  -- (per playthrough) and sent on the next start.
  local restored = false
  local function persist(game)
    if not restored then
      restored = true
      local ok, saved = pcall(function() return mod.storage:read(game, "pending") end)
      if ok and type(saved) == "table" and type(saved.items) == "table" and #saved.items > 0 then
        local have = {}
        for _, q in ipairs(queue) do have[q.json] = true end
        local back = {}
        for _, it in ipairs(saved.items) do
          if type(it) == "table" and type(it.json) == "string" and not have[it.json] then
            back[#back + 1] = { json = it.json, label = it.label, tries = 0, nextAt = 0 }
          end
        end
        for i = #back, 1, -1 do table.insert(queue, 1, back[i]) end
        if #back > 0 then
          netInit()
          toast("PokeCounter: " .. #back .. " offene Meldung(en) vom letzten Mal werden nachgeschickt")
          dirty = true
        end
      end
    end
    if dirty then
      dirty = false
      local items = {}
      for _, q in ipairs(queue) do
        if not q.slotKey then items[#items + 1] = { json = q.json, label = q.label } end
      end
      pcall(function() mod.storage:write(game, "pending", { format = 1, items = items }) end)
    end
  end

  -- ------------------------------------------------------------ auto-hunt
  -- F10 (or the mod option) starts a soft-reset hunt for a static Pokémon:
  -- save in front of it, press F10. The game goes back to the title screen,
  -- waits a random number of frames, presses A (B during FireRed's quest log
  -- replay) until the wild battle starts, and resets again unless the
  -- Pokémon is shiny. It runs as fast as the PC allows, muted, and never
  -- saves. Three resets in a row without a battle (2 minutes of game time
  -- each) stop it. A shiny stops it and the shiny pause holds the game.
  local HUNT_SPEED = 64             -- logic steps per frame, capped by the frame's time budget
  local HUNT_TIMEOUT_TICKS = 120 * 60
  local HUNT_MAX_TIMEOUTS = 3

  local function huntRestart(game)
    hunt.ticks = 0
    hunt.nextTap = love.math.random(0, 120)   -- own start delay -> own RNG state per reset
    hunt.encSeen = encSeq
    hunt.base = nil                            -- party size, read again after "Continue"
    hunt.tapCount = 0
    game.softResetRequested = true             -- handled at the next logic step (Game3:fixedUpdate)
  end

  local function huntStop(game, why)
    if not hunt then return end
    game.speedOverride = hunt.prevSpeed
    pcall(love.audio.setVolume, hunt.prevVolume or 1)
    local n = hunt.resets
    hunt = nil
    if why == "shiny" then
      toast(string.format("Auto-Jagd: SHINY nach %d Resets!", n))
    elseif why == "nobattle" then
      toast(string.format("Auto-Jagd gestoppt: %d Resets ohne Kampf - vor dem Pokemon speichern", HUNT_MAX_TIMEOUTS))
    else
      toast(string.format("Auto-Jagd AUS (%d Resets)", n))
    end
    log("auto-hunt stopped (%s) after %d resets", why, n)
  end

  local function huntStart(game, mode)
    if held or shinyAt then
      toast("Auto-Jagd: erst das Shiny bestaetigen (START/SELECT halten)")
      return
    end
    if not game.boot and not game.session then return end
    local dir = nil
    if mode == "gift" then
      -- the direction the player faces now: pressed between the A presses,
      -- so a save in Littleroot walks onto Route 101 (Emerald) and a save in
      -- front of a Poke Ball only bumps into the table (FireRed)
      if game.phase ~= "field" or not game.session then
        toast("Starter-Jagd: im Spiel vor dem Pokeball / Startpunkt F11 druecken")
        return
      end
      local Player = engine("src.core.game3.player")
      dir = Player and Player.facing or "up"
      if #(game.session.party or {}) >= 6 then
        toast("Starter-Jagd: im Team muss ein Platz frei sein")
        return
      end
    end
    local okV, vol = pcall(love.audio.getVolume)
    hunt = {
      mode = mode or "static", dir = dir,
      resets = 0, timeouts = 0, startedAt = now(),
      prevSpeed = game.speedOverride, prevVolume = okV and vol or 1,
    }
    game.speedOverride = HUNT_SPEED
    pcall(love.audio.setVolume, 0)
    if hunt.mode == "gift" then
      toast("Starter-Jagd AN: setzt zurueck, bis ein Shiny kommt - F11 beendet")
    else
      toast("Auto-Jagd AN: setzt zurueck, bis ein Shiny kommt - F10 beendet")
    end
    log("auto-hunt started (%s)", hunt.mode)
    huntRestart(game)
  end

  local function huntToggle(game, mode)
    if hunt then huntStop(game, "user") else huntStart(game, mode) end
  end

  -- gift hunt: a new Pokémon in the party (starter, gift) is the result
  local function giftCheck(game)
    local s = game.session
    if game.phase ~= "field" or type(s) ~= "table" or type(s.party) ~= "table" then return end
    local n = #s.party
    if hunt.base == nil then hunt.base = n return end
    if n > hunt.base then
      hunt.base = n
      local mon = s.party[n]
      if type(mon) == "table" then report(mon) end
    end
  end

  -- next button for the gift hunt: Emerald/Ruby/Sapphire starter screen ->
  -- move to the chosen ball, else A and the saved facing direction in turn
  local function isRse(game)
    local v = game and game.session and game.session.version
    return v == "emerald" or v == "ruby" or v == "sapphire"
  end

  local function giftButton(game)
    local SC = isRse(game) and engine("src.ui.game3.rse.starter_choose") or nil
    local scr = SC and SC.isOpen and SC.isOpen() and SC.active and SC.active()
    if scr and scr.state == "input" then
      local want = tonumber(mod.options:get("starter")) or 1
      if (scr.selection or 1) < want then return "right" end
      if (scr.selection or 1) > want then return "left" end
      return "a"
    end
    hunt.tapCount = (hunt.tapCount or 0) + 1
    if hunt.dir and hunt.tapCount % 2 == 0 then return hunt.dir end
    return "a"
  end

  -- every logic tick: battle seen -> shiny? / timeout
  local function huntCheck(game)
    if not hunt then return end
    if encSeq ~= hunt.encSeen then
      hunt.encSeen = encSeq
      hunt.timeouts = 0
      if lastShiny then
        huntStop(game, "shiny")
        return
      end
      hunt.resets = hunt.resets + 1
      if hunt.resets % 25 == 0 then toast(string.format("Auto-Jagd: %d Resets", hunt.resets)) end
      huntRestart(game)
    elseif hunt.ticks >= HUNT_TIMEOUT_TICKS then
      hunt.timeouts = hunt.timeouts + 1
      if hunt.timeouts >= HUNT_MAX_TIMEOUTS then
        huntStop(game, "nobattle")
      else
        huntRestart(game)
      end
    end
  end

  -- one game logic tick: count it, press A (B during the quest log replay)
  mod.hooks:wrap("input.step", function(next, game, dt)
    if hunt and not held and hunt.mode == "gift" then
      local okG, errG = pcall(giftCheck, game)
      if not okG then log("gift hunt: %s", tostring(errG)) end
    end
    if hunt and not held then
      local okH, errH = pcall(huntCheck, game)
      if not okH then
        log("auto-hunt: %s", tostring(errH))
        huntStop(game, "error")
      end
    end
    if hunt and not held then
      hunt.ticks = hunt.ticks + 1
      if hunt.ticks >= hunt.nextTap then
        local btn = game.phase == "quest_log" and "b" or (hunt.mode == "gift" and giftButton(game) or "a")
        mod.input:tap(game, btn)
        hunt.nextTap = hunt.ticks + love.math.random(8, 30)
      end
    end
    return next(game, dt)
  end)

  -- the hunt never writes the save (no accidental save from a menu)
  mod.hooks:wrap("save.write", function(next, game)
    if hunt then
      log("auto-hunt: save blocked")
      return false
    end
    return next(game)
  end)

  -- ------------------------------------------------------------- hooks
  mod.hooks:wrap("core.update", function(next, game, dt)
    pump()
    persist(game)
    local okB, errB = pcall(boxTick)
    if not okB then log("boxes: %s", tostring(errB)) end
    local okT, errT = pcall(teamTick)
    if not okT then log("team: %s", tostring(errT)) end
    if shinyAt and not held then
      if #queue == 0 or now() - shinyAt >= SHINY_WAIT_S or not udp then
        startHold()
      end
    end
    if held then
      if resumeDown(game) then
        resumeSince = resumeSince or now()
        if now() - resumeSince >= RESUME_HOLD_S then
          endHold()
          return next(game, dt)
        end
      else
        resumeSince = nil
      end
      return
    end
    return next(game, dt)
  end)

  -- While held, presses never reach the game (no buffered A press after the
  -- resume, no F1/F2 save hotkeys); releases still do, so nothing sticks.
  mod.hooks:wrap("input.key", function(next, game, ev)
    if ev and ev.phase == "pressed" and (ev.key == "f10" or ev.key == "f11")
        and mod.options:get("hunt") ~= false then
      if hunt and ((hunt.mode == "gift") ~= (ev.key == "f11")) then
        huntStop(game, "user")             -- the other key stops a running hunt too
      else
        huntToggle(game, ev.key == "f11" and "gift" or "static")
      end
      return true
    end
    if held and ev and ev.phase == "pressed" then return true end
    return next(game, ev)
  end)
  mod.hooks:wrap("input.gamepad", function(next, game, ev)
    if held and ev and ev.phase == "pressed" then return true end
    return next(game, ev)
  end)

  local fonts = {}
  local function font(size)
    size = math.max(8, math.floor(size))
    if not fonts[size] then fonts[size] = love.graphics.newFont(size) end
    return fonts[size]
  end

  mod.hooks:wrap("render.hud", function(next, game, vp)
    next(game, vp)
    if type(vp) ~= "table" then return end
    local g = love.graphics
    local gx, gy = vp.gameX or 0, vp.gameY or 0
    local gw, gh = vp.gameWidth or vp.width or g.getWidth(), vp.gameHeight or vp.height or g.getHeight()
    local t = now()
    for i = #toasts, 1, -1 do if toasts[i].untilT < t then table.remove(toasts, i) end end
    if #toasts > 0 then
      local f = font(gh * 0.035)
      local lh = f:getHeight() + 6
      g.push("all")
      g.setFont(f)
      for i, m in ipairs(toasts) do
        local y = gy + gh - (#toasts - i + 1) * lh - 4
        g.setColor(0, 0, 0, 0.65)
        g.rectangle("fill", gx, y, gw, lh)
        g.setColor(1, 1, 1, 1)
        g.printf(m.text, gx + 6, y + 3, gw - 12, "left")
      end
      g.pop()
    end
    if hunt then
      local f = font(gh * 0.03)
      local mins = math.max(1 / 60, (t - hunt.startedAt) / 60)
      local line = string.format("%s  %d Resets  %.0f/h  (%s = aus)",
        hunt.mode == "gift" and "STARTER-JAGD" or "AUTO-JAGD", hunt.resets, hunt.resets / mins * 60,
        hunt.mode == "gift" and "F11" or "F10")
      g.push("all")
      g.setFont(f)
      g.setColor(0, 0, 0, 0.6)
      g.rectangle("fill", gx, gy, gw, f:getHeight() + 6)
      g.setColor(0.6, 1, 0.6, 1)
      g.printf(line, gx + 6, gy + 3, gw - 12, "left")
      g.pop()
    end
    if not (held or shinyAt) then return end
    local bh = math.floor(gh * 0.22)
    local by = gy + math.floor(gh * 0.06)
    g.push("all")
    g.setColor(0, 0, 0, 0.72)
    g.rectangle("fill", gx, by, gw, bh)
    g.setColor(1, 0.85, 0.2, 1)
    local big = font(bh * 0.42)
    g.setFont(big)
    g.printf("*** SHINY ***", gx, by + bh * 0.08, gw, "center")
    g.setColor(1, 1, 1, 1)
    local small = font(bh * 0.2)
    g.setFont(small)
    local hint = held and "START oder SELECT 2 Sek. halten = weiter" or "PokeCounter wird benachrichtigt ..."
    g.printf(hint, gx, by + bh * 0.58, gw, "center")
    if held and resumeSince then
      local f = math.min(1, (now() - resumeSince) / RESUME_HOLD_S)
      g.setColor(1, 0.85, 0.2, 1)
      g.rectangle("fill", gx + gw * 0.2, by + bh * 0.86, gw * 0.6 * f, bh * 0.06)
    end
    g.pop()
  end)

  if netInit() then sendMdns() end
  log("PokeCounter active (%s)", gameCode())
  local fixed = configuredHost()
  toast("PokeCounter aktiv (eigene IP " .. tostring(localIp or "?") .. ")"
    .. (fixed and (", sende an " .. fixed) or ", suche Display ..."))
end
