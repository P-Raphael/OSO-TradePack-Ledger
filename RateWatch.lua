-- Route observations are independent of the sale ledger. Native queries run at
-- most once every 30 seconds; one small history job runs per update interval.
TradePacksRateWatch = {}
local Watch = {}
Watch.__index = Watch
TradePacksRateRoutes.install(Watch)
TradePacksRateChart.install(Watch)
TradePacksRateCombined.install(Watch)
local WIDTH, HEIGHT, OVERLAY_HEIGHT = 440, 736, 264
local REFRESH_SECONDS, HISTORY_DAYS = 30, 30
local MAX_CHART_POINTS = 30
local MAX_COMPARE_PACKS = 6
local SERIES_COLORS = {{0.2, 0.53, 0.25}, {0.15, 0.45, 0.9}, {0.85, 0.25, 0.55},
  {0.1, 0.65, 0.7}, {0.65, 0.35, 0.85}, {0.75, 0.4, 0.1}}
local PROFICIENCY_OPTIONS = {
  {id = "current", name = "Current Commerce (character points + bonus points)"},
  {id = "off", name = "Commerce bonus OFF"},
  {id = "272000", name = "Fixed Commerce: 272,000 points"},
  {id = "332000", name = "Fixed Commerce: 332,000 points"}
}
local FRESHNESS_MULTIPLIERS = {Luxury = 1.30, Fine = 1.15, Commercial = 1.05, Preserved = 1.03}
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, part in pairs(value) do out[key] = copy(part) end
  return out
end
local function number(value)
  local n = tonumber(value)
  if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
