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
  local RETRY_S = 0.4
  local MAX_TRIES = 8
  local SHINY_WAIT_S = 1.5
  local RESUME_HOLD_S = 2.0
  local QUEUE_MAX = 16

  mod.options:define({
    { key = "autopause", label = "SHINY AUTO-PAUSE", type = "toggle", default = true },
    { key = "host", label = "DISPLAY IP (EMPTY = AUTO)", type = "text", default = "", maxLen = 15 },
    { key = "status", label = "STATUS MESSAGES", type = "toggle", default = true },
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
    local version = s and s.version or mod.version or "emerald"
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
  local subnetBroadcast = nil -- a.b.c.255 of the local address (some Wi-Fi stacks drop 255.255.255.255)
  local pingAt = -1e9
  local startedAt = now()
  local warnedMissing = false
  local queue = {}

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
    local u = socket.udp()
    if not u then return false end
    u:settimeout(0)
    -- bind first: SO_BROADCAST on a socket without a descriptor fails
    local ok = u:setsockname("*", 0)
    if not ok then
      toast("PokeCounter: UDP-Socket nicht moeglich")
      pcall(function() u:close() end)
      return false
    end
    if not u:setoption("broadcast", true) then log("broadcast not allowed, using mDNS only") end
    -- local address without sending anything: a connected UDP socket knows
    -- which interface it would use
    pcall(function()
      local probe = socket.udp()
      probe:setpeername("192.0.2.1", 9)
      local ip = probe:getsockname()
      probe:close()
      local a, b, c = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
      if a and ip ~= "0.0.0.0" and a ~= "127" then
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

  local function sendMdns()
    mdnsAt = now()
    if udp then udp:sendto(MDNS_QUERY, "224.0.0.251", 5353) end
  end

  local function sendDatagram(json)
    local to = configuredHost() or learnedIp or mdnsIp
    if to then
      udp:sendto(json, to, PORT)
      return
    end
    udp:sendto(json, "255.255.255.255", PORT)
    if subnetBroadcast then udp:sendto(json, subnetBroadcast, PORT) end
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
        -- a reply right after a startup ping may be the ping's answer: keep
        -- the report then (the display drops repeats by eid)
        local pingReply = head and head.firstSent and head.firstSent - pingAt < 0.5 and now() - pingAt < 0.5
        if head and not pingReply and data:find('"ok"', 1, true) then
          local done = table.remove(queue, 1)
          if done.label then toast("PokeCounter: " .. done.label .. " gemeldet") end
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
    if p.tries >= MAX_TRIES then
      log("no reply from display, dropping: %s", p.json)
      toast("PokeCounter: keine Antwort vom Display")
      learnedIp = nil -- fall back to mDNS / broadcast
      table.remove(queue, 1)
      return
    end
    sendDatagram(p.json)
    p.firstSent = p.firstSent or t
    p.tries = p.tries + 1
    p.nextAt = t + RETRY_S
  end

  local function enqueue(json, label)
    if not netInit() then return end
    if #queue >= QUEUE_MAX then table.remove(queue, 1) end
    queue[#queue + 1] = { json = json, tries = 0, nextAt = 0, label = label }
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
    if shiny and mod.options:get("autopause") ~= false then
      shinyAt = now()
      shinyName = mon.name or mon.nickname
    end
    enqueue(json, (shiny and "SHINY " or "") .. "#" .. sp)
  end

  mod.events:on("battle.started", function(ev)
    if type(ev) ~= "table" or ev.kind ~= "wild" then return end
    local st = ev.battle
    local mon = st and st.enemy and st.enemy.mon
    if type(mon) ~= "table" then return end
    local ok, err = pcall(report, mon)
    if not ok then log("report failed: %s", tostring(err)) end
  end)

  -- ------------------------------------------------------------- hooks
  mod.hooks:wrap("core.update", function(next, game, dt)
    pump()
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
  toast("PokeCounter aktiv, suche Display ...")
end
