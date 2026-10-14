-- Run from Addon: lua TradePacks/tests/test_rate_watch.lua
local now = 20000 * 86400 + 20 * 3600
local saved, widgets, errors, queries, importedObjects = {}, {}, {}, {}, {}
local importedApis, abilityReads = {}, 0
local abilityInfos = {{name = "Commerce", point = 0, modifyPoint = 0}}
local failDayWrite = false
local requestResult = 30000 -- The native API returns a cooldown in milliseconds.
local reads, writes, clears = 0, 0, 0
local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}; for k, value in pairs(v) do t[k] = copy(value) end; return t
end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
ADDON = {
  ImportAPI = function(_, id) importedApis[id] = true end,
  ImportObject = function(_, id) importedObjects[id] = true end,
  LoadData = function(_, key) reads = reads + 1; return copy(saved[key]) end,
  SaveData = function(_, key, value)
    writes = writes + 1; saved[key] = copy(value)
    if failDayWrite and key:match("^TradePacksRates_.*[AB]$") then saved[key].hours = nil end
  end,
  ClearData = function(_, key) clears = clears + 1; saved[key] = nil end
}
local Widget = {}
Widget.__index = function(_, key) return Widget[key] or function() end end
local drawOrder = 0
local function widget(kind, name, parent, x, y, width, height)
  assert(kind ~= "line" or importedObjects[48], "Line widget created before its object import")
  drawOrder = drawOrder + 1
  local w = setmetatable({kind = kind, name = name, parent = parent, x = x, y = y,
    width = width, height = height, visible = true, handlers = {}, draws = {}, events = {},
    drawOrder = drawOrder}, Widget)
  w.style = setmetatable({}, Widget); widgets[name] = w; return w