end
local function hash(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 2147483647 end
  return string.format("%.0f", h)
end
local function routeKey(from, to) return tostring(from) .. "_" .. tostring(to) end
local function hourLabel(hour) return string.format("%02d:00", hour % 24) end
local function validPeriod(value, maximum, fallback)
  local n = number(value)
  if not n or n < 1 or n > maximum or n ~= math.floor(n) then return fallback end
  return math.floor(n)
end
local function periodLabel(hours)
  if hours < 1 then return string.format("%dm", hours * 60) end
  return hours > 48 and hours % 24 == 0 and string.format("%dd", hours / 24) or string.format("%dh", hours)
end
local function minuteLabel(at, offset)
  local minute = math.floor(at / 60 + offset * 60) % 1440
  return string.format("%02d:%02d", math.floor(minute / 60), minute % 60)
end
local function dateLabel(at, offset, includeHour)
  local hour = hourLabel(math.floor(at / 3600 + offset))
  if os and type(os.date) == "function" then
    local ok, date = pcall(os.date, "!%d/%m", at + offset * 3600)
    if ok then return date .. (includeHour and (" " .. hour) or "") end
  end
  return hour
end
local function zoneList(raw, known)
  local out, seen = {}, {}
  for _, value in pairs(type(raw) == "table" and raw or {}) do
    if type(value) == "number" then
      local id = value
      value = {id = id, zoneGroupName = "Zone " .. id}
      for _, zone in ipairs(known or {}) do
        if zone.id == id then value.zoneGroupName = zone.name; break end
      end
    end
    if type(value) == "table" then
      local id = number(value.id or value.zoneGroupType)
      if id and id > 0 and not seen[id] and type(value.zoneGroupName) == "string" then
        out[#out + 1] = {id = id, name = value.zoneGroupName, continent = value.continentName}
        seen[id] = true
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end
local function contains(list, id)
  for _, value in ipairs(list) do if value.id == id then return value end end
end

function TradePacksRateWatch.new(ctx)
  local self = setmetatable({ctx = ctx, days = {}, series = {}, latest = {},
    packs = {}, jobs = {}, jobKeys = {}, head = 1, tail = 0, elapsed = 0,
    nextQueryAt = 0, generation = 0, revision = 0, status = "Choose a route to begin.",
    historyLoading = 0, menuRows = {}}, Watch)
  local saved = ADDON:LoadData("TradePacksRateSettings")
  self.settings = type(saved) == "table" and saved or {}
  local s = self.settings
  s.from, s.to = number(s.from), number(s.to)
  s.offset = number(s.offset) or -3
  if s.offset < -12 or s.offset > 14 or s.offset ~= math.floor(s.offset) then s.offset = -3 end
  s.mode = s.mode == "hourly" and "hourly" or "recent"
  s.recentHours = (s.recentHours == 0.25 or s.recentHours == 0.5) and s.recentHours
    or validPeriod(s.recentHours, HISTORY_DAYS * 24, 24)
  s.hourlyDays = validPeriod(s.hourlyDays, HISTORY_DAYS, HISTORY_DAYS)
  s.metric = (s.metric == "price" or s.metric == "profit" or s.metric == "both") and s.metric or "rate"
  s.showRatePrice = s.showRatePrice == true
  s.pack = type(s.pack) == "string" and s.pack or nil
  local selected, seen = {}, {}
  for _, name in ipairs(type(s.selectedPacks) == "table" and s.selectedPacks or {}) do
    if type(name) == "string" and name ~= "" and not seen[name] and #selected < MAX_COMPARE_PACKS then
      selected[#selected + 1], seen[name] = name, true
    end
  end
  if #selected == 0 and s.pack then selected[1], seen[s.pack] = s.pack, true end
  s.selectedPacks = selected
  if not seen[s.pack] then s.pack = selected[1] end
  self:trimGraphPositions()
  self:initRouteSelection()
  s.open, s.detached = s.open == true, s.detached == true
  s.graphOnly = s.graphOnly == true
  s.graphBackground = (s.graphBackground == "shaded" or s.graphBackground == "dark")
    and s.graphBackground or "transparent"
  s.collectHidden = s.collectHidden == true
  s.proficiencyMode = contains(PROFICIENCY_OPTIONS, s.proficiencyMode) and s.proficiencyMode or "current"
  s.maxFreshness = s.maxFreshness == true
  self.minuteHistory = TradePacksMinuteHistory.new({now = ctx.now, sameData = ctx.sameData,
    enqueue = function(key, work, retry) self:enqueue(key, work, retry) end})
  pcall(function() ADDON:ImportAPI(37) end) -- X2Store: documented ratio and route queries only.
  pcall(function() ADDON:ImportAPI(3) end) -- X2Ability: the Commerce reader used by Folio105.
  ADDON:ImportObject(48) -- Native Line widget, also used by the auction price chart.
  self:createUi()
  self:createOverlay()
  self:createDriver()
  self:watchOtherTracker()
  self:visibility()
  return self
end

function Watch:trimGraphPositions()
  local entries, active = {}, {}
  for _, name in ipairs(self.settings.selectedPacks or {}) do active[name] = true end
  for _, item in ipairs(type(self.settings.selectedRoutes) == "table" and self.settings.selectedRoutes or {}) do
    if type(item) == "table" and type(item.id) == "string" then active[item.id] = true end
  end
  for name, position in pairs(type(self.settings.graphPositions) == "table" and self.settings.graphPositions or {}) do
    if type(name) == "string" and #name > 0 and #name <= 240 and type(position) == "table"
      and number(position.x) and number(position.y) then
      entries[#entries + 1] = {name = name, x = number(position.x), y = number(position.y), used = number(position.used) or 0}
    end
  end
  table.sort(entries, function(a, b)
    if active[a.name] ~= active[b.name] then return active[a.name] == true end
    if a.used ~= b.used then return a.used > b.used end
    return a.name < b.name
  end)
  local positions = {}
  for i = 1, math.min(24, #entries) do
    local entry = entries[i]
    positions[entry.name] = {x = entry.x, y = entry.y, used = entry.used}
  end
  self.settings.graphPositions = positions
  local styles = {}
  for i = 1, math.min(12, #entries) do
    local id = entries[i].name
    local value = type(self.settings.graphStyles) == "table" and self.settings.graphStyles[id]
    if type(value) == "table" then
      styles[id] = self:graphStyle({id = id})
    end
  end
  self.settings.graphStyles = styles
  local colors, colorCount = {}, 0
  local function retainColor(id)
    local value = type(self.settings.seriesColors) == "table" and self.settings.seriesColors[id]
    if colorCount < 24 and type(id) == "string" and #id <= 240 and not colors[id]
      and type(value) == "string" and value:match("^%x%x%x%x%x%x$") then
      colors[id], colorCount = value:upper(), colorCount + 1
    end
  end
  -- A route used only in the combined view may never have a mini-window position.
  for id in pairs(active) do retainColor(id) end
  for _, entry in ipairs(entries) do retainColor(entry.name) end
  self.settings.seriesColors = colors
end

function Watch:seriesColor(id, index, transparent)
  local hex = self.settings.seriesColors and self.settings.seriesColors[id]
  local key = (hex or tostring(index)) .. tostring(transparent)
  self.seriesColorCache = self.seriesColorCache or {}
  local cacheId = tostring(id) .. tostring(transparent)
  local cached = self.seriesColorCache[cacheId]
  if cached and cached.key == key then return cached.color end
  local color
  if hex then color = {tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255}
  else
    local base, extra = SERIES_COLORS[index] or SERIES_COLORS[1], transparent and 0.2 or 0
    color = {math.min(1, base[1] + extra), math.min(1, base[2] + extra), math.min(1, base[3] + extra)}
  end
  self.seriesColorCache[cacheId] = {key = key, color = color}
  return color
end

function Watch:applySeriesColor(chart, index, id, colorIndex)
  local layer = self:chartLayer(chart, index)
  local color = self:seriesColor(id, colorIndex or index, chart.transparent)
  if layer.color ~= color then
    layer.color, layer.renderSignature = color, nil
    layer.line:SetLineColor(color[1], color[2], color[3], 1)
    if index == 1 then chart.color = color end
  end
end

function Watch:setSeriesColor(id, hex)
  if not id then return end
  self.settings.seriesColors = self.settings.seriesColors or {}
  self.settings.seriesColors[id] = hex
  self:saveSettings(); self:render()
end

function Watch:showColorMenu(graph, id)
  local owner = graph and graph.window or self.window
  if not id and graph and not graph.combined then id = graph.id end
  if not id then
    local options = {}
    for _, entry in ipairs(self:selectedEntries()) do
      options[#options + 1] = {id = entry.id, name = entry.name .. " | " .. self:routeLabel(entry)}
    end
    return self:showMenu(options, function(value) self:showColorMenu(graph, value.id) end,
      24, false, "color-pack", owner)
  end
  local options = {{id = "default", name = "Automatic pack color"}}
  for _, entry in ipairs({{"55EE77", "Green"}, {"5599FF", "Blue"}, {"FF6688", "Rose"},
    {"FFAA33", "Orange"}, {"FFDD44", "Yellow"}, {"33DDDD", "Cyan"}, {"CC88FF", "Purple"},
    {"FFFFFF", "White"}, {"FF4444", "Red"}}) do
    options[#options + 1] = {id = entry[1], name = entry[2] .. " (#" .. entry[1] .. ")"}
  end
  options[#options + 1] = {id = "custom", name = "Custom color: #RRGGBB..."}
  self:showMenu(options, function(value)
    if value.id == "custom" then
      self.editorMode, self.colorId = "color", id
      self.periodTitle:SetText("Line color: enter #RRGGBB (example: #55EE77)")
      self.periodInput:SetText("#" .. (self.settings.seriesColors[id] or "55EE77"))
      self.periodError:SetText("")
      self:placePicker(self.periodEditor, owner, 400, 136, 24)
      self.periodEditor:Show(true); self:raisePicker()
    else self:setSeriesColor(id, value.id ~= "default" and value.id or nil) end
  end, 24, false, "color-" .. id, owner)
end

function Watch:placeMiniGraph(graph, index)
  if graph.dragging or graph.resizing then return end
  local s = self.settings
  local sw, sh, scale = self:rateScreenSize()
  local columns = math.max(1, math.min(2, math.floor(sw / (WIDTH + 8))))
  local rows = math.ceil(MAX_COMPARE_PACKS / columns)
  local left = math.max(0, math.min(180, sw - columns * (WIDTH + 8) + 8))
  local top = math.max(0, math.min(120, sh - rows * (OVERLAY_HEIGHT + 8) + 8))
  local position = graph.id and s.graphPositions[graph.id]
  local legacy = not position and index == 1 and number(s.graphX) and number(s.graphY)
  local x, y
  if position or legacy then
    x, y = self:restoreRatePosition(position and position.x or s.graphX,
      position and position.y or s.graphY, 28, (graph.width or WIDTH) - 230, 0)
  else
    x = math.max(0, math.min(left + ((index - 1) % columns) * (WIDTH + 8), sw - WIDTH))
    y = math.max(0, math.min(top + math.floor((index - 1) / columns) * (OVERLAY_HEIGHT + 8), sh - OVERLAY_HEIGHT))
    -- Selection slots can change while existing packs keep their positions.
    -- Give a newly selected pack a free tile without moving any saved graph.
    local occupied = {}
    for _, item in ipairs(self:selectedEntries()) do
      local other = item.id ~= graph.id and s.graphPositions[item.id]
      if other then
        occupied[#occupied + 1] = {
          x = other.x / scale,
          y = other.y / scale}
      end
    end
    local function overlap(px, py)
      local area = 0
      for _, other in ipairs(occupied) do
        area = area + math.max(0, math.min(px + WIDTH, other.x + WIDTH) - math.max(px, other.x))
          * math.max(0, math.min(py + OVERLAY_HEIGHT, other.y + OVERLAY_HEIGHT) - math.max(py, other.y))
      end
      return area
    end
    local bestArea = overlap(x, y)
    if bestArea > 0 then
      for slot = 1, MAX_COMPARE_PACKS do
        local px = math.max(0, math.min(left + ((slot - 1) % columns) * (WIDTH + 8), sw - WIDTH))
        local py = math.max(0, math.min(top + math.floor((slot - 1) / columns) * (OVERLAY_HEIGHT + 8), sh - OVERLAY_HEIGHT))
        local area = overlap(px, py)
        if area < bestArea then x, y, bestArea = px, py, area end
        if bestArea == 0 then break end
      end
    end
  end
  graph.window:RemoveAllAnchors()
  graph.window:AddAnchor("TOPLEFT", "UIParent", x, y)
  if graph.id and (not position or position.x ~= x * scale or position.y ~= y * scale) then
    s.graphPositions[graph.id] = {x = x * scale, y = y * scale, used = self.ctx.now()}
    return true
  end
end

function Watch:syncMiniGraphs(forcePosition)
  if not self.miniGraphs then return end
  local entries, changed = self:selectedEntries(), false
  -- A placeholder keeps settings reachable and polling alive before a first reply.
  local count = math.max(1, #entries)
  for index = 1, math.max(count, #self.miniGraphs) do
    local graph = self.miniGraphs[index]
    if not graph and index <= count then graph = self:createMiniGraph(index) end
    local active = index <= count
    local item = active and entries[index] or nil
    local id = item and item.id
    if graph.id ~= id and self.menuOwner == graph.window then
      self.menu:Show(false); self.periodEditor:Show(false)
    end
    if graph.id ~= id or forcePosition or not graph.positioned then
      graph.id, graph.name, graph.entry, graph.positioned = id, item and item.name, item, true
      self:layoutFloatingGraph(graph)
      if active then changed = self:placeMiniGraph(graph, index) or changed end
    end
    local visible = active and self.settings.open and self.settings.graphOnly and self.settings.graphLayout ~= "combined"
    if graph.window:IsVisible() ~= visible then graph.window:Show(visible) end
  end
  if changed then self:saveSettings() end
  self:syncCombinedGraph(forcePosition)
end

function Watch:closeMiniGraph(graph)
  if graph.entry and #self:selectedEntries() > 1 then
    self:togglePack(graph.entry)
  else
    self.settings.open = false
    self:saveSettings(); self:visibility()
  end
end

function Watch:saveSettings()
  self:trimGraphPositions()
  local ok, err = pcall(function()
    local data = copy(self.settings)
    data.open = data.open and true or nil
    data.detached = data.detached and true or nil
    data.graphOnly = data.graphOnly and true or nil
    data.collectHidden = data.collectHidden and true or nil
    data.maxFreshness = data.maxFreshness and true or nil
    ADDON:SaveData("TradePacksRateSettings", data)
    if not self.ctx.sameData(data, ADDON:LoadData("TradePacksRateSettings")) then
      error("rate panel settings did not read back")
    end
  end)
  if not ok then self.ctx.reportSaveError("rates", err) end
end

function Watch:enqueue(key, work, retry, after)
  if self.jobKeys[key] then return end
  self.tail = self.tail + 1
  self.jobs[self.tail] = {key = key, work = work, retry = retry, after = after}
  self.jobKeys[key] = true
end

function Watch:workOne()
  if self.head > self.tail then return end
  local job = self.jobs[self.head]
  self.jobs[self.head], self.jobKeys[job.key] = nil, nil
  self.head = self.head + 1
  if self.head > self.tail then self.head, self.tail = 1, 0 end
  if self.ctx.now() < (job.after or 0) then
    self:enqueue(job.key, job.work, job.retry, job.after)
    return
  end
  local ok, err = pcall(job.work)
  if not ok then
    if job.retry then self:enqueue(job.key, job.work, true, self.ctx.now() + 60) end
    self.status = "Some history is unavailable; saved copies are protected."
    self.ctx.reportSaveError("rates", err)
  end
end

function Watch:seriesFor(from, to, name)
  local identity = routeKey(from, to) .. ":" .. name
  if not self.series[identity] then
    self.series[identity] = {from = from, to = to, name = name,
      key = "TradePacksRates_" .. routeKey(from, to) .. "_" .. hash(name)}
  end
  return self.series[identity]
end

function Watch:validDay(data, series, day)
  if type(data) ~= "table" or data.version ~= 1 or data.name ~= series.name
    or data.from ~= series.from or data.to ~= series.to or data.day ~= day
    or type(data.hours) ~= "table" then return false end
  for h, row in pairs(data.hours) do
    if type(h) ~= "number" or h < 0 or h > 23 or h ~= math.floor(h)
      or type(row) ~= "table" or not number(row.n) or row.n < 1 or row.n > 60
      or not number(row.sum) or not number(row.low) or not number(row.high)
      or not number(row.last) or not number(row.minute) or row.minute < 0 or row.minute > 1439
      or row.low <= 0 or row.high < row.low then return false end
  end
  return true
end

function Watch:loadDay(series, day)
  if not series.checkedIdentity then
    local index = ADDON:LoadData(series.key .. "Index")
    if index and (type(index) ~= "table" or index.name ~= series.name
      or index.from ~= series.from or index.to ~= series.to) then
      error("rate history identity mismatch; preserving existing data")
    end
    series.checkedIdentity = true
  end
  local key = series.key .. "_" .. day
  if self.days[key] then return self.days[key] end
  local meta = ADDON:LoadData(key .. "Meta")
  local bank = type(meta) == "table" and meta.bank
  local data
  if bank == "A" or bank == "B" then
    data = ADDON:LoadData(key .. bank)
    if not self:validDay(data, series, day) then
      bank = bank == "A" and "B" or "A"
      data = ADDON:LoadData(key .. bank)
    end
    if not self:validDay(data, series, day) then
      error("rate history is incomplete; keeping both saved copies")
    end
  elseif meta ~= nil then
    error("rate history pointer is invalid; keeping saved copies")
  else
    bank = nil
    data = {version = 1, name = series.name, from = series.from, to = series.to,
      day = day, hours = {}}
  end
  local entry = {key = key, bank = bank, data = data}
  self.days[key] = entry
  return entry
end

function Watch:saveDay(entry)
  local bank = entry.bank == "A" and "B" or "A"
  ADDON:SaveData(entry.key .. bank, entry.data)
  if not self.ctx.sameData(entry.data, ADDON:LoadData(entry.key .. bank)) then
    error("rate history day did not read back completely")
  end
  ADDON:SaveData(entry.key .. "Meta", {bank = bank})
  local meta = ADDON:LoadData(entry.key .. "Meta")
  if type(meta) ~= "table" or meta.bank ~= bank then error("rate history commit failed") end
  entry.bank = bank
end

function Watch:prune(series, today)
  if series.indexDay == today then return end
  local key = series.key .. "Index"
  local index = ADDON:LoadData(key)
  if index and (type(index) ~= "table" or index.name ~= series.name
    or index.from ~= series.from or index.to ~= series.to) then
    error("rate history identity mismatch; preserving existing data")
  end
  local first = type(index) == "table" and number(index.firstDay) or today
  if not first or first < 0 or first ~= math.floor(first) then error("invalid rate history date") end
  -- A rolling 30-day view can span 31 UTC dates. Keep its partial first day.
  local cutoff = today - HISTORY_DAYS
  -- Each cleanup is a separate job, never a long loop of native calls on one frame.
  local last = type(index) == "table" and number(index.lastDay) or first
  if not last or last < first or last - first > HISTORY_DAYS then error("invalid rate history range") end
  for day = first, math.min(cutoff - 1, last) do
    local oldKey = series.key .. "_" .. day
    self:enqueue("prune:" .. oldKey, function()
      ADDON:ClearData(oldKey .. "A")
      ADDON:ClearData(oldKey .. "B")
      ADDON:ClearData(oldKey .. "Meta")
      self.days[oldKey] = nil
    end, true)
  end
  local updated = {name = series.name, from = series.from, to = series.to,
    firstDay = math.max(first, cutoff), lastDay = today}
  ADDON:SaveData(key, updated)
  if not self.ctx.sameData(updated, ADDON:LoadData(key)) then error("rate history index save failed") end
  series.indexDay = today
end

function Watch:sample(series, at, ratio)
  -- Failure of optional minute detail must not block the durable hourly history.
  local ok, added = pcall(function() return self.minuteHistory:sample(series, at, ratio) end)
  if not ok then self.ctx.reportSaveError("minute history", added)
  elseif added and self:isSelectedPack(series.name, series.from, series.to) then self.revision = self.revision + 1 end
  local day, minute = math.floor(at / 86400), math.floor(at % 86400 / 60)
  local entry = self:loadDay(series, day)
  local hour = math.floor(minute / 60)
  local bucket = entry.data.hours[hour]
  -- One observation per minute; Refresh spam cannot overweight a time of day.
  if bucket and bucket.minute >= minute then return end
  if not bucket then
    bucket = {n = 0, sum = 0, low = ratio, high = ratio}
    entry.data.hours[hour] = bucket
  end
  bucket.n, bucket.sum = bucket.n + 1, bucket.sum + ratio
  bucket.low, bucket.high = math.min(bucket.low, ratio), math.max(bucket.high, ratio)
  bucket.last, bucket.minute = ratio, minute
  if self:isSelectedPack(series.name, series.from, series.to) then self.revision = self.revision + 1 end
  self:enqueue("save:" .. entry.key, function() self:saveDay(entry) end, true)
  self:enqueue("index:" .. series.key, function() self:prune(series, day) end, true)
end

function Watch:loadSelectedHistory()
  local s = self.settings
  if #self:selectedEntries() == 0 then return end
  local now, selected = self.ctx.now(), {}
  local today, hour = math.floor(now / 86400), math.floor(now / 3600)
  local period = s.mode == "hourly" and s.hourlyDays * 24 or s.recentHours
  local firstDay = math.floor((hour - period + 1) / 24)
  local function queueRead(key, work)
    if self.jobKeys[key] then return end
    self.historyLoading = self.historyLoading + 1
    self:enqueue(key, function()
      local ok, err = pcall(work)
      self.historyLoading = self.historyLoading - 1
      self.revision = self.revision + 1
      if not ok then error(err) end
    end)
  end
  for _, item in ipairs(self:selectedEntries()) do
    local series = self:seriesFor(item.from, item.to, item.name)
    selected[#selected + 1] = series
    if series.minuteLoadedHour ~= hour then
      queueRead("minute-load:" .. series.key, function()
        self.minuteHistory:loadRecent(series); series.minuteLoadedHour = hour
      end)
    end
  end
  -- Recent data for every compared pack comes first; long histories load in
  -- small interleaved jobs. Never duplicate reads when toggling a selection.
  for day = today, firstDay, -1 do
    for _, series in ipairs(selected) do
      local key = series.key .. "_" .. day
      if not self.days[key] then queueRead("load:" .. key, function() self:loadDay(series, day) end) end
    end
  end
end

function Watch:historyRows(name)
  local s, rows = self.settings, {}
  local item = self:routeEntry(name)
  if not item then return rows end
  local series = self:seriesFor(item.from, item.to, item.name)
  local today = math.floor(self.ctx.now() / 86400)
  for day = today - HISTORY_DAYS, today do
    local entry = self.days[series.key .. "_" .. day]
    for hour, bucket in pairs(entry and entry.data.hours or {}) do
      rows[#rows + 1] = {at = day * 86400 + hour * 3600, ratio = bucket.sum / bucket.n,
        n = bucket.n, low = bucket.low, high = bucket.high,
        last = bucket.last, lastAt = day * 86400 + bucket.minute * 60}
    end
  end
  table.sort(rows, function(a, b) return a.at < b.at end)
  return rows
end

function Watch:chartData(name)
  local s, now = self.settings, self.ctx.now()
  if s.mode == "recent" and s.recentHours <= 1 then return self:minuteChartData(name) end
  local rows, columns, hours = self:historyRows(name), {}, {}
  local lastHour = math.floor(now / 3600)
  local period = s.mode == "hourly" and s.hourlyDays * 24 or s.recentHours
  local firstHour, count = lastHour - period + 1, 0
  local step = math.ceil(period / MAX_CHART_POINTS)
  local layout = {firstHour = firstHour, hours = period, step = step,
    count = math.ceil(period / step), hourly = s.mode == "hourly"}
  if layout.hourly then layout.count, layout.step = 24, 1 end
  for _, row in ipairs(rows) do
    local rowHour = math.floor(row.at / 3600)
    if rowHour >= firstHour and rowHour <= lastHour then
      count = count + 1
      local hour = (rowHour + s.offset) % 24
      local group = hours[hour] or {sum = 0, days = 0, n = 0, low = row.low, high = row.high}
      group.sum, group.days, group.n = group.sum + row.ratio, group.days + 1, group.n + row.n
      group.low, group.high = math.min(group.low, row.low), math.max(group.high, row.high)
      hours[hour] = group
      if not layout.hourly then
        local index = math.floor((rowHour - firstHour) / step) + 1
        local start = firstHour + (index - 1) * step
        local point = columns[index] or {sum = 0, observed = 0, n = 0, days = 0,
          at = start * 3600, hour = (start + s.offset) % 24,
          hours = math.min(step, lastHour - start + 1), low = row.low, high = row.high}
        -- Give each observed hour equal weight; polling longer in one hour must
        -- not dominate a multi-hour point. Missing hours never become samples.
        point.sum, point.observed, point.n = point.sum + row.ratio, point.observed + 1, point.n + row.n
        point.low, point.high = math.min(point.low, row.low), math.max(point.high, row.high)
        local localDay = math.floor((row.at + s.offset * 3600) / 86400)
        if point.lastDay ~= localDay then point.days = point.days + 1; point.lastDay = localDay end
        columns[index] = point
      end
    end
  end
  local best, covered = nil, 0
  for hour, group in pairs(hours) do
    group.ratio, group.hour = group.sum / group.days, hour
    if group.days >= 3 then
      covered = covered + 1
      if not best or group.ratio > best.ratio then best = group end
    end
  end
  -- A single sampled hour cannot establish the best hour of the day.
  if covered < 2 then best = nil end
  if s.mode == "hourly" then
    columns = {}
    for hour = 0, 23 do columns[hour + 1] = hours[hour] end
  else
    for _, point in pairs(columns) do
      point.ratio = point.sum / point.observed
      point.complete = point.observed == point.hours
    end
  end
  return columns, best, count, layout
end

function Watch:minuteChartData(name)
  local s, now = self.settings, self.ctx.now()
  local item = self:routeEntry(name)
  local minutes = math.floor(s.recentHours * 60)
  local last = math.floor(now / 60)
  local first, columns, observed = last - minutes + 1, {}, 0
  local layout = {minute = true, firstAt = first * 60, count = minutes,
    hours = s.recentHours, step = 1, units = minutes}
  if item then
    local series = self:seriesFor(item.from, item.to, item.name)
    for _, row in ipairs(self.minuteHistory:rows(series, now)) do
      local index = math.floor(row.at / 60) - first + 1
      if index >= 1 and index <= minutes then
        columns[index] = {at = row.at, ratio = row.ratio, n = 1, observed = 1,
          minutes = 1, days = 1, complete = true}
        observed = observed + 1
      end
    end
  end
  return columns, nil, observed, layout
end

function Watch:columnX(index, layout, width)
  if layout.minute then return (index - 0.5) * width / layout.count end
  if layout.hourly then return (index - 0.5) * width / 24 end
  local start = (index - 1) * layout.step
  return (start + math.min(layout.step, layout.hours - start) / 2) * width / layout.hours
end

function Watch:renderTicks(ticks, chart, layout)
  local count = math.min(5, layout.count, math.max(2, math.floor(chart.width / 70) + 1))
  for i, tick in ipairs(ticks) do
    tick:Show(i <= count)
    if i <= count then
      local index = count == 1 and 1 or math.floor((i - 1) * (layout.count - 1) / (count - 1) + 0.5) + 1
      local at = layout.minute and (layout.firstAt + (index - 1) * 60)
        or ((layout.firstHour + (index - 1) * layout.step) * 3600)
      local label = layout.minute and minuteLabel(at, self.settings.offset) or layout.hourly and hourLabel(index - 1)
        or (layout.hours > 48 and dateLabel(at, self.settings.offset, false)
          or hourLabel(math.floor(at / 3600 + self.settings.offset)))
      tick:SetText(label)
      tick:RemoveAllAnchors()
      tick:AddAnchor("TOP", chart.plot, "BOTTOMLEFT", self:columnX(index, layout, chart.width), 3)
    end
  end
end

function Watch:basePrice(name)
  local tables = {[5] = SOLZREED_PRICE, [8] = TWOCROWNS_PRICE,
    [20] = CINDERSTONE_MOOR_PRICE, [4] = SOLIS_HEADLANDS_PRICE,
    [12] = VILLANELLE_PRICE, [17] = YNYSTERE_PRICE, [33] = HEEDMAR_PRICE}
  local item = type(name) == "table" and name or {name = name, to = self.settings.to}
  local prices = tables[item.to]
  local entry = type(prices) == "table" and prices[item.name]
  return type(entry) == "table" and number(entry[1]) or nil
end

function Watch:commerceSkill()
  local mode = self.settings.proficiencyMode
  if mode == "off" then return 0 end
  if mode ~= "current" then return number(mode) end
  local now = self.ctx.now()
  if now < (self.nextCommerceAt or 0) then return self.currentCommerce end
  self.nextCommerceAt, self.currentCommerce = now + 5, nil
  if X2Ability and type(X2Ability.GetAllMyActabilityInfos) == "function" then
    local ok, infos = pcall(function() return X2Ability:GetAllMyActabilityInfos() end)
    if ok and type(infos) == "table" then
      for _, info in pairs(infos) do
        if type(info) == "table" and info.name == "Commerce" then
          local points = number(info.point)
          local modifier = info.modifyPoint == nil and 0 or number(info.modifyPoint)
          if points and modifier then self.currentCommerce = math.max(0, points + modifier) end
          break
        end
      end
    end
  end
  return self.currentCommerce
end

function Watch:priceContext(name)
  local context = {base = self:basePrice(name), skill = self:commerceSkill(), freshness = 1}
  local destination = type(name) == "table" and name.to or self.settings.to
  name = type(name) == "table" and name.name or name
  if context.skill then context.professional = 1 + (context.skill / 10000 * 0.05) end
  if self.settings.maxFreshness and name then
    if destination == 33 then
      context.freshness = 1.30
    else
      for packType, multiplier in pairs(FRESHNESS_MULTIPLIERS) do
        if name:find(packType, 1, true) then context.freshness = multiplier; break end
      end
    end
  end
  return context
end

function Watch:estimatePrice(context, ratio)
  if not context.base or not context.professional or not ratio then return nil end
  -- Match Folio105.CalculatePrice, including its final copper rounding. Prices.lua
  -- holds copper per percentage point, so a 130% demand reading is already 130.
  return math.floor((context.base * ratio) * context.professional * context.freshness)
end

function Watch:discover()
  if not X2Store or type(X2Store.GetProductionZoneGroups) ~= "function"
    or type(X2Store.GetSellableZoneGroups) ~= "function" then
    self.status = "Route queries are unavailable in this client."
    return false
  end
  local ok, data = pcall(function() return X2Store:GetProductionZoneGroups() end)
  self.origins = ok and zoneList(data) or {}
  self:rememberZones(self.origins)
  if #self.origins == 0 then self.status = "Routes are not available yet. Try Refresh."; return false end
  if not contains(self.origins, self.settings.from) then self.settings.from = self.origins[1].id end
  return self:destinations()
end

function Watch:destinations()
  local ok, data = pcall(function() return X2Store:GetSellableZoneGroups(self.settings.from) end)
  self.outlets = ok and zoneList(data, self.origins) or {}
  self:rememberZones(self.outlets)
  if #self.outlets == 0 then
    self.status = "Destinations are not available yet; retrying shortly."
    return false -- Preserve the saved route while the client finishes loading.
  end
  self.routeOutlets[self.settings.from] = self.outlets
  if not contains(self.outlets, self.settings.to) then self.settings.to = self.outlets[1] and self.outlets[1].id end
  if not self.settings.to then self.status = "No destinations are available for this origin."; return false end
  return true
end

function Watch:selectRoute(from, to)
  self.settings.from, self.settings.to = from, to
  self:destinations()
  local key = routeKey(self.settings.from, self.settings.to)
  self.packs, self.latest = self.routePacks[key] or {}, self.routeQuotes[key] or {}
  self.browsePending = true
  self.menu:Show(false)
  self:loadSelectedHistory()
  self.status = self.request and "Waiting for the previous route query to finish." or "Refreshing route..."
  self:saveSettings()
  self:query()
  self:render()
end

function Watch:watchOtherTracker()
  -- The separate Pack Ratio addon exposes this Lua function. Its reply has no
  -- route IDs, so ignore our pending reply when it issues a conflicting query.
  -- Preserve its behavior and do not replace shared UIParent event handlers.
  if _G and type(_G.checkPackRatio) == "function" then
    local previous = _G.checkPackRatio
    _G.checkPackRatio = function(from, to, ...)
      local now = self.ctx.now()
      self.externalUntil = now + REFRESH_SECONDS
      self.externalRoute = {from = number(from), to = number(to)}
      local otherFrom, otherTo = self.externalRoute.from, self.externalRoute.to
      local watched = self.externalRoute.from == self.settings.from and self.externalRoute.to == self.settings.to
      for _, route in ipairs(self:trackedRoutes()) do
        if route.from == otherFrom and route.to == otherTo then watched = true end
      end
      local conflicts = self.request and (self.request.from ~= otherFrom or self.request.to ~= otherTo)
      if watched and not conflicts then
        -- The older tracker can poll every five seconds. Its same-route reply
        -- is usable; blocking it for 30 seconds on every poll starves our chart.
        if self:shouldCollect() and not self.request and now >= (self.externalConflictUntil or 0) then
          self.request = {from = otherFrom, to = otherTo,
            generation = self.generation, at = now, shared = true}
        end
      else
        -- A quick switch back to our route must not admit an unlabeled reply
        -- still in flight for the other route.
        self.externalConflictUntil = now + REFRESH_SECONDS
        if self.request then self.request.conflict = true end
      end
      return previous(from, to, ...)
    end
  end
end

function Watch:expireRequest()
  if self.request and self.ctx.now() - self.request.at >= 15 then
    self.request = nil
    self.refreshState = "timeout"
    self.status = "No server reply; keeping the last reading."
  end
end

function Watch:query()
  local now, s = self.ctx.now(), self.settings
  -- Manual Refresh must recover too, even if the background updater stopped.
  self:expireRequest()
  if not self:shouldCollect() or self.request or now < self.nextQueryAt then return false end
  if now < (self.externalUntil or 0) then
    self.status = "Pause the other rate tracker to refresh this route."
    return false
  end
  if not self.origins or #self.origins == 0 or not self.outlets or #self.outlets == 0 then
    if not self:discover() then self.nextQueryAt = now + REFRESH_SECONDS; return false end
  end
  local route = self:nextRoute()
  if not route then
    self.status = "Choose different origin and destination zones."
    return false
  end
  -- Validate saved routes against the client's zone lists before a native
  -- ratio request, including routes other than the one currently browsed.
  local outlets = self.routeOutlets[route.from]
  if contains(self.origins, route.from) and not outlets then
    local ok, data = pcall(function() return X2Store:GetSellableZoneGroups(route.from) end)
    outlets = ok and zoneList(data, self.origins) or {}
    if #outlets > 0 then self.routeOutlets[route.from] = outlets; self:rememberZones(outlets) end
  end
  if not contains(self.origins, route.from) or not contains(outlets or {}, route.to) then
    self.routePollAt[route.key], self.nextQueryAt = now, now + REFRESH_SECONDS
    self.browsePending = nil
    self.status = "Selected route unavailable; keeping its saved history."
    return false
  end
  if not X2Store or type(X2Store.GetSpecialtyRatioBetween) ~= "function" then
    self.status = "Rate queries are unavailable in this client."
    return false
  end
  local request = {from = route.from, to = route.to, generation = self.generation, at = now}
  self.request = request
  self.routePollAt[route.key] = now
  if route.from == s.from and route.to == s.to then self.browsePending = nil end
  self.nextQueryAt = now + REFRESH_SECONDS
  self.refreshState, self.status = "waiting", "Waiting for server reply..."
  local ok, sent = pcall(function() return X2Store:GetSpecialtyRatioBetween(route.from, route.to) end)
  -- The native specialty UI treats the return value as cooldown milliseconds,
  -- not just a success boolean. Honor a longer server cooldown before retrying.
  local cooldown = ok and number(sent)
  self.extendedCooldown = cooldown and cooldown > REFRESH_SECONDS * 1000 or false
  if cooldown and cooldown > 0 then
    self.serverCooldownUntil = now + math.ceil(cooldown / 1000)
    self.nextQueryAt = math.max(self.nextQueryAt, self.serverCooldownUntil)
  end
  self.routeInterval = math.max(REFRESH_SECONDS, cooldown and math.ceil(cooldown / 1000) or 0)
  if (not ok or sent == false or sent == nil) and self.request == request then
    self.request = nil
    self.refreshState, self.status = "failed", "Server did not accept the request."
    return false
  end
  return true
end

function Watch:receive(payload)
  local request, now = self.request, self.ctx.now()
  if not self:shouldCollect() then self.request = nil; return false end
  if not request then return false end
  if request.conflict or request.generation ~= self.generation or now - request.at >= 15 then
    self.request = nil
    self.status = "Ignored a late or conflicting route reply."
    return false
  end
  if type(payload) ~= "table" then return false end
  if (payload.fromZoneGroup and number(payload.fromZoneGroup) ~= request.from)
    or (payload.toZoneGroup and number(payload.toZoneGroup) ~= request.to) then return false end
  local packs, latest = {}, {}
  for _, row in pairs(payload.ratios or payload) do
    if type(row) == "table" and type(row.itemInfo) == "table" then
      local name, ratio = row.itemInfo.name, number(row.ratio)
      if type(name) == "string" and name ~= "" and ratio and ratio > 0 and ratio <= 1000 and not latest[name] then
        packs[#packs + 1] = {id = name, name = name}
        latest[name] = {ratio = ratio, at = now}
      end
    end
  end
  self.request = nil
  if #packs == 0 then self.status = "No pack rates returned for this route."; return false end
  table.sort(packs, function(a, b) return a.name < b.name end)
  local key = routeKey(request.from, request.to)
  local retained = self.routeQuotes[key] or {}
  for name, quote in pairs(latest) do retained[name] = quote end
  self.routeQuotes[key], self.routePacks[key] = retained, packs
  self.routePollAt[key] = now
  if request.from == self.settings.from and request.to == self.settings.to then
    self.packs, self.latest = packs, retained
  end
  for _, pack in ipairs(packs) do
    local series, ratio = self:seriesFor(request.from, request.to, pack.name), latest[pack.name].ratio
    self:enqueue("sample:" .. series.key .. ":" .. math.floor(now / 60), function()
      self:sample(series, now, ratio)
    end)
  end
  -- A reply belongs to its requested route, not the route currently being
  -- browsed. Missing rows retain their last reading/age and selected identity.
  if #self:selectedEntries() == 0 and request.from == self.settings.from and request.to == self.settings.to then
    local item = self:routeEntry(packs[1].name, request.from, request.to)
    self.settings.selectedRoutes = {item}
    self:syncRouteSelection()
    self:saveSettings()
    if self:isVisible() then self:loadSelectedHistory() else self.historyNeedsLoad = true end
  end
  if self.menuMulti and self.menu:IsVisible() then self.menuOptions = self:packMenuOptions(); self:renderMenu() end
  self.refreshState, self.status = "received", "Rates updated."
  self.revision = self.revision + 1
  self:render()
  return true
end

function Watch:toggle()
  self.settings.open = not (self.settings.open and self:isVisible())
  self:place()
  self:saveSettings()
  self:visibility()
  if self.settings.open then self:query(); self:render() end
end

function Watch:createDriver()
  -- An always-shown, empty window owns both the timer and response subscription.
  -- Closing the ledger, hiding the OPS button, or using mini-graphs cannot stop it.
  local driver = self.ctx.widget("window", "TradePacksRatesDriver", nil, 0, 0, 1, 1)
  self.driver = driver
  driver:EnablePick(false)
  driver:Clickable(false)
  driver:SetCloseOnEscape(false)
  driver:SetHandler("OnUpdate", function(_, elapsedMs)
    local ok, err = pcall(function() self:tick(math.max(0, number(elapsedMs) or 0) / 1000) end)
    if not ok then
      self.status = "Refresh error; see the TradePacks chat message."
      self.ctx.reportSaveError("rate panel", err)
    end
  end)
  driver:SetHandler("OnEvent", function(_, event, payload)
    if event ~= "SPECIALTY_RATIO_BETWEEN_INFO" then return end
    local ok, result = pcall(function() return self:receive(payload) end)
    if not ok then self.ctx.reportSaveError("rate reply", result); return false end
    return result
  end)
  driver:RegisterEvent("SPECIALTY_RATIO_BETWEEN_INFO")
  driver:Show(true)
end

function Watch:place()
  if self.dragging then return end
  local window, s = self.window, self.settings
  window:RemoveAllAnchors()
  if s.detached then
    local x, y = self:restoreRatePosition(s.x, s.y, 18, 260, 13)
    window:AddAnchor("TOPLEFT", "UIParent", x, y)
  else
    local screen = self:rateScreenSize()
    local ok, x = pcall(function() return self.ctx.ledger:GetOffset() end)
    if ok and number(x) and number(screen) and x + self.ctx.ledger:GetWidth() + WIDTH + 8 > screen
      and x >= WIDTH + 8 then
      window:AddAnchor("TOPRIGHT", self.ctx.ledger, "TOPLEFT", -8, 0)
    else
      local offset = 8
      if ok and number(x) and number(screen) then
        offset = math.min(offset, screen - x - self.ctx.ledger:GetWidth() - WIDTH)
      end
      window:AddAnchor("TOPLEFT", self.ctx.ledger, "TOPRIGHT", offset, 0)
    end
  end
  self:syncMiniGraphs()
end

function Watch:detach()
  if not self.settings.detached then
    local ok, x, y = pcall(function() return self.window:GetOffset() end)
    if ok and number(x) and number(y) then
      local scale = self.ctx.scale()
      self.settings.x, self.settings.y = x * scale, y * scale
    end
  end
  self.settings.detached = not self.settings.detached
  self:place()
  self:saveSettings()
  self:render()
end

function Watch:visibility()
  local visible = self.settings.open and not self.settings.graphOnly
    and (self.settings.detached or self.ctx.ledger:IsVisible())
  if self.window:IsVisible() ~= visible then
    self.window:Show(visible)
    if not visible then self.menu:Show(false); self.periodEditor:Show(false) end
  end
  self:syncMiniGraphs()
  if self.menuOwner and not self.menuOwner:IsVisible() then
    self.menu:Show(false); self.periodEditor:Show(false)
  end
  if self:isVisible() and not self.initialized then
    self.initialized = true
    self:discover()
    self:loadSelectedHistory()
    self.historyNeedsLoad = nil
    self:render()
  elseif self:isVisible() and self.historyNeedsLoad then
    self.historyNeedsLoad = nil
    self:loadSelectedHistory()
  end
end

function Watch:isVisible()
  return self.window:IsVisible() or (self.overlay and self.overlay:IsVisible())
    or (self.combinedGraph and self.combinedGraph.window:IsVisible()) or false
end

function Watch:shouldCollect()
  return self:isVisible() or (self.settings.collectHidden and self.settings.from ~= nil and self.settings.to ~= nil)
end

function Watch:setGraphOnly(enabled, graph)
  if not enabled then
    local position = graph and graph.id and self.settings.graphPositions[graph.id]
    if self.settings.graphLayout == "combined" then
      position = {x = self.settings.combinedX, y = self.settings.combinedY}
    end
    self.settings.x = position and position.x or self.settings.graphX or self.settings.x
    self.settings.y = position and position.y or self.settings.graphY or self.settings.y
    if graph and graph.entry then
      self.settings.pack, self.settings.focusId, self.legacyPack = graph.name, graph.id, graph.name
    end
  end
  self.settings.graphOnly = enabled
  self.settings.detached = true
  self.settings.open = true
  self.menu:Show(false)
  self.periodEditor:Show(false)
  self:place()
  self:saveSettings()
  self:visibility()
  self:render()
end

function Watch:tick(dt)
  self.elapsed = self.elapsed + math.max(0, dt)
  if self.elapsed < 0.2 then return end
  self.elapsed = 0
  self:workOne()
  self:visibility()
  if not self:shouldCollect() then return end
  local now = self.ctx.now()
  self:query()
  -- Collection while hidden must not redraw charts or poll cost/Commerce data.
  if not self:isVisible() then return end
  if (self.renderedRevision ~= self.revision and now >= (self.nextDirtyRenderAt or 0))
    or now >= (self.nextRenderAt or 0) then
    self:render()
    self.nextRenderAt = now + 5
  elseif now >= (self.nextStatusAt or 0) then
    self:renderStatus()
  end
end

function Watch:refreshStatus()
  local now = self.ctx.now()
  if self.request then
    return (self.request.shared and "Waiting for same-route tracker reply: " or "Waiting for server reply: ")
      .. math.max(0, math.floor(now - self.request.at)) .. "s"
  end
  if now < (self.externalUntil or 0) then
    local sameRoute = self.externalRoute and self.externalRoute.from == self.settings.from
      and self.externalRoute.to == self.settings.to
    if sameRoute and now < (self.externalConflictUntil or 0) then
      return "Other route reply pending; retry in " .. math.ceil(self.externalConflictUntil - now) .. "s"
    end
    return (sameRoute and "Following same-route tracker; retry in " or "Other route tracker active; retry in ")
      .. math.ceil(self.externalUntil - now) .. "s"
  end
  local remaining = math.max(0, math.ceil(self.nextQueryAt - now))
  if remaining > 0 then
    if self.refreshState == "timeout" then return "No server reply; retry in " .. remaining .. "s" end
    if self.refreshState == "failed" then return "Request rejected; retry in " .. remaining .. "s" end
    if self.extendedCooldown and (self.serverCooldownUntil or 0) > now then
      return "Server cooldown: " .. remaining .. "s until next update"
    end
    return (#self:trackedRoutes() > 1 and "Next route update in " or "Next update in ") .. remaining .. "s."
  end
  return self.status
end

function Watch:renderStatus()
  local now, at = self.ctx.now(), self.displayedQuoteAt
  local ageText = "No observations yet for this pack and route."
  if at then
    local age = math.max(0, now - at)
    ageText = "Updated " .. (age < 60 and (math.floor(age) .. "s") or (math.floor(age / 60) .. "m"))
      .. " ago" .. (age > self:staleAfter() and " - stale" or "")
  end
  self.age:SetText(ageText)
  local status = self:refreshStatus()
  self.statusLabel:SetText(self.ctx.fit(status, 65))
  for _, graph in ipairs(self.miniGraphs or {}) do
    if graph.window:IsVisible() then
      local age = graph.quoteAt and math.max(0, now - graph.quoteAt)
      local text = age and ("Updated " .. (age < 60 and (math.floor(age) .. "s") or (math.floor(age / 60) .. "m"))
        .. " ago" .. (age > self:staleAfter() and " - stale" or "") .. " | ") or ""
      self:setGraphLabel(graph.status, text .. status, (graph.width or WIDTH) - 94, graph.font or 12)
    end
  end
  self:renderCombinedStatus()
  self.nextStatusAt = now + 1
end

function Watch:raisePicker()
  -- Comparison legends and chart widgets are created lazily after the picker.
  -- Keep the entire picker above those newer siblings, including its backdrop.
  if self.menu and self.menu:IsVisible() then pcall(function() self.menu:Raise() end) end
  if self.periodEditor and self.periodEditor:IsVisible() then
    pcall(function() self.periodEditor:Raise() end)
  end
end

function Watch:placePicker(picker, owner, width, height, y)
  local sw, sh = self:rateScreenSize()
  local ok, left, top = pcall(function() return owner:GetOffset() end)
  left, top = ok and number(left) or 0, ok and number(top) or 0
  local x = math.max(0, math.min(left + 12, sw - width))
  y = math.max(0, math.min(top + (y or 24), sh - height))
  picker:RemoveAllAnchors(); picker:AddAnchor("TOPLEFT", "UIParent", x, y)
end

function Watch:showMenu(options, select, y, multi, kind, owner)
  owner = owner or self.window
  if self.periodEditor then self.periodEditor:Show(false) end
  if kind and self.menuKind == kind and self.menuOwner == owner and self.menu:IsVisible() then
    self.menu:Show(false)
    return
  end
  self.menuKind = kind
  self.menuOwner = owner
  self.menuMulti, self.menuHint = multi == true, nil
  self.menuOptions, self.menuSelect, self.menuPage = options, select, 1
  self:placePicker(self.menu, owner, 540, multi and 418 or 252, y or 84)
  self:renderMenu()
  self.menu:Show(true)
  self:raisePicker()
end

function Watch:renderMenu()
  local options, page = self.menuOptions or {}, self.menuPage or 1
  local pages = math.max(1, math.ceil(#options / 8))
  self.menuPage = math.max(1, math.min(page, pages))
  for i, button in ipairs(self.menuRows) do
    local value = options[(self.menuPage - 1) * 8 + i]
    button.option = value
    button:Show(value ~= nil)
    button:RemoveAllAnchors()
    button:AddAnchor("TOPLEFT", self.menu, 8, 4 + (i - 1) * (self.menuMulti and 44 or 27))
    button:SetExtent(524, self.menuMulti and 42 or 25)
    self.menuNameLabels[i]:Show(value ~= nil and self.menuMulti)
    self.menuRouteLabels[i]:Show(value ~= nil and self.menuMulti)
    if value then
      self.ctx.setButtonText(button, self.menuMulti and "" or value.name)
      if self.menuMulti then
        self.menuNameLabels[i]:SetText((self:isSelectedPack(value.id) and "[x] " or "[ ] ") .. value.name)
        self.menuRouteLabels[i]:SetText(self:routeLabel(value))
      end
    end
  end
  self.menuPageLabel:SetText(self.menuMulti
    and string.format("%d/6 selected | Page %d/%d", #self:selectedPackNames(), self.menuPage, pages)
    or string.format("%d / %d", self.menuPage, pages))
  if self.menuDone then
    self.ctx.setButtonText(self.menuDone, self.menuMulti and "Done" or "Close")
    self.menuDone:Show(true)
  end
  if self.menuHelp then
    self.menuHelp:SetText(self.menuHint or "Selections stay; choose From/To to add another route.")
    self.menuHelp:Show(self.menuMulti)
  end
  local footer = self.menuMulti and 354 or 222
  for _, row in ipairs({{self.menuPrev, 8, footer}, {self.menuPageLabel, 90, footer + 2},
    {self.menuNext, self.menuMulti and 456 or 372, footer}, {self.menuHelp, 8, footer + 37},
    {self.menuDone, 456, footer + (self.menuMulti and 34 or 0)}}) do
    row[1]:RemoveAllAnchors(); row[1]:AddAnchor("TOPLEFT", self.menu, row[2], row[3])
  end
  self.menu:SetExtent(540, self.menuMulti and 418 or 252)
  self.menuPageLabel:SetExtent(self.menuMulti and 350 or 274, 20)
  self:raisePicker()
end

function Watch:showPackMenu()
  self:showMenu(self:packMenuOptions(), function(value) self:togglePack(value) end, 155, true, "pack")
end

function Watch:showPeriodMenu(graph)
  local hourly = self.settings.mode == "hourly"
  local key = hourly and "hourlyDays" or "recentHours"
  local choices = hourly and {3, 7, 14, 30} or {0.25, 0.5, 1, 2, 3, 6, 12, 24, 48, 168, 336, 720}
  local options = {}
  for _, amount in ipairs(choices) do
    local days, minutes = hourly or amount > 48, not hourly and amount < 1
    local n = minutes and amount * 60 or days and not hourly and amount / 24 or amount
    options[#options + 1] = {id = amount, name = (hourly and "Average over " or "Last ")
      .. string.format("%d", n) .. (minutes and " minutes" or days and " days" or (amount == 1 and " hour" or " hours"))}
  end
  options[#options + 1] = {id = "custom", name = hourly and "Custom: 1 to 30 days..." or "Custom: 1 to 720 hours..."}
  self:showMenu(options, function(value)
    if value.id == "custom" then
      self.editorMode = "period"
      self.periodKey = key
      self.periodTitle:SetText(hourly and "Time-of-day lookback: 1 to 30 days" or "Recent history: 1 to 720 hours")
      self.periodInput:SetText(tostring(math.max(1, self.settings[key])))
      self.periodError:SetText("")
      self:placePicker(self.periodEditor, self.menuOwner or self.window, 400, 136, graph and 24 or 320)
      self.periodEditor:Show(true)
      self:raisePicker()
    else
      self.settings[key] = value.id
      self.selectedPoint = nil
      self:saveSettings(); self:loadSelectedHistory(); self:render()
    end
  end, graph and 24 or 314, false, "period", graph and graph.window)
end

function Watch:createPeriodEditor()
  local c = self.ctx
  local editor = c.widget("window", "TradePacksRatesPeriodEditor", nil, 20, 320, 400, 136)
  self.periodEditor = editor
  pcall(function() editor:SetDrawPriority(101); editor:EnablePick(true) end)
  pcall(function() editor:SetTitleText(""); editor:SetCloseOnEscape(true) end)
  local bg = editor:CreateColorDrawable(c.dark and 0.08 or 0.96, c.dark and 0.07 or 0.89,
    c.dark and 0.06 or 0.69, 1, "background")
  bg:AddAnchor("TOPLEFT", editor, 0, 0); bg:AddAnchor("BOTTOMRIGHT", editor, 0, 0)
  self.periodTitle = c.label("TradePacksRatesPeriodTitle", editor, 10, 12, 380, 20, "")
  self.periodInput = c.editbox("TradePacksRatesPeriodInput", editor, 20, 48, 110, 26, "24")
  c.button("TradePacksRatesPeriodApply", editor, 146, 48, 108, 26, "Apply", function()
    local ok, text = pcall(function() return self.periodInput:GetText() end)
    if self.editorMode == "color" then
      local hex = ok and tostring(text):match("^%s*#?(%x%x%x%x%x%x)%s*$")
      if not hex then self.periodError:SetText("Enter six hex digits, for example #55EE77."); return end
      editor:Show(false); self:setSeriesColor(self.colorId, hex:upper()); return
    end
    local maximum = self.periodKey == "hourlyDays" and HISTORY_DAYS or HISTORY_DAYS * 24
    local amount = ok and validPeriod(text, maximum) or nil
    if not amount then
      self.periodError:SetText("Enter a whole number from 1 to " .. maximum .. ".")
      return
    end
    self.settings[self.periodKey] = amount
    self.selectedPoint = nil
    editor:Show(false)
    self:saveSettings(); self:loadSelectedHistory(); self:render()
  end)
  c.button("TradePacksRatesPeriodCancel", editor, 270, 48, 108, 26, "Cancel", function() editor:Show(false) end)
  self.periodError = c.label("TradePacksRatesPeriodError", editor, 10, 90, 380, 20, "")
  editor:Show(false)
end

function Watch:createLineChart(id, parent, x, y, width, height, transparent, selectPoint)
  local plot = self.ctx.widget("emptywidget", id, parent, x, y, width, height)
  plot:EnablePick(false)
  if not transparent then
    local background = plot:CreateColorDrawable(0.3, 0.2, 0.05, 0.12, "background")
    background:AddAnchor("TOPLEFT", plot, 0, 0)
    background:AddAnchor("BOTTOMRIGHT", plot, 0, 0)
  end
  local r, g, b = 0.2, 0.53, 0.25
  if transparent then r, g, b = 0.35, 0.95, 0.48 end
  local line = self.ctx.widget("line", id .. "Line", plot, 0, 0, width, height)
  line:EnablePick(false)
  line:SetLineColor(r, g, b, 1)
  line:SetLineThickness(2)
  line:Show(false)
  local zeroLine = self.ctx.widget("line", id .. "BreakEven", plot, 0, 0, width, height)
  zeroLine:EnablePick(false); zeroLine:SetLineColor(0.65, 0.65, 0.65, 0.9); zeroLine:SetLineThickness(1)
  zeroLine:Show(false)
  local chart = {plot = plot, line = line, zeroLine = zeroLine, color = {r, g, b},
    markers = {}, hits = {}, width = width, height = height, id = id,
    transparent = transparent, selectPoint = selectPoint, layers = {}}
  chart.emptyTitle = self.ctx.label(id .. "EmptyTitle", plot, 8, height / 2 - 26, width - 16, 20, "")
  chart.emptyDetail = self.ctx.label(id .. "EmptyDetail", plot, 8, height / 2 - 4, width - 16, 20, "")
  chart.emptyHint = self.ctx.label(id .. "EmptyHint", plot, 8, height / 2 + 22, width - 16, 20, "")
  for _, label in ipairs({chart.emptyTitle, chart.emptyDetail, chart.emptyHint}) do
    label:EnablePick(false); label:Show(false)
    pcall(function()
      label.style:SetFontSize(12)
      if transparent then label.style:SetColor(1, 1, 1, 1); label.style:SetOutline(true) end
    end)
  end
  if selectPoint then
    chart.showRateButton = self.ctx.button(id .. "ShowRate", plot, (width - 180) / 2, height / 2 + 22,
      180, 26, "Show rate graph", function()
        self.settings.metric, self.selectedPoint = "rate", nil
        self:saveSettings(); self:render()
      end)
    chart.showRateButton:Show(false)
  end
  for i = 1, 60 do
    local marker = plot:CreateColorDrawable(r, g, b, 1, "artwork")
    marker:SetExtent(5, 5)
    marker:SetVisible(false)
    chart.markers[i] = marker
    if selectPoint then
      local hit = self.ctx.textButton(id .. "Point" .. i, plot, 0, 0, 14, 14, "", function()
        selectPoint(i)
      end)
      hit:Show(false)
      chart.hits[i] = hit
    end
  end
  chart.layers[1] = {line = line, markers = chart.markers, hits = chart.hits, color = chart.color}
  return chart
end

function Watch:chartLayer(chart, index)
  if chart.layers[index] then return chart.layers[index] end
  local color = SERIES_COLORS[index]
  if chart.transparent then
    color = {math.min(1, color[1] + 0.2), math.min(1, color[2] + 0.2), math.min(1, color[3] + 0.2)}
  end
  local id = chart.id .. "Series" .. index
  local line = self.ctx.widget("line", id, chart.plot, 0, 0, chart.width, chart.height)
  line:EnablePick(false); line:SetLineColor(color[1], color[2], color[3], 1)
  line:SetLineThickness(2); line:Show(false)
  local layer = {line = line, markers = {}, hits = {}, color = color}
  for i = 1, 60 do
    local marker = chart.plot:CreateColorDrawable(color[1], color[2], color[3], 1, "artwork")
    marker:SetExtent(5, 5); marker:SetVisible(false); layer.markers[i] = marker
    if chart.selectPoint then
      local hit = self.ctx.textButton(id .. "Point" .. i, chart.plot, 0, 0, 14, 14, "", function()
        local data = self.comparisonData and self.comparisonData[index]
        local point = data and data.columns[i]
        if point then
          self.settings.pack, self.settings.focusId, self.legacyPack = data.name, data.id, data.name
          self.selectedPoint = {id = data.id, name = data.name, at = point.at, hour = point.hour, mode = self.settings.mode}
          self:saveSettings(); self:render()
        end
      end)
      hit:Show(false); layer.hits[i] = hit
    end
  end
  chart.layers[index] = layer
  return layer
end

function Watch:renderEmptyState(chart, title, detail, canShowRate)
  chart.emptyTitle:SetText(title or ""); chart.emptyTitle:Show(title ~= nil)
  chart.emptyDetail:SetText(detail or ""); chart.emptyDetail:Show(title ~= nil)
  if chart.showRateButton then chart.showRateButton:Show(title ~= nil and canShowRate == true) end
  chart.emptyHint:SetText("Open ... to change graph settings.")
  chart.emptyHint:Show(title ~= nil and canShowRate == true and chart.showRateButton == nil)
end

function Watch:renderLineChart(chart, columns, low, high, layout, layerIndex)
  local layer = self:chartLayer(chart, layerIndex or 1)
  local signature = {tostring(low), tostring(high), self.settings.metric, tostring(layout.minute),
    tostring(layout.hourly), tostring(layout.count), tostring(layout.hours), tostring(layout.step),
    tostring(chart.width), tostring(chart.height)}
  for i = 1, 60 do
    local point = columns[i]
    signature[#signature + 1] = point and (tostring(point.value) .. ":" .. tostring(point.complete)) or "-"
  end
  signature = table.concat(signature, "|")
  if layer.renderSignature == signature then return end
  local segments, previous = {}, nil
  for i, marker in ipairs(layer.markers) do
    local point, hit = columns[i], layer.hits[i]
    local visible = point ~= nil and point.value ~= nil and low ~= nil and high ~= nil and high > low
    marker:SetVisible(visible)
    if hit then hit:Show(visible) end
    if visible then
      if point.complete == false then marker:SetColor(1, 0.65, 0.18, 1)
      else marker:SetColor(layer.color[1], layer.color[2], layer.color[3], 1) end
      local x = self:columnX(i, layout, chart.width)
      -- Native Line coordinates rise from the bottom, as in the auction chart.
      local y = chart.height * math.max(0, math.min(1, (point.value - low) / (high - low)))
      marker:RemoveAllAnchors()
      marker:AddAnchor("CENTER", chart.plot, "BOTTOMLEFT", x, -y)
      if hit then
        hit:SetExtent(layout.minute and 6 or 14, 14)
        hit:RemoveAllAnchors()
        hit:AddAnchor("CENTER", chart.plot, "BOTTOMLEFT", x, -y)
      end
      -- Partial multi-hour buckets still show their observed average, but a
      -- line through them would conceal a gap inside the bucket.
      if previous and previous.complete ~= false and point.complete ~= false then
        segments[#segments + 1] = {beginX = previous.x, beginY = previous.y, endX = x, endY = y}
      end
      previous = {x = x, y = y, complete = point.complete}
    else
      previous = nil -- Missing hours break the line instead of implying observations.
    end
  end
  layer.line:ClearPoints()
  if chart.dashed then
    local dashes = {}
    for _, segment in ipairs(segments) do
      local dx, dy = segment.endX - segment.beginX, segment.endY - segment.beginY
      local length = math.sqrt(dx * dx + dy * dy)
      local steps = math.max(1, math.min(32, math.ceil(length / 12)))
      for step = 0, steps - 1 do
        local a, b = step / steps, math.min(1, (step + 0.55) / steps)
        dashes[#dashes + 1] = {beginX = segment.beginX + dx * a, beginY = segment.beginY + dy * a,
          endX = segment.beginX + dx * b, endY = segment.beginY + dy * b}
      end
    end
    segments = dashes
  end
  if #segments > 0 then layer.line:SetPoints(segments) end
  layer.line:Show(#segments > 0)
  layer.renderSignature = signature
  if layerIndex and layerIndex > 1 then return end
  local showZero = self.settings.metric == "profit" and low ~= nil and high ~= nil and low < high
  chart.zeroLine:ClearPoints()
  if showZero then
    local y = chart.height * (0 - low) / (high - low)
    chart.zeroLine:SetPoints({{beginX = 0, beginY = y, endX = chart.width, endY = y}})
  end
  chart.zeroLine:Show(showZero)
end

function Watch:renderComparison(chart, low, high, layout)
  for i = 1, math.max(#self.comparisonData, #chart.layers) do
    local data = self.comparisonData[i]
    if data then self:applySeriesColor(chart, i, data.id) end
    self:renderLineChart(chart, data and data.columns or {}, low, high, layout, i)
  end
end

function Watch:renderPriceOverlay(chart, entries, layout)
  if self.settings.metric ~= "both" then
    if chart.priceChart then chart.priceChart.plot:Show(false) end
    return
  end
  local prices = chart.priceChart
  if not prices then
    prices = self:createLineChart(chart.id .. "Prices", chart.plot, 0, 0, chart.width, chart.height, true)
    prices.rightAxis, prices.dashed = true, true
    chart.priceChart = prices
  end
  prices.plot:Show(true)
  if prices.width ~= chart.width or prices.height ~= chart.height then
    prices.width, prices.height = chart.width, chart.height
    prices.plot:SetExtent(prices.width, prices.height)
    prices.zeroLine:SetExtent(prices.width, prices.height)
    for _, layer in ipairs(prices.layers) do layer.line:SetExtent(prices.width, prices.height) end
  end
  local columns, low, high = {}, nil, nil
  for i, data in ipairs(entries or {}) do
    columns[i] = {}
    for index, point in pairs(data.columns or {}) do
      local value = point.priceCopper and point.priceCopper / 10000
      columns[i][index] = {value = value, complete = point.complete}
      if value then low, high = math.min(low or value, value), math.max(high or value, value) end
    end
  end
  low, high = self:chartBounds(low, high, "price")
  prices.lowValue, prices.highValue = low, high
  for i = 1, math.max(#columns, #prices.layers) do
    local layer = self:chartLayer(prices, i)
    local source = chart.layers[i]
    if source and layer.priceColor ~= source.color then
      layer.color, layer.renderSignature = source.color, nil
      layer.line:SetLineColor(source.color[1], source.color[2], source.color[3], 0.8)
      layer.line:SetLineThickness(1)
      layer.priceColor = source.color
      for _, marker in ipairs(layer.markers) do marker:SetExtent(3, 3) end
    end
    self:renderLineChart(prices, columns[i] or {}, low, high, layout, i)
  end
  self:renderValueAxis(prices, low, high, "price")
end

function Watch:pointText(point)
  local s, c = self.settings, self.ctx
  local money = point.priceCopper
  if s.metric == "profit" then money = point.profitCopper end
  local value = s.metric ~= "rate" and money ~= nil and ("~" .. c.money(money))
    or string.format("%.1f%%", point.ratio)
  if s.metric == "both" then
    value = string.format("%.1f%%", point.ratio) .. " | " .. (money and ("~" .. c.money(money)) or "price unavailable")
  end
  if s.mode == "hourly" then
    return hourLabel(point.hour) .. ": " .. value .. " | " .. point.n .. " samples / " .. point.days .. " day(s)"
  end
  local at = point.minutes and minuteLabel(point.at, s.offset) or dateLabel(point.at, s.offset, true)
  return at .. ": " .. value .. " | " .. point.observed .. "/" .. (point.minutes or point.hours)
    .. (point.minutes and "m" or "h") .. " observed; " .. point.n .. " samples"
end

function Watch:coverageText(columns, count, layout)
  local partial = 0
  for _, point in pairs(columns) do if point.complete == false then partial = partial + 1 end end
  local text = "Coverage: " .. count .. "/" .. (layout.minute and layout.units or layout.hours)
    .. (layout.minute and "m" or "h") .. " | "
    .. (layout.minute and "1m readings" or layout.hourly and "time-of-day avg" or (layout.step .. "h avg"))
  if partial > 0 then text = text .. " | " .. partial .. " partial" end
  return text
end

function Watch:createUi()
  local c = self.ctx
  local w, resize = c.popup("TradePacksRatesWindow", WIDTH, HEIGHT, nil, true)
  self.window, self.resizeWindow = w, resize
  pcall(function() w:SetCloseOnEscape(false) end)
  local function label(id, x, y, width, text)
    local textLabel = c.label("TradePacksRates" .. id, w, x, y, width, 20, text)
    -- Static text must not block dragging the window beneath it. Interactive
    -- buttons, plot points and pack legends use their own widget helpers.
    textLabel:EnablePick(false)
    return textLabel
  end
  local function button(id, x, y, width, text, fn)
    return c.button("TradePacksRates" .. id, w, x, y, width, 26, text, fn)
  end
  self.title = label("Title", 18, 13, 260, "Trade Rates & Trends")
  self.dock = button("Dock", 290, 12, 92, "Detach", function() self:detach() end)
  button("Close", 392, 12, 30, "X", function()
    self.settings.open = false; self.menu:Show(false); self:saveSettings(); self:visibility()
  end)
  local function startDrag()
    if not self.settings.detached then self:detach() end
    self.dragging = true
    w:StartMoving()
    return true
  end
  local function stopDrag()
    w:StopMovingOrSizing()
    self.dragging = false
    local ok, x, y = pcall(function() return w:GetOffset() end)
    if ok and number(x) and number(y) then
      self.settings.x, self.settings.y = x * c.scale(), y * c.scale()
      self:saveSettings()
    end
  end
  -- The root catches the header, margins, empty plot space and static labels;
  -- child controls retain their own click targets above the background.
  for _, handle in ipairs({w, self.title}) do
    handle:EnablePick(true)
    handle:EnableDrag(true)
    if DC_ALWAYS ~= nil then pcall(function() handle:SetDragCondition(DC_ALWAYS) end) end
    handle:SetHandler("OnDragStart", startDrag)
    handle:SetHandler("OnDragStop", stopDrag)
  end
  label("FromTitle", 16, 56, 60, "From")
  self.fromButton = button("From", 80, 52, 340, "Choose origin", function()
    if not self.origins then self:discover() end
    self:showMenu(self.origins or {}, function(value) self:selectRoute(value.id, nil) end, 82, false, "origin")
  end)
  label("ToTitle", 16, 91, 60, "To")
  self.toButton = button("To", 80, 87, 340, "Choose destination", function()
    self:showMenu(self.outlets or {}, function(value) self:selectRoute(self.settings.from, value.id) end,
      117, false, "destination")
  end)
  self.packButton = button("Pack", 20, 125, 400, "Waiting for pack list", function()
    if self.menu:IsVisible() and self.menuMulti then self.menu:Show(false)
    else self:showPackMenu() end
  end)
  self.rate = label("Rate", 20, 168, 400, "Rate: waiting for a reading")
  pcall(function() self.rate.style:SetFontSize(20) end)
  self.price = label("Price", 20, 201, 400, "Price estimate: unavailable")
  self.age = label("Age", 20, 226, 400, "")
  self.proficiencyButton = button("Proficiency", 20, 250, 198, "Prof: Current", function()
    self:showMenu(PROFICIENCY_OPTIONS, function(value)
      self.settings.proficiencyMode = value.id
      self.nextCommerceAt = 0
      self:saveSettings(); self:render()
    end, 280, false, "proficiency")
  end)
  self.freshnessButton = button("Freshness", 226, 250, 194, "Max freshness: Off", function()
    self.settings.maxFreshness = not self.settings.maxFreshness
    self:saveSettings(); self:render()
  end)
  self.metricButton = button("Metric", 20, 284, 110, "Graph: Rate", function()
    self.settings.metric = self.settings.metric == "rate" and "price"
      or self.settings.metric == "price" and "profit" or self.settings.metric == "profit" and "both" or "rate"
    self:saveSettings(); self:render()
  end)
  self.modeButton = button("Mode", 138, 284, 138, "View: Recent", function()
    self.settings.mode = self.settings.mode == "recent" and "hourly" or "recent"
    self.menu:Show(false); self.periodEditor:Show(false)
    self:saveSettings(); self:loadSelectedHistory(); self:render()
  end)
  self.periodButton = button("Period", 284, 284, 136, "Period: 24h", function() self:showPeriodMenu() end)
  self.timeButton = button("Timezone", 254, 600, 166, "Time: UTC-3", function()
    local options = {}
    for offset = -12, 14 do
      options[#options + 1] = {id = offset, name = "UTC" .. (offset >= 0 and "+" or "") .. offset}
    end
    self:showMenu(options, function(value)
      self.settings.offset = value.id; self:saveSettings(); self:render()
    end, 328, false, "timezone")
  end)
  self.highLabel = label("High", 5, 320, 54, "")
  self.lowLabel = label("Low", 5, 438, 54, "")
  self.chart = self:createLineChart("TradePacksRatesPlot", w, 60, 325, 360, 126, false,
    function(i)
      local data = self.comparisonData and self.comparisonData[1]
      local point = data and data.columns[i]
      if point then
        self.settings.pack, self.settings.focusId, self.legacyPack = data.name, data.id, data.name
        self.selectedPoint = {id = data.id, name = data.name, at = point.at, hour = point.hour, mode = self.settings.mode}
        self:saveSettings(); self:render()
      end
    end)
  self.ticks = {}
  for i, index in ipairs({1, 7, 13, 19, 24}) do
    self.ticks[i] = label("Tick" .. i, 45 + (index - 1) * 15, 454, 46, "")
  end
  self.pointDetail = label("PointDetail", 20, 479, 400, "Click a point for samples. Gaps mean no observations.")
  self.best = label("Best", 20, 509, 400, "Best hour: collecting observations")
  self.coverage = label("Coverage", 20, 535, 400, "")
  self.statusLabel = label("Status", 12, 564, 416, "")
  self.refreshButton = button("Refresh", 20, 600, 98, "Refresh", function()
    if not self.origins then self:discover() end
    self.browsePending = true
    self:query(); self:render()
  end)
  self.graphOnlyButton = button("GraphOnly", 126, 600, 116, "Show graphs", function() self:setGraphOnly(true) end)
  self.collectionButton = button("CollectHidden", 20, 634, 236, "Collect while hidden: Off", function()
    self.settings.collectHidden = not self.settings.collectHidden
    self:saveSettings(); self:render()
    if self.settings.collectHidden then self:query() end
  end)
  self.graphLayoutButton = button("GraphLayout", 264, 634, 156, "Graphs: Separate", function()
    self.settings.graphLayout = self.settings.graphLayout == "combined" and "separate" or "combined"
    self:saveSettings(); self:visibility(); self:render()
  end)
  self.backgroundButton = button("Background", 20, 668, 236, "Background: Transparent", function()
    self:cycleGraphBackground()
  end)
  self.valuesButton = button("Values", 264, 668, 156, "Values: Selected", function()
    self.settings.showRatePrice = not self.settings.showRatePrice
    self:saveSettings(); self:render()
  end)
  self.legend = label("Legend", 10, 702, 420, "Amber: partial interval | Gaps: no observations")
  pcall(function() self.legend.style:SetFontSize(12) end)

  local menu = c.widget("window", "TradePacksRatesMenu", nil, 12, 84, 540, 252)
  self.menu = menu
  pcall(function() menu:SetDrawPriority(100); menu:EnablePick(true) end)
  pcall(function() menu:SetTitleText(""); menu:SetCloseOnEscape(true) end)
  local bg = menu:CreateColorDrawable(c.dark and 0.08 or 0.96, c.dark and 0.07 or 0.89,
    c.dark and 0.06 or 0.69, 1, "background")
  bg:AddAnchor("TOPLEFT", menu, 0, 0); bg:AddAnchor("BOTTOMRIGHT", menu, 0, 0)
  self.menuNameLabels, self.menuRouteLabels = {}, {}
  for i = 1, 8 do
    self.menuRows[i] = c.textButton("TradePacksRatesMenuRow" .. i, menu, 8, 4 + (i - 1) * 27, 524, 25, "", function()
      local option = self.menuRows[i].option
      if not self.menuMulti then menu:Show(false) end
      if option then self.menuSelect(option) end
    end)
    self.menuNameLabels[i] = c.label("TradePacksRatesMenuName" .. i, self.menuRows[i], 0, 0, 524, 20, "")
    self.menuRouteLabels[i] = c.label("TradePacksRatesMenuRoute" .. i, self.menuRows[i], 0, 21, 524, 18, "")
    self.menuNameLabels[i]:EnablePick(false); self.menuRouteLabels[i]:EnablePick(false)
    pcall(function() self.menuRouteLabels[i].style:SetFontSize(12) end)
  end
  self.menuPrev = c.button("TradePacksRatesMenuPrev", menu, 8, 222, 72, 25, "Prev", function()
    self.menuPage = self.menuPage - 1; self:renderMenu()
  end)
  self.menuPageLabel = c.label("TradePacksRatesMenuPage", menu, 90, 224, 350, 20, "")
  self.menuNext = c.button("TradePacksRatesMenuNext", menu, 456, 222, 72, 25, "Next", function()
    self.menuPage = self.menuPage + 1; self:renderMenu()
  end)
  self.menuHelp = c.label("TradePacksRatesMenuHelp", menu, 8, 259, 430, 20, "")
  pcall(function() self.menuHelp.style:SetFontSize(12) end)
  self.menuDone = c.button("TradePacksRatesMenuDone", menu, 456, 256, 72, 25, "Done", function() menu:Show(false) end)
  self.menuDone:Show(false); self.menuHelp:Show(false)
  menu:Show(false)
  self:createPeriodEditor()
  self:place()
end

function Watch:layoutComparison(count)
  local extra = count > 1 and count * 38 + 4 or 0
  if self.comparisonExtra == extra then return end
  self.comparisonExtra, self.panelHeight = extra, HEIGHT + extra
  if self.resizeWindow then self.resizeWindow(self.panelHeight)
  else self.window:SetExtent(WIDTH, self.panelHeight) end
  for _, entry in ipairs({{self.pointDetail, 20, 479}, {self.best, 20, 509},
    {self.coverage, 20, 535}, {self.statusLabel, 12, 564}, {self.refreshButton, 20, 600},
    {self.graphOnlyButton, 126, 600}, {self.timeButton, 254, 600},
    {self.collectionButton, 20, 634}, {self.graphLayoutButton, 264, 634},
    {self.backgroundButton, 20, 668}, {self.valuesButton, 264, 668}, {self.legend, 10, 702}}) do
    entry[1]:RemoveAllAnchors(); entry[1]:AddAnchor("TOPLEFT", self.window, entry[2], entry[3] + extra)
  end
  self:place()
end

function Watch:renderSeriesLegends()
  local count = #self.comparisonData
  self:layoutComparison(count)
  self.seriesLegend = self.seriesLegend or {}
  self.seriesRouteLabels = self.seriesRouteLabels or {}
  for i = 1, math.max(count, #self.seriesLegend) do
    local data = self.comparisonData[i]
    if count > 1 and data and not self.seriesLegend[i] then
      self.seriesLegend[i] = self.ctx.textButton("TradePacksRatesSeriesLegend" .. i,
        self.window, 16, 479 + (i - 1) * 38, 408, 36, "", function()
          local entry = self.comparisonData[i]
          if entry then self:setFocusPack(entry.id) end
        end)
      pcall(function()
        self.seriesLegend[i].style:SetFontSize(12)
      end)
      self.seriesRouteLabels[i] = self.ctx.label("TradePacksRatesSeriesRoute" .. i,
        self.window, 16, 499 + (i - 1) * 38, 408, 16, "")
      self.seriesRouteLabels[i]:EnablePick(false)
      pcall(function() self.seriesRouteLabels[i].style:SetFontSize(11) end)
      self.seriesLegend[i]:SetExtent(408, 20)
    end
    local full = self.seriesLegend[i]
    if full then
      local visible = count > 1 and data ~= nil
      full:Show(visible)
      self.seriesRouteLabels[i]:Show(visible)
      if visible then
        self.seriesRouteLabels[i]:SetText(data.routeLabel)
        local value = "waiting"
        if self.settings.metric == "profit" and data.cost == nil then value = "costs incomplete"
        elseif self.settings.metric ~= "rate" and not data.pricing.base then value = "no payout price"
        elseif self.settings.metric ~= "rate" and not data.pricing.skill then value = "waiting for Prof"
        elseif data.quote then
          if self.settings.metric == "rate" then value = string.format("%.1f%%", data.quote.ratio)
          elseif data.quotePrice then
            value = "~" .. self.ctx.money(data.quotePrice - (self.settings.metric == "profit" and data.cost or 0))
          end
          if self.ctx.now() - data.quote.at > self:staleAfter() then value = value .. " stale" end
        end
        if self.settings.metric == "profit" and data.costs and data.costs.stalePrices then
          value = value .. " | cached costs"
        end
        if data.count == 0 then value = value .. " | no history" end
        if self.settings.showRatePrice or self.settings.metric == "both" then value = self:ratePriceText(data) end
        local prefix = tostring(i) .. (data.id == self.settings.focusId and "* " or ". ")
        self:setGraphLabel(full, prefix .. data.name, 408, 12, " | " .. value)
        local color = self:seriesColor(data.id, i, false)
        pcall(function()
          full.style:SetColor(color[1], color[2], color[3], 1)
        end)
      end
    end
  end
end

function Watch:createOverlay()
  self.miniGraphs = {}
  local graph = self:createMiniGraph(1)
  -- Retain the first graph's aliases for the existing single-pack integrations.
  self.overlay, self.overlayTitle, self.overlayQuote = graph.window, graph.title, graph.quoteLabel
  self.overlayHigh, self.overlayLow, self.overlayChart = graph.high, graph.low, graph.chart
  self.overlayTicks, self.overlayCoverage, self.overlayStatus = graph.ticks, graph.coverage, graph.status
  self:place()
end

function Watch:createMiniGraph(index)
  local c = self.ctx
  local prefix = "TradePacksRateOverlay" .. (index == 1 and "" or tostring(index))
  local w = c.widget("window", prefix, nil, 180, 120, WIDTH, OVERLAY_HEIGHT)
  local graph = {window = w, ticks = {}, index = index}
  self.miniGraphs[index] = graph
  pcall(function() w:SetTitleText(""); w:SetCloseOnEscape(false); w:EnablePick(false) end)
  self:applyGraphBackground(graph)
  local function label(id, x, y, width, text)
    local l = c.label(prefix .. id, w, x, y, width, 18, text)
    pcall(function() l.style:SetColor(1, 1, 1, 1); l.style:SetOutline(true); l:EnablePick(false) end)
    return l
  end
  graph.title = label("Title", 28, 0, 330, "Trade rate graph - drag to move")
  pcall(function() graph.title.style:SetFontSize(12) end)
  pcall(function() graph.title:EnablePick(true); graph.title:EnableDrag(true) end)
  if DC_ALWAYS ~= nil then pcall(function() graph.title:SetDragCondition(DC_ALWAYS) end) end
  graph.title:SetHandler("OnDragStart", function()
    graph.dragging, graph.dragName = true, graph.id
    w:StartMoving()
    return true
  end)
  graph.title:SetHandler("OnDragStop", function()
    w:StopMovingOrSizing()
    graph.dragging = false
    local ok, x, y = pcall(function() return w:GetOffset() end)
    if ok and number(x) and number(y) and (not graph.dragName or graph.dragName == graph.id) then
      x, y = x * c.scale(), y * c.scale()
      if graph.id then self.settings.graphPositions[graph.id] = {x = x, y = y, used = c.now()} end
      if index == 1 then self.settings.graphX, self.settings.graphY = x, y end
      self:saveSettings()
    elseif graph.dragName ~= graph.id then
      -- A reply can remove a pack while its slot is being dragged. Restore the
      -- replacement pack's position instead of inheriting the previous drag.
      if self:placeMiniGraph(graph, index) then self:saveSettings() end
    end
    graph.dragName = nil
  end)
  graph.expand = c.textButton(prefix .. "Expand", w, 0, 0, 26, 18, "...",
    function() self:setGraphOnly(false, graph) end)
  graph.backgroundButton = c.textButton(prefix .. "Background", w, 360, 0, 30, 18, "BG",
    function() self:cycleGraphBackground() end)
  pcall(function() graph.backgroundButton.style:SetColor(1, 1, 1, 1) end)
  graph.close = c.textButton(prefix .. "Close", w, 394, 0, 24, 18, "x",
    function() self:closeMiniGraph(graph) end)
  pcall(function() graph.expand.style:SetColor(1, 1, 1, 1); graph.close.style:SetColor(1, 1, 1, 1) end)
  graph.routeLabel = label("Route", 10, 22, 420, "")
  pcall(function() graph.routeLabel.style:SetFontSize(12) end)
  graph.quoteLabel = label("Quote", 10, 44, 420, "")
  pcall(function() graph.quoteLabel.style:SetFontSize(12) end)
  graph.high = label("High", 0, 44, 58, "")
  graph.low = label("Low", 0, 151, 58, "")
  graph.chart = self:createLineChart(prefix .. "Plot", w, 60, 72, 360, 120, true)
  local color = SERIES_COLORS[index]
  color = {math.min(1, color[1] + 0.2), math.min(1, color[2] + 0.2), math.min(1, color[3] + 0.2)}
  graph.chart.color, graph.chart.layers[1].color = color, color
  graph.chart.line:SetLineColor(color[1], color[2], color[3], 1)
  for i, index in ipairs({1, 7, 13, 19, 24}) do
    graph.ticks[i] = label("Tick" .. i, 44 + (index - 1) * 15, 194, 46, "")
  end
  graph.coverage = label("Coverage", 10, 217, 420, "")
  pcall(function() graph.coverage.style:SetFontSize(12) end)
  graph.status = label("Status", 10, 240, 420, "")
  pcall(function() graph.status.style:SetFontSize(12) end)
  self:addGraphControls(graph, prefix)
  w:Show(false)
  return graph
end

function Watch:renderMiniGraph(graph, data)
  self:layoutFloatingGraph(graph)
  self:applySeriesColor(graph.chart, 1, graph.id, graph.index)
  local s, c = self.settings, self.ctx
  local columns, count, layout
  if data then columns, count, layout = data.columns, data.count, data.layout
  else
    local unusedBest
    columns, unusedBest, count, layout = self:chartData(graph.entry)
  end
  local quote, pricing = data and data.quote, data and data.pricing or {}
  local cost, costs, quotePrice = data and data.cost, data and data.costs, data and data.quotePrice
  local low, high
  for _, point in pairs(columns) do
    if point.value then low, high = math.min(low or point.value, point.value), math.max(high or point.value, point.value) end
  end
  low, high = self:chartBounds(low, high)
  graph.quoteAt, graph.lowValue, graph.highValue = quote and quote.at, low, high
  local suffix = quote and ("Rate: " .. string.format("%.1f%%", quote.ratio)) or "Waiting for a reading"
  if s.metric == "price" and quotePrice then suffix = "Price: ~" .. c.money(quotePrice) end
  if s.metric == "profit" then
    suffix = cost ~= nil and quotePrice and ("Est. profit ~" .. c.money(quotePrice - cost)) or "Costs incomplete"
  end
  if s.metric ~= "rate" and not pricing.base then suffix = "No price estimate"
  elseif s.metric ~= "rate" and not pricing.skill then suffix = "Prof unavailable"
  elseif s.metric == "profit" and cost ~= nil and not quotePrice then suffix = "Waiting for a reading" end
  if quote and c.now() - quote.at > self:staleAfter() then suffix = suffix .. " stale" end
  if s.showRatePrice or s.metric == "both" then
    suffix = self:ratePriceText(data)
    if quote and c.now() - quote.at > self:staleAfter() then suffix = suffix .. " stale" end
  end
  local period = s.mode == "recent" and periodLabel(s.recentHours) or (s.hourlyDays .. "d avg")
  local bothValues = s.showRatePrice or s.metric == "both"
  local tail = " | " .. (bothValues and (quote and string.format("%.1f%%", quote.ratio) or "rate unavailable")
    or suffix:gsub("^Rate: ", ""))
  if s.metric == "profit" and costs and costs.stalePrices then tail = tail .. " | cached costs" end
  local compactName = (graph.name or "Choose pack") .. (graph.entry and (" | " .. self:routeLabel(graph.entry)) or "")
  self:setGraphLabel(graph.title, graph.compact and compactName or (graph.name or "Choose a pack in ..."),
    graph.width - 230, graph.font, (graph.compact or bothValues) and tail or "")
  self:setGraphLabel(graph.routeLabel, graph.entry and self:routeLabel(graph.entry) or "Choose From/To in the controls",
    graph.width - 20, graph.font)
  local bodyChars = math.max(12, math.floor((graph.width - 20) / (graph.font * 0.55)))
  self:setGraphLabel(graph.quoteLabel, suffix .. " | " .. (s.mode == "recent" and periodLabel(s.recentHours)
    or (s.hourlyDays .. "d avg")) .. " UTC" .. s.offset, graph.width - 20, graph.font)
  if bothValues then
    self:setGraphLabel(graph.quoteLabel, quotePrice and ("Price: ~" .. c.money(quotePrice))
      or (not pricing.base and "Price: no payout price" or "Price: unavailable"), graph.width - 20, graph.font)
  end
  graph.high:SetText(low and string.format("%.1f%s", high, s.metric ~= "rate" and "g" or "%") or "")
  graph.low:SetText(low and string.format("%.1f%s", low, s.metric ~= "rate" and "g" or "%") or "")
  graph.high:Show(false); graph.low:Show(false)
  local coverage = self:coverageText(columns, count, layout) .. " | own scale"
  if s.metric == "profit" then
    coverage = coverage .. (costs and costs.stalePrices and " | cached costs" or " | 0g: break-even")
  end
  graph.coverage:SetText(c.fit(coverage, bodyChars))
  if s.metric == "both" then graph.coverage:SetText("Solid: % left | Dashed: est. price right") end
  local title, detail, showRate
  if low == nil then
    if not graph.name then title, detail = "Choose a pack to plot", "Open ... to choose a route and packs."
    elseif s.metric ~= "rate" and not pricing.base then
      title, detail, showRate = "No payout price for this pack", "The recorded payout percentage is still available.", true
    elseif s.metric ~= "rate" and not pricing.skill then
      title, detail, showRate = "Waiting for Commerce data", "Choose a fixed Prof value or show payout rates.", true
    elseif s.metric == "profit" and cost == nil then
      local missing, seen = {}, {}
      for _, component in ipairs(costs and costs.missingComponents or {}) do
        local name = component:match("^([^:]+)")
        if name and not seen[name] then missing[#missing + 1], seen[name] = name, true end
      end
      title, showRate = "Profit unavailable: costs incomplete", true
      detail = #missing > 0 and ("Missing costs: " .. table.concat(missing, ", "))
        or "Configure costs in the ledger's cost editors."
    elseif self.historyLoading > 0 then title, detail = "Loading this period...", "Reading saved observations."
    elseif layout.minute then title, detail = "No minute readings in this period", "Keep collection on to build recent history."
    else title, detail = "No readings in this period", "Try a longer period or keep collecting." end
  end
  self:renderValueAxis(graph.chart, low, high)
  self:renderLineChart(graph.chart, columns, low, high, layout)
  self:renderPriceOverlay(graph.chart, data and {data} or {}, layout)
  self:renderEmptyState(graph.chart, title, detail, showRate)
  self:renderTicks(graph.ticks, graph.chart, layout)
  self:styleFloatingText(graph)
end

function Watch:render()
  if not self:isVisible() then return end
  self:syncMiniGraphs()
  local s, c = self.settings, self.ctx
  local entries = self:selectedEntries()
  local focus = self:routeEntry()
  local origin, outlet = contains(self.origins or {}, s.from), contains(self.outlets or {}, s.to)
  c.setButtonText(self.fromButton, origin and origin.name or "Choose origin")
  c.setButtonText(self.toButton, outlet and outlet.name or "Choose destination")
  c.setButtonText(self.packButton, #entries > 1 and ("Packs: " .. #entries .. " | Details: " .. c.fit(s.pack, 30))
    or s.pack and c.fit(s.pack, 48) or "Waiting for pack list")
  c.setButtonText(self.dock, s.detached and "Dock" or "Detach")
  c.setButtonText(self.modeButton, s.mode == "recent" and "View: Recent" or "Time of day")
  c.setButtonText(self.periodButton, "Period: " .. (s.mode == "recent" and periodLabel(s.recentHours) or (s.hourlyDays .. "d")))
  c.setButtonText(self.metricButton, s.metric == "profit" and "Graph: Profit"
    or s.metric == "price" and "Graph: Price" or s.metric == "both" and "Graph: Both" or "Graph: Rate")
  c.setButtonText(self.collectionButton, s.collectHidden and "Collect while hidden: On" or "Collect while hidden: Off")
  c.setButtonText(self.graphLayoutButton, s.graphLayout == "combined" and "Graphs: Combined" or "Graphs: Separate")
  c.setButtonText(self.valuesButton, s.showRatePrice and "Values: Rate + Price" or "Values: Selected")
  c.setButtonText(self.backgroundButton, "Background: " ..
    ({transparent = "Transparent", shaded = "Shaded (50%)", dark = "Dark (90%)"})[s.graphBackground])
  c.setButtonText(self.timeButton, "Time: UTC" .. (s.offset >= 0 and "+" or "") .. s.offset)
  local quote, pricing = self:latestQuote(focus), self:priceContext(focus or s.pack)
  local costs = s.metric == "profit" and c.costEstimate and c.costEstimate(s.pack) or nil
  local cost = costs and number(costs.totalCopper)
  if cost and cost < 0 then cost = nil end
  local proficiencyText = "Prof: OFF"
  if s.proficiencyMode == "current" then
    proficiencyText = "Prof: Current / " .. (pricing.skill and string.format("%.0f", pricing.skill) or "waiting")
  elseif s.proficiencyMode ~= "off" then
    proficiencyText = "Prof: " .. string.format("%.0fk", tonumber(s.proficiencyMode) / 1000)
  end
  c.setButtonText(self.proficiencyButton, proficiencyText)
  c.setButtonText(self.freshnessButton, s.maxFreshness and "Max freshness: On" or "Max freshness: Off")
  if not quote then
    local rows = self:historyRows()
    local last = rows[#rows]
    if last then quote = {ratio = last.last, at = last.lastAt} end
  end
  local quotePrice = quote and self:estimatePrice(pricing, quote.ratio)
  self.displayedQuoteAt = quote and quote.at or nil
  if quote then
    local age = math.max(0, self.ctx.now() - quote.at)
    self.rate:SetText((age > self:staleAfter() and "Last known rate: " or "Rate: ") .. string.format("%.1f%%", quote.ratio))
    self.price:SetText(quotePrice and ("Price estimate: " .. c.money(quotePrice))
      or (not pricing.base and "Price estimate: no reference price for this pack"
        or "Price estimate: waiting for Commerce data"))
  else
    self.rate:SetText("Rate: waiting for a reading")
    self.price:SetText("Price estimate: waiting for a reading")
  end
  if s.metric == "profit" then
    if not pricing.base then self.price:SetText("Profit estimate: no reference payout price")
    elseif not pricing.skill then self.price:SetText("Profit estimate: waiting for Commerce data")
    elseif cost == nil then self.price:SetText("Profit estimate: costs incomplete")
    elseif quotePrice then
      self.price:SetText(c.fit("Est. profit: " .. c.money(quotePrice - cost) .. " | Cost: " .. c.money(cost), 62))
    else self.price:SetText("Profit estimate: waiting for a reading") end
  end
  local columns, best, count, layout = self:chartData()
  self.chartColumns = columns
  self.comparisonData = {}
  for _, item in ipairs(entries) do
    local name = item.name
    local data
    if item.id == s.focusId then
      data = {name = name, columns = columns, best = best, count = count, layout = layout,
        pricing = pricing, costs = costs, cost = cost, quote = quote, quotePrice = quotePrice}
    else
      local packColumns, packBest, packCount, packLayout = self:chartData(item)
      local packPricing = self:priceContext(item)
      local packCosts = s.metric == "profit" and c.costEstimate and c.costEstimate(name) or nil
      local packCost = packCosts and number(packCosts.totalCopper)
      if packCost and packCost < 0 then packCost = nil end
      local packQuote = self:latestQuote(item)
      if not packQuote then
        local rows = self:historyRows(item)
        local last = rows[#rows]
        if last then packQuote = {ratio = last.last, at = last.lastAt} end
      end
      data = {name = name, columns = packColumns, best = packBest, count = packCount, layout = packLayout,
        pricing = packPricing, costs = packCosts, cost = packCost, quote = packQuote,
        quotePrice = packQuote and self:estimatePrice(packPricing, packQuote.ratio)}
    end
    data.id, data.from, data.to, data.routeLabel = item.id, item.from, item.to, self:routeLabel(item)
    self.comparisonData[#self.comparisonData + 1] = data
  end
  local low, high
  for _, data in ipairs(self.comparisonData) do
    for _, point in pairs(data.columns) do
      point.priceCopper = s.metric ~= "rate" and self:estimatePrice(data.pricing, point.ratio) or nil
      point.profitCopper = s.metric == "profit" and data.cost ~= nil and point.priceCopper
        and (point.priceCopper - data.cost) or nil
      local value
      if s.metric == "profit" then value = point.profitCopper and point.profitCopper / 10000
      elseif s.metric == "price" then value = point.priceCopper and point.priceCopper / 10000
      else value = point.ratio end
      point.value = value
      if value then low, high = math.min(low or value, value), math.max(high or value, value) end
    end
  end
  self.chartLow, self.chartHigh = low, high
  low, high = self:chartBounds(low, high)
  if low then
    self.highLabel:SetText(string.format("%.1f%s", high, s.metric ~= "rate" and "g" or "%"))
    self.lowLabel:SetText(string.format("%.1f%s", low, s.metric ~= "rate" and "g" or "%"))
  else self.highLabel:SetText(""); self.lowLabel:SetText("") end
  self.highLabel:Show(false); self.lowLabel:Show(false)
  local emptyTitle, emptyDetail, canShowRate
  if low == nil then
    if s.metric ~= "rate" and not pricing.base then
      emptyTitle, emptyDetail, canShowRate = "No payout price for this pack", "The recorded payout percentage is still available.", true
    elseif s.metric ~= "rate" and not pricing.skill then
      emptyTitle, emptyDetail, canShowRate = "Waiting for Commerce data", "Choose a fixed Prof value or show payout rates.", true
    elseif s.metric == "profit" and cost == nil then
      local missing, seen = {}, {}
      for _, component in ipairs(costs and costs.missingComponents or {}) do
        local name = component:match("^([^:]+)")
        if name and not seen[name] then missing[#missing + 1] = name; seen[name] = true end
      end
      emptyTitle, canShowRate = "Profit unavailable: costs incomplete", true
      emptyDetail = #missing > 0 and ("Missing costs: " .. table.concat(missing, ", "))
        or "Configure costs in the ledger's cost editors."
    elseif self.historyLoading > 0 then
      emptyTitle, emptyDetail = "Loading this period...", "Reading saved observations."
    elseif layout.minute then
      emptyTitle, emptyDetail = "No minute readings in this period", "Keep collection on to build recent history."
    else
      emptyTitle, emptyDetail = "No readings in this period", "Try a longer period or keep collecting."
    end
  end
  if #entries > 1 and emptyTitle then
    emptyTitle = "No comparable points in this period"
    emptyDetail = "See each pack's legend for prices and missing data."
    canShowRate = s.metric ~= "rate"
  end
  if self.window:IsVisible() then
    local width = s.metric == "both" and 304 or 360
    if self.chart.width ~= width then
      self.chart.width = width; self.chart.plot:SetExtent(width, self.chart.height)
      self.chart.zeroLine:SetExtent(width, self.chart.height)
      for _, layer in ipairs(self.chart.layers) do layer.line:SetExtent(width, self.chart.height) end
    end
    self:renderValueAxis(self.chart, low, high)
    self:renderEmptyState(self.chart, emptyTitle, emptyDetail, canShowRate)
    self:renderComparison(self.chart, low, high, layout)
    self:renderPriceOverlay(self.chart, self.comparisonData, layout)
    self:renderTicks(self.ticks, self.chart, layout)
  end
  self.best:SetText(best and ("Best observed hour: " .. hourLabel(best.hour) .. " - "
    .. hourLabel(best.hour + 1) .. " (" .. string.format("%.1f%%", best.ratio) .. ")")
    or (layout.minute and "Best-hour comparison: choose Time of day."
      or "Best hour: needs 3 days at 2 different hours."))
  local coverage = self:coverageText(columns, count, layout)
  self.coverage:SetText(self.historyLoading > 0 and "Loading saved observations..."
    or coverage)
  self.legend:SetText(s.metric == "profit" and
    ((costs and costs.stalePrices and "Profit uses cached costs" or "Profit uses current costs")
      .. " | 0g: break-even | Amber: partial")
    or "Amber: partial interval | Gaps: no observations")
  if #entries > 1 then
    local cached = false
    for _, data in ipairs(self.comparisonData) do
      if data.costs and data.costs.stalePrices then cached = true; break end
    end
    self.legend:SetText("* Details pack | Amber: partial | "
      .. (s.metric == "profit" and (cached and "Uses cached costs; 0g: break-even" or "Current costs; 0g: break-even")
        or "Gaps: no observations"))
  end
  if s.metric == "both" then self.legend:SetText("Solid: rate % (left) | Dashed: est. price (right)") end
  if s.metric ~= "rate" and not pricing.base then
    self.pointDetail:SetText("No reference price; choose Graph: Rate for this pack.")
  elseif s.metric ~= "rate" and not pricing.skill then
    self.pointDetail:SetText("Commerce unavailable; choose a fixed Prof value.")
  elseif s.metric == "profit" and cost == nil then
    self.pointDetail:SetText(c.fit((costs and costs.missing) or "Set materials, transport and labor costs in the ledger.", 64))
  elseif layout.minute and count == 0 then
    self.pointDetail:SetText("No minute readings yet; keep collection on to build history.")
  else
    local selected
    if self.selectedPoint and self.selectedPoint.mode == s.mode
      and (not self.selectedPoint.id or self.selectedPoint.id == s.focusId)
      and (not self.selectedPoint.name or self.selectedPoint.name == s.pack) then
      for _, point in pairs(columns) do
        if point.value ~= nil and (s.mode == "hourly" and point.hour == self.selectedPoint.hour
          or s.mode == "recent" and point.at == self.selectedPoint.at) then selected = point; break end
      end
    end
    self.pointDetail:SetText(selected and self:pointText(selected) or "Click a point for coverage. Amber points have gaps.")
  end
  for index, graph in ipairs(self.miniGraphs or {}) do
    if graph.window:IsVisible() then self:renderMiniGraph(graph, self.comparisonData[index]) end
  end
  self:renderCombinedGraph()
  if self.window:IsVisible() then self:renderSeriesLegends() end
  self:renderStatus()
  self:raisePicker()
  self.renderedRevision = self.revision
  self.nextDirtyRenderAt = self.ctx.now() + 1
end