end
function Widget:SetHandler(event, handler) self.handlers[event] = handler end
function Widget:RegisterEvent(event) self.events[event] = true end
function Widget:SetText(text) self.text = text end
function Widget:GetText() return self.text end
function Widget:SetExtent(width, height) self.width, self.height = width, height end
function Widget:Show(visible) self.visible = visible end
function Widget:SetVisible(visible) self.visible = visible end
function Widget:IsVisible() return self.visible end
function Widget:GetOffset() return self.x, self.y end
function Widget:GetWidth() return self.width end
function Widget:GetHeight() return self.height end
function Widget:AddAnchor(...) self.anchor = {...} end
function Widget:RemoveAllAnchors() self.anchor = nil end
function Widget:EnablePick(pick) self.pick = pick end
function Widget:EnableDrag(drag) self.drag = drag end
function Widget:Raise() drawOrder = drawOrder + 1; self.drawOrder = drawOrder end
function Widget:SetPoints(points) self.points = copy(points) end
function Widget:ClearPoints() self.points = {} end
function Widget:SetLineColor(...) self.color = {...} end
function Widget:SetColor(...) self.color = {...} end
function Widget:SetLineThickness(thickness) self.thickness = thickness end
function Widget:CreateColorDrawable(r, g, b, alpha, layer)
  local d = widget("drawable", self.name .. "Draw" .. (#self.draws + 1), self, 0, 0, 0, 0)
  d.layer, d.alpha = layer, alpha; self.draws[#self.draws + 1] = d; return d
end
local ledger = widget("window", "ledger", nil, 30, 30, 660, 864)
UIParent = {GetScreenWidth = function() return 1920 end, GetScreenHeight = function() return 1080 end}
local function label(name, parent, x, y, width, height, text)
  local w = widget("label", name, parent, x, y, width, height); w:SetText(text); return w
end
local function button(name, parent, x, y, width, height, text, action)
  local w = label(name, parent, x, y, width, height, text); w:SetHandler("OnClick", action); return w
end
local ctx = {
  ledger = ledger, widget = widget, label = label, editbox = label, button = button, textButton = button,
  setButtonText = function(w, text) w:SetText(text) end, now = function() return math.floor(now) end,
  scale = function() return 1 end, sameData = equal,
  fit = function(text, n) return #text > n and text:sub(1, n - 3) .. "..." or text end,
  money = function(copper) return string.format("%.2fg", copper / 10000) end,
  popup = function(name, width, height)
    local w = widget("window", name, nil, 100, 150, width, height); w:Show(false); return w
  end,
  reportSaveError = function(kind, err) errors[#errors + 1] = kind .. ":" .. tostring(err) end
}
local packName = "Halcyona Preserved Gilda Specialty"
TWOCROWNS_PRICE = {[packName] = {3000}}
X2Ability = {GetAllMyActabilityInfos = function()
  assert(importedApis[3], "Commerce queried before the Ability import")
  abilityReads = abilityReads + 1
  return copy(abilityInfos)
end}
X2Store = {
  GetProductionZoneGroups = function() return {
    {id = 22, zoneGroupName = "Halcyona"}, {id = 20, zoneGroupName = "Cinderstone"}} end,
  GetSellableZoneGroups = function() return {{id = 8, zoneGroupName = "Two Crowns"},
    {id = 5, zoneGroupName = "Solzreed"}} end,
  GetSpecialtyRatioBetween = function(_, from, to)
    queries[#queries + 1] = {from, to, at = math.floor(now)}
    return requestResult
  end
}
local externalCalls = 0
checkPackRatio = function() externalCalls = externalCalls + 1; return "unchanged return" end
dofile("TradePacks/MinuteHistory.lua")
dofile("TradePacks/RateRoutes.lua")
dofile("TradePacks/RateChart.lua")
dofile("TradePacks/RateCombined.lua")
dofile("TradePacks/RateWatch.lua")
local function newWatch()
  return TradePacksRateWatch.new(ctx)
end
local function drain(watch)
  local i = 0
  while watch.head <= watch.tail and i < 1000 do watch:workOne(); i = i + 1 end
  assert(i < 1000, "background queue failed to drain")
end
local function reply(watch, ratio)
  assert(watch.driver.events.SPECIALTY_RATIO_BETWEEN_INFO, "rate response listener was not registered")
  return watch.driver.handlers.OnEvent(watch.driver, "SPECIALTY_RATIO_BETWEEN_INFO",
    {{itemInfo = {name = packName}, ratio = ratio},
    {itemInfo = {name = "Pack without price"}, ratio = ratio - 10}})
end
local function choosePeriod(watch, id)
  watch.periodButton.handlers.OnClick()
  for index, option in ipairs(watch.menuOptions) do
    if option.id == id then
      while watch.menuPage < math.floor((index - 1) / 8) + 1 do
        widgets.TradePacksRatesMenuNext.handlers.OnClick()
      end
      watch.menuRows[(index - 1) % 8 + 1].handlers.OnClick()
      return
    end
  end
  error("period missing: " .. tostring(id))
end

-- Geometry/formula fixtures below inspect both chart renderers together.
-- Keep both mock surfaces visible for these comparisons; exclusive runtime
-- visibility and hidden-overview work are covered by test_rate_mini_graphs.lua.
local function showBothChartFixtures(watch)
  watch:setGraphOnly(true)
  watch.window:Show(true)
  watch:render()
end

local watch = newWatch()
assert(not watch.window:IsVisible() and not watch.overlay:IsVisible())
for i = 1, 10 do now = now + 1; watch:tick(1) end
assert(#queries == 0, "closed rates panel queried the server")
assert(abilityReads == 0, "closed rates panel polled Commerce")
assert(watch.settings.proficiencyMode == "current" and not watch.settings.maxFreshness)
watch.settings.from, watch.settings.to = 22, 8
watch:toggle()
assert(watch.window:IsVisible() and #queries == 1)
assert(reply(watch, 130), "valid owned reply was rejected")
assert(not reply(watch, 125), "unsolicited reply was accepted")
drain(watch)
assert(watch.settings.pack == packName and watch.rate.text == "Rate: 130.0%")
assert(watch.price.text == "Price estimate: 39.00g", "reference price applied ratio incorrectly")
local series = watch:seriesFor(22, 8, packName)
local day = math.floor(now / 86400)
local entry = watch:loadDay(series, day)
local bucket = entry.data.hours[20]
assert(bucket.n == 1)
watch:sample(series, now + 10, 100)
assert(bucket.n == 1, "repeated same-minute poll biased history")
for i = 1, 20 do watch:query() end
assert(#queries == 1, "Refresh clicks bypassed the query interval")

-- Docked visibility follows the ledger; detached graphs remain open.
ledger:Show(false); watch:visibility()
assert(not watch.window:IsVisible())
ledger:Show(true); watch:visibility(); watch:detach()
ledger:Show(false); watch:visibility()
assert(watch.window:IsVisible(), "detached panel closed with ledger")
watch:setGraphOnly(true)
assert(watch.overlay:IsVisible() and not watch.window:IsVisible())
assert(watch.overlay.pick == false and watch.overlayTitle.drag == true)
assert(#watch.overlay.draws == 0, "overlay gained a background drawable")
assert(watch.overlayChart.plot.pick == false and watch.overlayChart.line.pick == false)
assert(#watch.overlayChart.hits == 0, "overlay graph intercepts clicks")
for _, d in ipairs(watch.overlayChart.plot.draws) do assert(d.layer == "artwork") end
now = now + 30; watch:tick(1)
assert(#queries == 2, "graph overlay stopped polling while ledger was closed")
assert(reply(watch, 129)); drain(watch)
watch.overlay.x, watch.overlay.y = 410, 250
watch.overlayTitle.handlers.OnDragStop()
assert(saved.TradePacksRateSettings.graphX == 410 and saved.TradePacksRateSettings.graphY == 250)
widgets.TradePacksRateOverlayExpand.handlers.OnClick()
assert(watch.window:IsVisible() and not watch.overlay:IsVisible())
assert(watch.settings.x == 410 and watch.settings.y == 250)

-- Route changes cannot attribute the previous response to the new destination.
now = now + 30; assert(watch:query())
watch:selectRoute(22, 5)
assert(reply(watch, 105), "browsing dropped the owned previous-route reply")
assert(next(watch.latest) == nil, "old route reply contaminated the selected route")
now = now + 30; assert(watch:query()); assert(reply(watch, 110)); drain(watch)
assert(watch:seriesFor(22, 5, packName).key ~= series.key, "destination histories share a key")
watch:togglePack(packName, 22, 5)
watch:togglePack(packName, 22, 8)
assert(watch.price.text:find("no reference price", 1, true))
watch.settings.metric = "price"; watch:render()
for _, marker in ipairs(watch.chart.markers) do
  assert(not marker.visible, "invented price for an unsupported route")
end
assert(not watch.chart.line.visible and #watch.chart.line.points == 0)

-- Known other rate tracker keeps working; its response must not enter our history.
now = now + 30; assert(watch:query())
assert(checkPackRatio(20, 8) == "unchanged return" and externalCalls == 1)
assert(not reply(watch, 99), "external query's response entered our history")
assert(not watch:query(), "panel queried during an external tracker's active period")
now = now + 31
watch:selectRoute(22, 8)
if not watch.request then assert(watch:query()) end
assert(reply(watch, 130)); drain(watch)

-- Failed writes preserve the committed day and retry the same in-memory data.
entry = watch:loadDay(series, day)
local committed = saved[entry.key .. "Meta"].bank
now = now + 60
watch:sample(series, now, 125)
failDayWrite = true
watch:workOne()
failDayWrite = false
assert(saved[entry.key .. "Meta"].bank == committed, "failed history write switched banks")
now = now + 61; drain(watch)
assert(saved[entry.key .. "Meta"].bank ~= committed, "history write did not retry")
local expected = copy(entry.data)
local reloaded = newWatch()
local reloadedSeries = reloaded:seriesFor(22, 8, packName)
assert(equal(reloaded:loadDay(reloadedSeries, day).data, expected), "daily samples did not survive reload")
local active = saved[entry.key .. "Meta"].bank
saved[entry.key .. active].hours = nil
local recovered = newWatch():loadDay(reloadedSeries, day)
assert(recovered.bank ~= active, "damaged active rate day did not use its prior bank")

-- An hour gets equal weight per observed day, regardless of how long we sampled.
saved, errors = {}, {}
watch = newWatch()
watch.settings.from, watch.settings.to, watch.settings.pack = 22, 8, packName
watch.settings.mode, watch.settings.offset = "hourly", -3
series = watch:seriesFor(22, 8, packName)
for d = day - 2, day do
  watch:sample(series, d * 86400 + 6 * 3600, d == day - 2 and 100 or 130)
  watch:sample(series, d * 86400 + 18 * 3600, 125)
end
for minute = 1, 49 do watch:sample(series, (day - 2) * 86400 + 6 * 3600 + minute * 60, 100) end
drain(watch)
local columns, best, count = watch:chartData()
assert(count == 6 and columns[4].ratio == 120 and columns[16].ratio == 125)
assert(best and best.hour == 15 and best.days == 3, "best observed hour ignored timezone/daily weighting")
assert(columns[1] == nil, "offline gaps were filled with invented readings")
watch.settings.mode = "recent"
columns = watch:chartData()
local points = 0; for _ in pairs(columns) do points = points + 1 end
assert(points == 2, "24-hour view includes old days or fills gaps")

-- Both line charts use native segments: rising/falling/flat values, breaks, and
-- isolated points. Marker centers must agree with the native bottom-up Y axis.
for _, reading in ipairs({{2, 125}, {3, 125}, {7, 130}, {8, 110}, {9, 110}, {11, 120}, {12, 140}}) do
  watch:sample(series, day * 86400 + reading[1] * 3600, reading[2])
end
watch.settings.mode = "hourly"
showBothChartFixtures(watch)
local function checkSegments(chart, pairs)
  assert(chart.line.kind == "line" and chart.line.thickness == 2 and chart.line.pick == false)
  assert(#chart.line.points == #pairs, "line bridged missing hours or dropped a segment")
  for i, pair in ipairs(pairs) do
    local segment = chart.line.points[i]
    local first, last = chart.markers[pair[1]].anchor, chart.markers[pair[2]].anchor
    assert(first[1] == "CENTER" and first[3] == "BOTTOMLEFT")
    assert(segment.beginX == first[4] and segment.beginY == -first[5], "line misses its first marker")
    assert(segment.endX == last[4] and segment.endY == -last[5], "line misses its last marker")
    assert(segment.beginX >= 0 and segment.endX <= chart.width)
    assert(segment.beginY >= 0 and segment.beginY <= chart.height)
    assert(segment.endY >= 0 and segment.endY <= chart.height)
    assert(segment.endX - segment.beginX == 15, "line crosses an unobserved hour")
  end
end
local expectedPairs = {{4, 5}, {5, 6}, {6, 7}, {9, 10}}
for _, chart in ipairs({watch.chart, watch.overlayChart}) do
  checkSegments(chart, expectedPairs)
  assert(chart.line.visible)
  assert(chart.line.points[1].endY > chart.line.points[1].beginY, "rising rate slopes downward")
  assert(chart.line.points[2].endY < chart.line.points[2].beginY, "falling rate slopes upward")
  assert(chart.line.points[3].endY == chart.line.points[3].beginY, "equal rates aren't level")
  for _, i in ipairs({1, 16, 24}) do assert(chart.markers[i].visible, "isolated reading disappeared") end
  assert(not chart.markers[8].visible, "missing hour gained a point")
end
assert(not watch.chart.hits[8].visible and watch.chart.hits[5].visible)
watch.chart.hits[5].handlers.OnClick()
assert(watch.pointDetail.text == "04:00: 130.0% | 1 samples / 1 day(s)", "point selects the wrong hour")
local rateSegments = copy(watch.chart.line.points)
widgets.TradePacksRatesMetric.handlers.OnClick()
assert(watch.settings.metric == "price" and watch.chartColumns[5].value == 39)
assert(watch.chart.valueAxis[1].label.text:find("g", 1, true))
for _, chart in ipairs({watch.chart, watch.overlayChart}) do checkSegments(chart, expectedPairs) end
for i, segment in ipairs(watch.chart.line.points) do
  local rateDirection = rateSegments[i].endY - rateSegments[i].beginY
  local priceDirection = segment.endY - segment.beginY
  assert((rateDirection == 0 and priceDirection == 0) or rateDirection * priceDirection > 0,
    "price changed the direction of the observed trend")
end
widgets.TradePacksRatesMode.handlers.OnClick()
assert(watch.settings.mode == "recent")
for _, chart in ipairs({watch.chart, watch.overlayChart}) do
  checkSegments(chart, {{6, 7}, {10, 11}, {11, 12}, {12, 13}, {15, 16}})
end

-- A constant series stays level and visible. Changing to an unobserved pack
-- clears both lines, markers, and click targets instead of leaving stale data.
local flatSeries = watch:seriesFor(22, 8, "Flat pack")
watch:sample(flatSeries, day * 86400, 130)
watch:sample(flatSeries, day * 86400 + 3600, 130)
watch.settings.metric, watch.settings.pack = "rate", "Flat pack"
watch:render()
for _, chart in ipairs({watch.chart, watch.overlayChart}) do
  checkSegments(chart, {{4, 5}})
  assert(chart.line.points[1].beginY == chart.height and chart.line.points[1].endY == chart.height,
    "constant 130% readings should stay level on the 130% bracket")
end
watch.settings.pack = "Unobserved pack"; watch:render()
for _, chart in ipairs({watch.chart, watch.overlayChart}) do
  assert(not chart.line.visible and #chart.line.points == 0, "old line survived a pack change")
  for _, marker in ipairs(chart.markers) do assert(not marker.visible) end
  for _, hit in ipairs(chart.hits) do assert(not hit.visible) end
end
watch.settings.pack = packName

-- Server pricing includes Commerce points + modifiers and optional maximum
-- freshness in every price surface. Controls recalculate without another query.
watch.settings.mode, watch.settings.metric = "hourly", "price"
watch.latest[packName] = {ratio = 130, at = now}
abilityInfos = {{name = "Commerce", point = 230000, modifyPoint = 42000}}
now = now + 5
local beforeAbilityReads, beforeQueries = abilityReads, #queries
watch:render()
assert(watch.price.text == "Price estimate: 92.04g", "server Commerce multiplier missing")
assert(watch.proficiencyButton.text == "Prof: Current / 272000", "bonus Commerce points were ignored")
assert(watch.chartColumns[5].priceCopper == 920400 and watch.chartColumns[5].value == 92.04)
assert(watch.overlayQuote.text:find("~92.04g", 1, true), "overlay uses a different price formula")
watch.chart.hits[5].handlers.OnClick()
assert(watch.pointDetail.text:find("~92.04g", 1, true), "price point shows an unadjusted quote")
for i = 1, 20 do watch:render() end
assert(abilityReads == beforeAbilityReads + 1, "chart points repeatedly poll Commerce")
abilityInfos[1].modifyPoint = 102000
now = now + 5; watch:render()
assert(watch.price.text == "Price estimate: 103.74g", "live Commerce changes did not update price")
local function selectProficiency(index)
  watch.proficiencyButton.handlers.OnClick()
  watch.menuRows[index].handlers.OnClick()
end
selectProficiency(3)
assert(watch.settings.proficiencyMode == "272000" and watch.price.text == "Price estimate: 92.04g")
watch.freshnessButton.handlers.OnClick()
assert(watch.chartColumns[5].priceCopper == 948012 and watch.price.text == "Price estimate: 94.80g")
assert(watch.overlayQuote.text:find("~94.80g", 1, true))
selectProficiency(2)
assert(watch.settings.proficiencyMode == "off" and watch.chartColumns[5].priceCopper == 401700)
selectProficiency(4)
assert(watch.settings.proficiencyMode == "332000" and watch.chartColumns[5].priceCopper == 1068522)
assert(saved.TradePacksRateSettings.proficiencyMode == "332000" and saved.TradePacksRateSettings.maxFreshness)
drain(watch)
local pricingReload = newWatch()
assert(pricingReload.settings.proficiencyMode == "332000" and pricingReload.settings.maxFreshness)
watch.freshnessButton.handlers.OnClick()
assert(saved.TradePacksRateSettings.maxFreshness == nil, "freshness OFF did not use native-safe persistence")
assert(#queries == beforeQueries, "pricing controls restarted route queries")

-- Unavailable/malformed Commerce is not silently treated as a known zero.
abilityInfos = {}
selectProficiency(1)
assert(watch.price.text == "Price estimate: waiting for Commerce data")
assert(watch.overlayQuote.text:find("Prof unavailable", 1, true))
for _, chart in ipairs({watch.chart, watch.overlayChart}) do
  assert(not chart.line.visible and #chart.line.points == 0)
  for _, marker in ipairs(chart.markers) do assert(not marker.visible) end
end
abilityInfos = {{name = "Commerce", point = "invalid", modifyPoint = 42000}}
now = now + 5; watch:render()
assert(watch.price.text == "Price estimate: waiting for Commerce data")
abilityInfos = {{name = "Commerce", point = 0}}
now = now + 5; watch:render()
assert(watch.price.text == "Price estimate: 39.00g", "known zero Commerce failed to recover pricing")

-- Compare with Folio105's actual CalculatePrice source and both real price
-- tables, covering every reference pack, destination, proficiency, and freshness.
local function read(path)
  local file = assert(io.open(path, "r")); local source = file:read("*a"); file:close(); return source
end
local folioSource = read("Folio105/Folio105.lua")
local referenceFactory = assert(load(
  "local proficiencyMode, commerceSkill, maxFreshnessEnabled, toZoneGroup = ...\n"
    .. assert(folioSource:match("local freshnessMultipliers = %b{}")) .. "\n"
    .. assert(folioSource:match("local function CalculatePrice%b().-\nend"))
    .. "\nreturn CalculatePrice", "Folio105 pricing reference", "t", _G))
local function priceTables(path)
  local environment = {}; assert(loadfile(path, "t", environment))(); return environment
end
local folioPrices, opsPrices = priceTables("Folio105/Prices.lua"), priceTables("TradePacks/Prices.lua")
local priceNames = {[5] = "SOLZREED_PRICE", [8] = "TWOCROWNS_PRICE", [20] = "CINDERSTONE_MOOR_PRICE",
  [4] = "SOLIS_HEADLANDS_PRICE", [12] = "VILLANELLE_PRICE", [17] = "YNYSTERE_PRICE", [33] = "HEEDMAR_PRICE"}
local originalGlobals, originalSettings, comparisons = {}, copy(watch.settings), 0
for _, name in pairs(priceNames) do
  originalGlobals[name] = _G[name]; _G[name] = opsPrices[name]
  assert(equal(opsPrices[name], folioPrices[name]), "reference prices differ from Folio105: " .. name)
end
abilityInfos = {{name = "Commerce", point = 230000, modifyPoint = 42000}}
watch.nextCommerceAt = 0
for destination, tableName in pairs(priceNames) do
  watch.settings.to = destination
  for _, mode in ipairs({"current", "off", "272000", "332000"}) do
    watch.settings.proficiencyMode = mode
    for _, freshness in ipairs({false, true}) do
      watch.settings.maxFreshness = freshness
      local reference = referenceFactory(mode, 272000, freshness, destination)
      for name, entry in pairs(folioPrices[tableName]) do
        local context = watch:priceContext(name)
        for _, ratio in ipairs({98.5, 100, 130}) do
          assert(watch:estimatePrice(context, ratio) == reference(entry[1], ratio, name),
            "Folio105 price mismatch: " .. destination .. " / " .. name .. " / " .. mode)
          comparisons = comparisons + 1
        end
      end
    end
  end
end
for _, name in pairs(priceNames) do _G[name] = originalGlobals[name] end
watch.settings = originalSettings

-- Entries stay small, and cleanup only touches expired rate-panel keys.
local function size(v)
  if type(v) ~= "table" then return type(v) == "string" and #v + 8 or 24 end
  local n = 16; for k, value in pairs(v) do n = n + size(k) + size(value) end; return n
end
for hour = 0, 23 do watch:sample(series, day * 86400 + hour * 3600, 120) end
drain(watch)
assert(size(watch:loadDay(series, day).data) < 12000, "rate day could exceed SaveData value limit")
saved.TradePacksState = {untouched = true}
now = now + 31 * 86400
watch:prune(series, math.floor(now / 86400)); drain(watch)
assert(clears > 0 and saved.TradePacksState.untouched)
assert(saved[series.key .. "_" .. day .. "Meta"] == nil, "expired day was not pruned")
assert(#errors == 0, table.concat(errors, " | "))

-- Drive the real event/timer callbacks in native milliseconds. The Rates driver
-- stays shown even when the ledger and full panel are hidden for Graph only.
saved, queries, errors = {}, {}, {}
checkPackRatio = function() externalCalls = externalCalls + 1; return "unchanged return" end
local polling = newWatch()
polling.settings.from, polling.settings.to = 22, 8
ledger:Show(true); polling:toggle()
assert(#queries == 1 and reply(polling, 130))
ledger:Show(false); polling:setGraphOnly(true)
assert(polling.driver.kind == "window" and rawget(polling.driver, "parent") == nil and polling.driver:IsVisible())
assert(polling.driver.pick == false and #polling.driver.draws == 0)
assert(not polling.window:IsVisible() and polling.overlay:IsVisible())
local function frames(seconds, milliseconds)
  local start = now
  for elapsed = milliseconds, seconds * 1000, milliseconds do
    now = start + elapsed / 1000
    polling.driver.handlers.OnUpdate(polling.driver, milliseconds)
  end
  now = start + seconds
end
local firstReading = polling.latest[packName].at
frames(31, 5)
assert(#queries == 2, "automatic request did not fire through the native updater")
assert(polling.statusLabel.text:find("Waiting for server reply", 1, true))
assert(reply(polling, 129), "Graph only did not receive its response")
assert(polling.latest[packName].at > firstReading and polling.age.text == "Updated 0s ago")
frames(31, 5)
assert(#queries == 3 and reply(polling, 128), "second automatic refresh stalled")
assert(polling.overlayQuote.text:find("128.0%", 1, true))
assert(polling.overlayStatus.text:find("Next update in", 1, true))
for i = 2, #queries do assert(queries[i].at - queries[i - 1].at >= 30, "native frame timing bypassed throttle") end

-- An expired request is recovered by the Refresh button without any intervening
-- OnUpdate. Late and missing replies never lock manual refresh indefinitely.
now = now + 31; assert(polling:query())
local beforeManual = #queries
now = now + 31
widgets.TradePacksRatesRefresh.handlers.OnClick()
assert(#queries == beforeManual + 1 and reply(polling, 127), "manual Refresh kept an expired request")

-- Respect a longer native cooldown and show it. Requests rejected by the API
-- leave no phantom pending reply and retry after the interval.
now = now + 31; requestResult = 60000
assert(polling:query() and reply(polling, 126))
local beforeCooldown = #queries
frames(31, 5)
assert(#queries == beforeCooldown and polling.statusLabel.text:find("Server cooldown", 1, true))
requestResult = 30000; frames(30, 5)
assert(#queries == beforeCooldown + 1 and reply(polling, 125))
now = now + 31; requestResult = false
assert(not polling:query() and polling.request == nil)
polling:renderStatus()
assert(polling.statusLabel.text:find("Request rejected", 1, true))
local rejectedCount = #queries
for i = 1, 20 do assert(not polling:query()) end
assert(#queries == rejectedCount, "Refresh spam retried a rejected request too soon")
requestResult = nil; now = now + 31
assert(not polling:query() and polling.request == nil)
requestResult = 30000; now = now + 31; assert(polling:query())
frames(16, 5)
assert(polling.request == nil and polling.statusLabel.text:find("No server reply", 1, true))
assert(polling.age.text:find("ago", 1, true), "quote age stopped when a response was missing")
frames(15, 5); assert(polling.request and reply(polling, 124))

-- The older tracker polls every five seconds. Same-route replies keep updating
-- this chart instead of its 30-second guard postponing all updates forever.
local ownQueries = #queries
for i = 1, 12 do
  now = now + 5
  assert(checkPackRatio(22, 8) == "unchanged return")
  assert(polling.request and polling.request.shared)
  assert(reply(polling, 124 - i / 10))
  polling.driver.handlers.OnUpdate(polling.driver, 200)
  assert(polling.latest[packName].at == math.floor(now))
end
assert(#queries == ownQueries, "same-route sharing issued duplicate native queries")
checkPackRatio(20, 8)
assert(not reply(polling, 99), "different-route tracker contaminated the selected route")
polling:renderStatus()
assert(polling.statusLabel.text:find("Other route tracker active", 1, true))
now = now + 5; checkPackRatio(22, 8)
assert(polling.request == nil and not reply(polling, 99), "quick route switch accepted an older route's reply")
polling:renderStatus()
assert(polling.statusLabel.text:find("Other route reply pending", 1, true))
now = now + 26; checkPackRatio(22, 8)
assert(polling.request and polling.request.shared and reply(polling, 123), "same-route sharing did not recover")
now = now + 31; assert(polling:query() and reply(polling, 123), "polling did not resume after other tracker stopped")

-- No polling while closed; high-FPS frames still perform only five history jobs
-- per second. Invalid same-zone selections never reach the native query.
polling.settings.open = false; polling:visibility()
local closedCount = #queries
local workCount, workOne = 0, polling.workOne
polling.workOne = function(self) workCount = workCount + 1; workOne(self) end
frames(2, 5)
assert(workCount >= 8 and workCount <= 11, "millisecond frame times overrun the background work budget")
frames(31, 5)
assert(#queries == closedCount, "closed panel continued to poll")
polling.settings.open = true; polling:visibility()
polling.settings.to = polling.settings.from
polling:query()
for i = closedCount + 1, #queries do
  assert(queries[i][1] ~= queries[i][2], "same-zone browser selection reached the native API")
end
polling.settings.selectedRoutes, polling.settings.pack = {}, nil
now = now + 31
assert(not polling:query(), "empty selection queried the invalid same-zone browser route")
assert(#errors == 0, table.concat(errors, " | "))

-- Period changes use saved hourly observations, resize both charts, and never
-- issue new server queries or touch ledger data. Exercise the actual controls.
do
  saved, errors = {}, {}
  local periods = newWatch()
  assert(periods.settings.recentHours == 24 and periods.settings.hourlyDays == 30)
  periods.settings.from, periods.settings.to, periods.settings.pack = 22, 8, packName
  showBothChartFixtures(periods)
  local periodSeries = periods:seriesFor(22, 8, packName)
  local lastHour = math.floor(now / 3600)
  local firstHour = lastHour - 719
  for hour = firstHour - 1, lastHour + 1 do
    periods:sample(periodSeries, hour * 3600, 100 + (hour - firstHour) % 25)
  end
  drain(periods)
  local queryCount = #queries
  for _, span in ipairs({6, 13, 24, 37, 48, 168, 336, 720}) do
    periods.settings.recentHours = span
    local data, _, observed, layout = periods:chartData()
    assert(observed == span, "period includes an old/future hour or drops its first hour")
    assert(layout.count <= 30 and layout.firstHour == lastHour - span + 1)
    local samples = 0
    for _, point in pairs(data) do samples = samples + point.n end
    assert(samples == span, "aggregation lost or duplicated samples")
    periods:render()
    for _, chart in ipairs({periods.chart, periods.overlayChart}) do
      assert(#chart.line.points == layout.count - 1, "complete period lost line segments")
      for index, marker in ipairs(chart.markers) do
        assert(marker.visible == (index <= layout.count), "old point survived a shorter period")
        if marker.visible then
          local left = (index - 1) * layout.step
          local width = math.min(layout.step, span - left)
          local expectedX = (left + width / 2) * chart.width / span
          assert(math.abs(marker.anchor[4] - expectedX) < 0.000001, "partial final bucket distorted the time axis")
        end
      end
    end
    for i, tick in ipairs(periods.ticks) do
      assert(tick.visible == (i <= math.min(5, layout.count)))
      assert(tick.text == periods.overlayTicks[i].text, "overlay uses a different time range")
    end
    if span > 48 then assert(periods.ticks[1].text:find("/", 1, true), "long periods lack dates") end
  end
  local boundaryDay = math.floor(firstHour / 24)
  periods:prune(periodSeries, math.floor(now / 86400)); drain(periods)
  local boundaryKey = periodSeries.key .. "_" .. boundaryDay
  assert(saved[boundaryKey .. "Meta"], "rolling 30-day period pruned its partial first UTC day")

  -- Recent presets and a non-preset custom value persist independently of the
  -- time-of-day lookback. Invalid input stays open without saving a bad value.
  choosePeriod(periods, 6)
  assert(periods.settings.recentHours == 6 and periods.periodButton.text == "Period: 6h")
  assert(periods.overlayQuote.text:find(" | 6h ", 1, true))
  choosePeriod(periods, "custom")
  for _, invalid in ipairs({"", "0", "721", "-1", "2.5", "nan", "1e999"}) do
    periods.periodInput:SetText(invalid)
    widgets.TradePacksRatesPeriodApply.handlers.OnClick()
    assert(periods.periodEditor:IsVisible() and periods.settings.recentHours == 6)
    assert(saved.TradePacksRateSettings.recentHours == 6 and periods.periodError.text ~= "")
  end
  periods.periodInput:SetText("37"); widgets.TradePacksRatesPeriodApply.handlers.OnClick()
  assert(periods.settings.recentHours == 37 and not periods.periodEditor:IsVisible())
  assert(saved.TradePacksRateSettings.recentHours == 37)
  periods.modeButton.handlers.OnClick()
  assert(periods.settings.mode == "hourly" and periods.periodButton.text == "Period: 30d")
  choosePeriod(periods, 7)
  local data, bestHour, observed, layout = periods:chartData()
  assert(observed == 168 and layout.count == 24 and bestHour.days == 7)
  for _, point in pairs(data) do assert(point.days == 7, "time-of-day lookback includes the wrong days") end
  assert(periods.overlayQuote.text:find(" | 7d avg ", 1, true))
  choosePeriod(periods, "custom")
  periods.periodInput:SetText("31"); widgets.TradePacksRatesPeriodApply.handlers.OnClick()
  assert(periods.periodEditor:IsVisible() and periods.settings.hourlyDays == 7)
  periods.periodInput:SetText("5"); widgets.TradePacksRatesPeriodApply.handlers.OnClick()
  assert(saved.TradePacksRateSettings.hourlyDays == 5 and saved.TradePacksRateSettings.recentHours == 37)
  choosePeriod(periods, "custom")
  periods.periodInput:SetText("2"); widgets.TradePacksRatesPeriodCancel.handlers.OnClick()
  assert(not periods.periodEditor:IsVisible() and periods.settings.hourlyDays == 5)
  periods.modeButton.handlers.OnClick()
  assert(periods.periodButton.text == "Period: 37h" and #queries == queryCount)
  local restoredPeriods = newWatch()
  drain(restoredPeriods)
  assert(restoredPeriods.settings.recentHours == 37 and restoredPeriods.settings.hourlyDays == 5)
  choosePeriod(restoredPeriods, 720); drain(restoredPeriods)
  local _, _, reloadedCount = restoredPeriods:chartData()
  assert(reloadedCount == 720, "30-day history did not survive restart")
  saved.TradePacksRateSettings.recentHours = 721
  saved.TradePacksRateSettings.hourlyDays = 0
  local invalidSaved = newWatch()
  assert(invalidSaved.settings.recentHours == 24 and invalidSaved.settings.hourlyDays == 30)

  -- Uneven sampling must not bias a multi-hour mean. An offline hour inside a
  -- wider bucket prevents a line from bridging it, even when both bins exist.
  periods.settings.pack, periods.settings.recentHours = "Sparse period", 48
  local sparse = periods:seriesFor(22, 8, periods.settings.pack)
  local start = lastHour - 47
  for hour = start, start + 7 do
    if hour ~= start + 4 then periods:sample(sparse, hour * 3600, hour == start and 100 or 140) end
  end
  for minute = 1, 49 do periods:sample(sparse, start * 3600 + minute * 60, 100) end
  periods:render()
  local point = periods.chartColumns[1]
  assert(point.ratio == 120 and point.n == 51 and point.observed == 2, "longer sampling biased the bucket mean")
  assert(periods.chartColumns[3].observed == 1 and not periods.chartColumns[3].complete)
  for _, chart in ipairs({periods.chart, periods.overlayChart}) do
    assert(#chart.line.points == 1, "multi-hour aggregation hid an offline gap")
    assert(chart.markers[3].visible and not chart.markers[5].visible)
    assert(equal(chart.markers[3].color, {1, 0.65, 0.18, 1}), "partial interval lacks amber coverage marker")
  end
  assert(periods.coverage.text:find("7/48h", 1, true) and periods.coverage.text:find("1 partial", 1, true))
  assert(periods.overlayCoverage.text:find("7/48h", 1, true))
  periods.chart.hits[3].handlers.OnClick()
  assert(periods.pointDetail.text:find("1/2h", 1, true), "partial bucket hides its coverage")
  assert(#errors == 0, table.concat(errors, " | "))
end

-- Real minute points span UTC-hour boundaries and survive restart. Old hourly
-- averages must never be expanded into invented minute observations.
do
  saved, errors, queries = {}, {}, {}
  checkPackRatio = function() return "unchanged return" end
  local minuteWatch = newWatch()
  minuteWatch.settings.from, minuteWatch.settings.to, minuteWatch.settings.pack = 22, 8, packName
  showBothChartFixtures(minuteWatch)
  drain(minuteWatch)
  choosePeriod(minuteWatch, 1)
  assert(minuteWatch.pointDetail.text:find("No minute readings", 1, true))
  local series = minuteWatch:seriesFor(22, 8, packName)
  local lastMinute = math.floor(now / 60)
  for index = 0, 59 do minuteWatch:sample(series, (lastMinute - 59 + index) * 60, 100 + index) end
  drain(minuteWatch); minuteWatch:render()
  local data, _, count, layout = minuteWatch:chartData()
  assert(layout.minute and count == 60 and data[1].ratio == 100 and data[60].ratio == 159)
  for _, chart in ipairs({minuteWatch.chart, minuteWatch.overlayChart}) do
    assert(#chart.line.points == 59 and chart.markers[60].visible)
    assert(chart.line.points[1].endX - chart.line.points[1].beginX == 6)
  end
  assert(minuteWatch.coverage.text:find("60/60m", 1, true))
  minuteWatch.chart.hits[60].handlers.OnClick()
  assert(minuteWatch.pointDetail.text:find("1/1m observed", 1, true))
  local detail = minuteWatch.pointDetail.text
  minuteWatch:render()
  assert(minuteWatch.pointDetail.text == detail, "refresh erased clicked coverage details")
  for _, span in ipairs({0.25, 0.5}) do
    choosePeriod(minuteWatch, span)
    data, _, count, layout = minuteWatch:chartData()
    assert(count == span * 60 and #minuteWatch.chart.line.points == count - 1)
    assert(saved.TradePacksRateSettings.recentHours == span)
  end
  local restored = newWatch(); drain(restored); showBothChartFixtures(restored)
  assert(restored.settings.recentHours == 0.5 and #restored.chart.line.points == 29)
  local readCount = reads
  for _ = 1, 5 do restored:render() end
  assert(reads == readCount, "minute rendering reads native persistence")
  now = now + 180 -- two missing minutes must create a gap, not a flat line
  restored:sample(restored:seriesFor(22, 8, packName), now, 130)
  drain(restored); restored:render()
  assert(restored.chartColumns[29] == nil and restored.chartColumns[30])
  assert(#restored.chart.line.points == 26, "minute chart bridged missing observations")
  choosePeriod(restored, 24)
  assert(not select(4, restored:chartData()).minute, "long period stopped using hourly history")
  assert(#errors == 0, table.concat(errors, " | "))
end

-- Background collection is opt-in, respects native cooldowns, persists, and
-- keeps all chart/Commerce work stopped while both windows are closed.
do
  saved, errors, queries = {}, {}, {}
  checkPackRatio = function() return "unchanged return" end
  local bg = newWatch()
  assert(not bg.settings.collectHidden)
  bg.settings.from, bg.settings.to, bg.settings.pack = 22, 8, packName
  bg:setGraphOnly(true); drain(bg)
  bg.collectionButton.handlers.OnClick()
  assert(bg.settings.collectHidden and saved.TradePacksRateSettings.collectHidden)
  assert(reply(bg, 130)); drain(bg)
  bg.settings.open = false; bg:visibility(); bg:saveSettings()
  local quoteText, commerceCount = bg.rate.text, abilityReads
  local beforeQueries = #queries
  now = now + 31; bg.driver.handlers.OnUpdate(bg.driver, 200)
  assert(#queries == beforeQueries + 1 and reply(bg, 129), "hidden collection stopped")
  drain(bg)
  assert(bg.latest[packName].ratio == 129 and bg.rate.text == quoteText and abilityReads == commerceCount)
  requestResult = 60000; now = now + 31
  bg.driver.handlers.OnUpdate(bg.driver, 200); assert(reply(bg, 128))
  local cooldownCount = #queries
  now = now + 31; bg.driver.handlers.OnUpdate(bg.driver, 200)
  assert(#queries == cooldownCount, "hidden collection ignored server cooldown")
  requestResult = 30000
  saved.TradePacksRateSettings.pack, saved.TradePacksRateSettings.focusId = nil, nil
  saved.TradePacksRateSettings.selectedPacks, saved.TradePacksRateSettings.selectedRoutes = {}, {}
  local reloaded = newWatch()
  assert(reloaded.settings.collectHidden and not reloaded:isVisible())
  reloaded.driver.handlers.OnUpdate(reloaded.driver, 200)
  assert(reloaded.request and reply(reloaded, 127), "saved hidden collection did not resume")
  drain(reloaded)
  assert(reloaded.historyNeedsLoad, "hidden first pack selection did not defer history load")
  reloaded:setGraphOnly(true); drain(reloaded)
  assert(not reloaded.historyNeedsLoad and reloaded.rate.text == "Rate: 127.0%")
  reloaded.collectionButton.handlers.OnClick()
  assert(not reloaded.settings.collectHidden and saved.TradePacksRateSettings.collectHidden == nil)
  reloaded.settings.open = false; reloaded:visibility()
  local stoppedCount = #queries
  now = now + 61; reloaded.driver.handlers.OnUpdate(reloaded.driver, 200)
  assert(#queries == stoppedCount and not reloaded:shouldCollect())
  -- Login can temporarily return empty route lists. Preserve the saved route
  -- and retry quietly without requiring the panel to be opened.
  saved.TradePacksRateSettings.collectHidden = true
  saved.TradePacksRateSettings.open, saved.TradePacksRateSettings.graphOnly = nil, nil
  local destinations = X2Store.GetSellableZoneGroups
  local discoveryReads = 0
  X2Store.GetSellableZoneGroups = function() discoveryReads = discoveryReads + 1; return {} end
  local login = newWatch()
  login.driver.handlers.OnUpdate(login.driver, 200)
  assert(login.settings.to == 8 and not login.request and #queries == stoppedCount)
  for _ = 1, 10 do login.driver.handlers.OnUpdate(login.driver, 200) end
  assert(discoveryReads == 1, "empty route discovery retried every frame")
  X2Store.GetSellableZoneGroups = destinations
  now = now + 31; login.driver.handlers.OnUpdate(login.driver, 200)
  assert(login.request and reply(login, 126), "hidden collection never recovered after login")
  assert(#errors == 0, table.concat(errors, " | "))
end

-- Profit charts preserve negative and zero values, put a labelled break-even
-- reference on both plots, recalculate current costs, and hide unpriced totals.
do
  saved, errors = {}, {}
  local estimate = {totalCopper = 330000}
  local costReads = 0
  ctx.costEstimate = function(name) costReads = costReads + 1; assert(name == packName); return copy(estimate) end
  local profit = newWatch()
  profit.settings.from, profit.settings.to, profit.settings.pack = 22, 8, packName
  profit.settings.proficiencyMode, profit.settings.metric = "off", "rate"
  profit.settings.recentHours = 24
  showBothChartFixtures(profit); drain(profit)
  local series = profit:seriesFor(22, 8, packName)
  local lastHour = math.floor(now / 3600)
  profit:sample(series, (lastHour - 1) * 3600, 100)
  profit:sample(series, lastHour * 3600, 120)
  profit.latest[packName] = {ratio = 120, at = now}
  drain(profit)
  profit.metricButton.handlers.OnClick(); profit.metricButton.handlers.OnClick()
  assert(profit.settings.metric == "profit" and saved.TradePacksRateSettings.metric == "profit")
  assert(profit.chartColumns[23].profitCopper == -30000 and profit.chartColumns[24].profitCopper == 30000)
  assert(profit.overlayQuote.text:find("profit ~3.00g", 1, true))
  assert(profit.chart.valueAxis[1].label.text:find("-", 1, true))
  for _, chart in ipairs({profit.chart, profit.overlayChart}) do
    assert(chart.zeroLine.visible and #chart.zeroLine.points == 1)
    assert(chart.zeroLine.points[1].beginY == chart.height / 2)
    assert(chart.markers[23].anchor[5] > chart.markers[24].anchor[5], "negative profit plotted above positive")
  end
  profit.chart.hits[23].handlers.OnClick()
  assert(profit.pointDetail.text:find("~-3.00g", 1, true))
  local beforeCosts = costReads
  estimate.totalCopper = 360000; profit:render()
  assert(costReads == beforeCosts + 1 and profit.chartColumns[24].profitCopper == 0)
  assert(profit.chart.markers[24].visible and profit.chart.zeroLine.visible)
  estimate.totalCopper = 400000; estimate.stalePrices = true; profit:render()
  assert(profit.chartColumns[24].profitCopper == -40000 and profit.legend.text:find("cached costs", 1, true))
  assert(profit.chart.zeroLine.points[1].beginY < profit.chart.height)
  estimate = {missing = "Labor: auction price unavailable"}; profit:render()
  assert(profit.price.text == "Profit estimate: costs incomplete")
  assert(profit.pointDetail.text:find("Labor", 1, true))
  assert(profit.overlayQuote.text:find("Costs incomplete", 1, true))
  for _, chart in ipairs({profit.chart, profit.overlayChart}) do
    assert(not chart.line.visible and not chart.zeroLine.visible)
    for _, marker in ipairs(chart.markers) do assert(not marker.visible) end
  end
  estimate = {totalCopper = 0}; profit:render()
  assert(profit.chartColumns[24].profitCopper == 360000, "explicit free costs treated as unknown")
  profit.metricButton.handlers.OnClick()
  assert(profit.settings.metric == "both" and not profit.chart.zeroLine.visible)
  profit.metricButton.handlers.OnClick()
  assert(profit.settings.metric == "rate" and not profit.chart.zeroLine.visible)

  -- Reproduce the screenshot: there are minute readings, but Transport/Labor
  -- are unconfigured. Period selection still changes the axis and coverage;
  -- explain the empty Profit chart inside the plot and offer an explicit switch.
  estimate = {missing = "Transport: not configured; Labor: not configured",
    missingComponents = {"Transport: not configured", "Labor: not configured"}}
  profit.settings.metric = "profit"
  for offset = 59, 0, -1 do profit:sample(series, now - offset * 60, 120 + offset % 3) end
  drain(profit)
  local previousFirstTick
  for _, span in ipairs({0.25, 0.5, 1}) do
    choosePeriod(profit, span)
    assert(profit.settings.metric == "profit", "period selection silently changed the metric")
    assert(profit.coverage.text:find(string.format("/%dm", span * 60), 1, true))
    if previousFirstTick then assert(profit.ticks[1].text ~= previousFirstTick, "period axis did not update") end
    previousFirstTick = profit.ticks[1].text
    for _, chart in ipairs({profit.chart, profit.overlayChart}) do
      assert(chart.emptyTitle.visible and chart.emptyTitle.text == "Profit unavailable: costs incomplete")
      assert(chart.emptyDetail.text == "Missing costs: Transport, Labor")
      assert(not chart.line.visible)
    end
    assert(profit.chart.showRateButton.visible and profit.overlayChart.emptyHint.visible)
  end
  profit.chart.showRateButton.handlers.OnClick()
  assert(profit.settings.metric == "rate" and profit.settings.recentHours == 1)
  assert(#profit.chart.line.points == 59 and #profit.overlayChart.line.points == 59)
  assert(not profit.chart.emptyTitle.visible and not profit.overlayChart.emptyTitle.visible)
  assert(not profit.chart.showRateButton.visible and not profit.overlayChart.emptyHint.visible)
  assert(saved.TradePacksRateSettings.metric == "rate")
  assert(#errors == 0, table.concat(errors, " | "))
  ctx.costEstimate = nil
end
-- Shared picker regressions: every single-select menu can be dismissed without
-- changing settings. Native Raise calls are modeled here; visual stacking still
-- needs a client restart/retest against the actual native widget renderer.
do
  saved.TradePacksRateSettings = {from = 22, to = 8, pack = packName, selectedPacks = {packName},
    open = true, detached = true, recentHours = 1}
  local picker = newWatch()
  picker:render()
  for _, button in ipairs({picker.periodButton, picker.fromButton, picker.toButton,
    picker.proficiencyButton, picker.timeButton}) do
    local before = copy(picker.settings)
    button.handlers.OnClick()
    assert(picker.menu:IsVisible() and picker.menuDone:IsVisible() and picker.menuDone.text == "Close",
      "single-select picker lacks a visible Close control")
    assert(picker.menuDone.anchor[4] + picker.menuDone.height <= picker.menu.height,
      "Close is outside the picker")
    assert(picker.menuNext.anchor[3] + picker.menuNext.width <= picker.menuDone.anchor[3],
      "pagination overlaps Close")
    button.handlers.OnClick()
    assert(not picker.menu:IsVisible(), "clicking the open picker's button did not dismiss it")
    button.handlers.OnClick()
    picker.menuDone.handlers.OnClick()
    assert(not picker.menu:IsVisible() and equal(before, picker.settings),
      "closing a picker changed its selected value")
  end
  picker.periodButton.handlers.OnClick()
  local originalPeriod = picker.settings.recentHours
  picker.menuNext.handlers.OnClick()
  assert(picker.menuPage == 2 and picker.menuDone:IsVisible())
  picker.menuDone.handlers.OnClick()
  assert(picker.settings.recentHours == originalPeriod, "Close chose a period from the current page")

  -- Reproduce the layering failure with widgets created after the menu, and
  -- then another series arriving during a render while the menu is open.
  picker.periodButton.handlers.OnClick()
  picker:togglePack("Second pack", 20, 5)
  assert(picker.menu:IsVisible() and #picker.seriesLegend == 2)
  assert(picker.menu.drawOrder > picker.seriesLegend[2].drawOrder
    and picker.menu.drawOrder > picker.seriesRouteLabels[2].drawOrder,
    "new comparison legends were left above the open picker")
  assert(picker.menu.draws[1].alpha == 1 and picker.menu.pick,
    "picker backdrop must be opaque and intercept clicks")
  picker.menuDone.handlers.OnClick()
  choosePeriod(picker, "custom")
  picker:togglePack("Third pack", 22, 8)
  assert(picker.periodEditor:IsVisible() and not picker.menu:IsVisible())
  assert(picker.periodEditor.drawOrder > picker.seriesLegend[3].drawOrder,
    "custom period editor was left under a newly created legend")
  assert(picker.periodEditor.draws[1].alpha == 1)
  widgets.TradePacksRatesPeriodCancel.handlers.OnClick()
  picker.packButton.handlers.OnClick()
  assert(picker.menuMulti and picker.menuDone.text == "Done" and picker.menuHelp:IsVisible())
  picker.packButton.handlers.OnClick()
  assert(not picker.menu:IsVisible(), "multi-pack picker lost its button toggle")
end
do
  local chart = watch:createLineChart("PollingGapFixture", watch.window, 0, 0, 360, 120, true)
  local layout = {minute = true, count = 15, hours = 0.25, step = 1, maxGapMinutes = 3}
  local columns = {[1] = {value = 110}, [4] = {value = 120}, [8] = {value = 125}, [14] = {value = 130}}
  watch.settings.metric = "rate"
  watch:renderLineChart(chart, columns, 90, 130, layout)
  assert(#chart.line.points == 1, "scheduled polling gaps were not connected or long gaps were bridged")
  assert(not chart.markers[2].visible and not chart.markers[3].visible and columns[2] == nil,
    "connecting a polling gap created observations")
  layout.maxGapMinutes = 4
  watch:renderLineChart(chart, columns, 90, 130, layout)
  assert(#chart.line.points == 2, "changed polling interval did not invalidate the geometry cache")
  columns[4].complete = false
  watch:renderLineChart(chart, columns, 90, 130, layout)
  assert(#chart.line.points == 0, "partial bucket was connected")
  columns[4].complete, columns[2] = true, {value = nil}
  watch:renderLineChart(chart, columns, 90, 130, layout)
  assert(#chart.line.points == 1, "missing price at an observed minute did not break the line")
  layout.minute = false
  watch:renderLineChart(chart, columns, 90, 130, layout)
  assert(#chart.line.points == 0, "minute bridging leaked into hourly aggregates")
  local original = watch.trackedRoutes
  watch.trackedRoutes = function() return {{}, {}, {}, {}, {}, {}} end
  watch.settings.mode, watch.settings.recentHours, watch.routeInterval = "recent", 0.5, 30
  local _, _, _, cadence = watch:minuteChartData()
  assert(cadence.maxGapMinutes == 4, "six-route minute chart lacks normal polling tolerance")
  watch.routeInterval = 60
  _, _, _, cadence = watch:minuteChartData()
  assert(cadence.maxGapMinutes == 7, "server cooldown was excluded from expected sampling")
  watch.trackedRoutes = original
end
print("TradePacks rate panel / minute, scheduled polling gaps, picker and coverage checks passed; " .. comparisons .. " Folio105 pricing comparisons passed")
