-- Run from Addon: lua TradePacks/tests/test_rate_routes.lua
-- These mocks verify route identity and scheduling; they do not prove native UI safety.
local now = 20000 * 86400 + 20 * 3600
local saved, queries, errors, widgets = {}, {}, {}, {}
local cooldown = 30000
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}; for key, part in pairs(value) do out[key] = copy(part) end; return out
end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end
ADDON = {
  ImportAPI = function() end, ImportObject = function() end,
  LoadData = function(_, key) return copy(saved[key]) end,
  SaveData = function(_, key, value) saved[key] = copy(value) end,
  ClearData = function(_, key) saved[key] = nil end
}
local Widget = {}
Widget.__index = function(_, key) return Widget[key] or function() end end
local function widget(kind, name, parent, x, y, width, height)
  local w = setmetatable({kind = kind, name = name, parent = parent, x = x, y = y,
    width = width, height = height, visible = true, handlers = {}, draws = {}, events = {}}, Widget)
  w.style = setmetatable({}, Widget); widgets[name] = w; return w
end
function Widget:SetHandler(event, fn) self.handlers[event] = fn end
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
function Widget:AddAnchor(...)
  self.anchor = {...}
  if self.kind == "window" and self.anchor[1] == "TOPLEFT" and self.anchor[2] == "UIParent" then
    self.x, self.y = self.anchor[3], self.anchor[4]
    self.anchorCalls = (rawget(self, "anchorCalls") or 0) + 1
  end
end
function Widget:RemoveAllAnchors() self.anchor = nil end
function Widget:EnablePick(value) self.pick = value end
function Widget:EnableDrag(value) self.drag = value end
function Widget:SetPoints(points) self.points = copy(points) end
function Widget:ClearPoints() self.points = {} end
function Widget:SetLineColor(...) self.color = {...} end
function Widget:SetColor(...) self.color = {...} end
function Widget:SetLineThickness(thickness) self.thickness = thickness end
function Widget:CreateColorDrawable(r, g, b, alpha, layer)
  local d = widget("drawable", self.name .. "Draw" .. (#self.draws + 1), self, 0, 0, 0, 0)
  d.layer, d.alpha = layer, alpha; self.draws[#self.draws + 1] = d; return d
end
UIParent = {GetScreenWidth = function() return 1920 end, GetScreenHeight = function() return 1080 end}
local function label(name, parent, x, y, width, height, text)
  local w = widget("label", name, parent, x, y, width, height); w:SetText(text); return w
end
local function button(name, parent, x, y, width, height, text, fn)
  local w = label(name, parent, x, y, width, height, text); w:SetHandler("OnClick", fn); return w
end
local costs = {}
local ctx = {
  ledger = widget("window", "ledger", nil, 30, 30, 660, 864),
  widget = widget, label = label, editbox = label, button = button, textButton = button,
  setButtonText = function(w, text) w:SetText(text) end, now = function() return math.floor(now) end,
  scale = function() return 1 end, sameData = equal,
  fit = function(text, n) return #text > n and text:sub(1, n - 3) .. "..." or text end,
  money = function(copper) return string.format("%.2fg", copper / 10000) end,
  popup = function(name, width, height)
    local w = widget("window", name, nil, 100, 150, width, height); w:Show(false)
    return w, function(newHeight) w:SetExtent(width, newHeight) end
  end,
  costEstimate = function(name) return costs[name] end,
  reportSaveError = function(kind, err) errors[#errors + 1] = kind .. ": " .. tostring(err) end
}
local A, B, MISSING = "Halcyona Preserved Gilda Specialty", "Cinderstone Preserved Gilda Specialty", "Unobserved pack"
TWOCROWNS_PRICE = {[A] = {3000}, [B] = {5000}}
SOLZREED_PRICE = {[A] = {6000}, [B] = {7000}}
HEEDMAR_PRICE = {[A] = {8000}}
X2Ability = {GetAllMyActabilityInfos = function() return {{name = "Commerce", point = 0, modifyPoint = 0}} end}
X2Store = {
  GetProductionZoneGroups = function()
    return {{id = 22, zoneGroupName = "Halcyona"}, {id = 20, zoneGroupName = "Cinderstone"}}
  end,
  GetSellableZoneGroups = function()
    return {{id = 8, zoneGroupName = "Two Crowns"}, {id = 5, zoneGroupName = "Solzreed"},
      {id = 33, zoneGroupName = "Heedmar"}}
  end,
  GetSpecialtyRatioBetween = function(_, from, to)
    queries[#queries + 1] = {from = from, to = to, at = now}; return cooldown
  end
}
checkPackRatio = nil
dofile("TradePacks/MinuteHistory.lua")
dofile("TradePacks/RateChart.lua")
dofile("TradePacks/RateRoutes.lua")
dofile("TradePacks/RateCombined.lua")
dofile("TradePacks/RateWatch.lua")
local function newWatch(settings)
  if settings then saved.TradePacksRateSettings = copy(settings) end
  return TradePacksRateWatch.new(ctx)
end
local function drain(watch)
  local count = 0
  while watch.head <= watch.tail and count < 2000 do watch:workOne(); count = count + 1 end
  assert(count < 2000, "history queue failed to drain: " .. table.concat(errors, "; "))
end
local function entryFor(watch, name, from, to)
  for _, entry in ipairs(watch:selectedEntries()) do
    if entry.name == name and entry.from == from and entry.to == to then return entry end
  end
  error("selection missing: " .. name .. " " .. from .. " -> " .. to)
end
local function selectedIds(watch)
  local out = {}; for _, entry in ipairs(watch:selectedEntries()) do out[#out + 1] = entry.id end; return out
end
local function response(watch, from, to, rows)
  assert(watch.request and watch.request.from == from and watch.request.to == to,
    "reply would be assigned to an unexpected request route")
  assert(watch:receive({fromZoneGroup = from, toZoneGroup = to, ratios = rows}))
  drain(watch); watch:render()
end
local function row(name, ratio) return {itemInfo = {name = name}, ratio = ratio} end
local function chart(watch, entry)
  local columns, _, count, layout = watch:chartData(entry)
  return columns, count, layout
end
local function assertOneRatio(watch, entry, ratio)
  local columns, count, layout = chart(watch, entry)
  assert(count == 1 and layout.minute, "route should have exactly one minute observation")
  local found = 0
  for _, column in pairs(columns) do
    assert(column.ratio == ratio, "another route's ratio leaked into minute history"); found = found + 1
  end
  assert(found == 1)
end

-- Old single-route preferences acquire exact route identities without losing
-- the existing pack position or focused selection.
local watch = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A}, recentHours = 0.25,
  graphPositions = {[A] = {x = 95, y = 75, used = now}}})
local aCrowns = entryFor(watch, A, 22, 8)
assert(type(aCrowns.id) == "string" and aCrowns.id ~= A)
assert(watch.settings.focusId == aCrowns.id, "legacy focused pack did not migrate")
assert(watch.settings.graphPositions[aCrowns.id].x == 95, "legacy graph position did not migrate with the route")
watch:toggle()
assert(#queries == 1 and queries[1].from == 22 and queries[1].to == 8)
local pending = watch.request
watch:selectRoute(20, 5)
assert(watch.request == pending, "browsing another route discarded an in-flight reply")
assert(#queries == 1, "browsing bypassed the global query cooldown")
assert(entryFor(watch, A, 22, 8).id == aCrowns.id, "browsing replaced existing selections")
assert(not watch:receive({fromZoneGroup = 20, toZoneGroup = 5, ratios = {row(A, 888)}}),
  "a route-labeled reply for another request was accepted")
assert(watch.request == pending and watch:latestQuote(aCrowns) == nil,
  "rejecting a mismatched route consumed or contaminated the legitimate pending request")
response(watch, 22, 8, {row(A, 120)})
assert(watch:latestQuote(aCrowns).ratio == 120, "in-flight reply was discarded after browsing changed")

-- Both origin and destination belong to each selected series. The same pack
-- delivered elsewhere remains independently selectable and priced.
watch:togglePack(B, 20, 5)
watch:togglePack(A, 22, 5)
local bSolzreed, aSolzreed = entryFor(watch, B, 20, 5), entryFor(watch, A, 22, 5)
assert(#watch:selectedEntries() == 3 and aSolzreed.id ~= aCrowns.id,
  "same-name packs at different destinations collapsed into one selection")
watch:setFocusPack(aCrowns.id)
assert(watch.settings.focusId == aCrowns.id and watch.settings.from == 20 and watch.settings.to == 5,
  "focusing a selected pack unexpectedly changed the route being browsed")
local ids = selectedIds(watch)
watch:selectRoute(22, 33)
assert(equal(selectedIds(watch), ids), "changing destination erased the selected route list")
watch.settings.maxFreshness = true
local crownsPricing, solzreedPricing = watch:priceContext(aCrowns), watch:priceContext(aSolzreed)
assert(crownsPricing.base == 3000 and solzreedPricing.base == 6000,
  "per-pack payout lookup used the browser destination")
assert(crownsPricing.freshness == 1.03 and solzreedPricing.freshness == 1.03,
  "Heedmar's browser freshness contaminated another destination")
local heedmar = watch:routeEntry(A, 22, 33)
assert(watch:priceContext(heedmar).freshness == 1.30, "Heedmar route lost its server freshness bonus")
assert(watch:estimatePrice(crownsPricing, 120) == math.floor(3000 * 120 * 1.03))
assert(watch:estimatePrice(solzreedPricing, 110) == math.floor(6000 * 110 * 1.03))
watch.settings.maxFreshness = false

-- A newly browsed route gets one discovery request. Every request remains
-- serialized, and a longer native cooldown applies across all selected routes.
now = now + 30
cooldown = 45000
assert(watch:query())
assert(queries[#queries].from == 22 and queries[#queries].to == 33,
  "new browser route was not prioritized for discovery")
local countBefore = #queries
watch:query(); watch:query()
assert(#queries == countBefore, "parallel selected-route requests were issued")
response(watch, 22, 33, {row(A, 125)})
assert(equal(selectedIds(watch), ids), "unselected-route reply rewrote the selection")
now = now + 30
assert(not watch:query() and #queries == countBefore, "server cooldown was bypassed for a different route")
now = now + 15
cooldown = 30000
local seenRoutes = {}
for i = 1, 3 do
  assert(watch:query(), "selected route did not get a polling turn")
  local request = watch.request
  local key = request.from .. "_" .. request.to
  assert(not seenRoutes[key], "one selected route starved another during the polling cycle")
  seenRoutes[key] = true
  if key == "22_8" then response(watch, 22, 8, {row(A, 121)})
  elseif key == "20_5" then response(watch, 20, 5, {row(B, 95)})
  elseif key == "22_5" then response(watch, 22, 5, {row(A, 110)})
  else error("unexpected route in selected-route polling cycle: " .. key) end
  now = now + 30
end
assert(seenRoutes["22_8"] and seenRoutes["20_5"] and seenRoutes["22_5"])
assert(watch:latestQuote(aCrowns).ratio == 121 and watch:latestQuote(aSolzreed).ratio == 110
  and watch:latestQuote(bSolzreed).ratio == 95, "per-route latest readings overwrote one another")

-- Minute and hourly history are looked up by full identity, regardless of the
-- route currently browsed, and missing observations stay missing.
assertOneRatio(watch, aSolzreed, 110)
assertOneRatio(watch, bSolzreed, 95)
local crownsRows = watch:historyRows(aCrowns)
assert(#crownsRows == 1 and crownsRows[1].n == 2 and crownsRows[1].low == 120 and crownsRows[1].high == 121)
local solzreedRows, otherRows = watch:historyRows(aSolzreed), watch:historyRows(bSolzreed)
assert(#solzreedRows == 1 and solzreedRows[1].ratio == 110)
assert(#otherRows == 1 and otherRows[1].ratio == 95)
watch:togglePack(MISSING, 20, 8)
local missing = entryFor(watch, MISSING, 20, 8)
watch:loadSelectedHistory(); drain(watch)
assert(watch:latestQuote(missing) == nil)
local _, missingCount = chart(watch, missing)
assert(missingCount == 0, "an unobserved route borrowed another route's history")
local missingId = missing.id
watch:togglePack(missingId)
assert(#watch:selectedEntries() == 3)

-- Missing rows in a valid reply retain selections and previous readings. A
-- timed-out request cannot fabricate an observation or stamp another route.
watch:selectRoute(22, 5)
assert(watch:query() or watch.request)
response(watch, 22, 5, {row("Other available pack", 75)})
assert(entryFor(watch, A, 22, 5).id == aSolzreed.id)
assert(watch:latestQuote(aSolzreed).ratio == 110, "missing pack response erased its last valid reading")
local beforeRows = copy(watch:historyRows(aSolzreed))
now = now + 30
assert(watch:query())
now = now + 16
assert(not watch:receive({row(A, 777)}), "late unlabeled reply was accepted")
drain(watch)
assert(equal(watch:historyRows(aSolzreed), beforeRows), "late reply changed historical values")
assert(watch:latestQuote(aCrowns).ratio == 121 and watch:latestQuote(aSolzreed).ratio == 110
  and watch:latestQuote(bSolzreed).ratio == 95, "timeout overwrote a valid current reading")

-- Removing a duplicate name removes only its exact route; adding it again and
-- restarting preserve the ordered selection and each route's saved history.
watch:togglePack(aSolzreed.id)
assert(#watch:selectedEntries() == 2 and entryFor(watch, A, 22, 8).id == aCrowns.id)
watch:togglePack(A, 22, 5)
watch:setFocusPack(aSolzreed.id)
watch:saveSettings()
ids = selectedIds(watch)
local restarted = newWatch()
assert(equal(selectedIds(restarted), ids) and restarted.settings.focusId == aSolzreed.id,
  "route-aware selection or focus did not survive restart")
restarted:loadSelectedHistory(); drain(restarted)
assertOneRatio(restarted, entryFor(restarted, A, 22, 5), 110)
assertOneRatio(restarted, entryFor(restarted, B, 20, 5), 95)
assert(equal(restarted:historyRows(entryFor(restarted, A, 22, 5)), beforeRows),
  "persisted hourly history was read from a different route")

-- Duplicate pack names remain distinct in the actual picker, plot legends,
-- independent windows, and price view after restart.
restarted:showPackMenu()
local aMenu = {}
for i, option in ipairs(restarted.menuOptions) do
  if option.name == A then
    aMenu[#aMenu + 1] = {id = option.id, route = restarted.menuRouteLabels[i].text}
    assert(restarted.menuNameLabels[i].text == "[x] " .. A)
  end
end
assert(#aMenu == 2 and aMenu[1].id ~= aMenu[2].id and aMenu[1].route ~= aMenu[2].route,
  "picker cannot distinguish the same pack on different routes")
restarted.menuDone.handlers.OnClick()
restarted:setGraphOnly(true)
local function mini(identity)
  for _, graph in ipairs(restarted.miniGraphs) do if graph.id == identity then return graph end end
  error("selected route has no mini-graph: " .. identity)
end
local firstMini, secondMini = mini(aCrowns.id), mini(aSolzreed.id)
assert(firstMini ~= secondMini and firstMini.routeLabel.text ~= secondMini.routeLabel.text)
firstMini.title.handlers.OnDragStart(); firstMini.window.x, firstMini.window.y = 140, 190
firstMini.title.handlers.OnDragStop()
secondMini.title.handlers.OnDragStart(); secondMini.window.x, secondMini.window.y = 800, 310
secondMini.title.handlers.OnDragStop()
assert(restarted.settings.graphPositions[aCrowns.id].x == 140
  and restarted.settings.graphPositions[aSolzreed.id].x == 800,
  "same-name mini-graphs overwrote each other's saved route positions")
secondMini.expand.handlers.OnClick()
assert(restarted.settings.focusId == aSolzreed.id)
restarted.settings.metric = "price"; restarted:render()
for _, series in ipairs(restarted.comparisonData) do
  if series.name == A then
    assert(series.pricing.base == (series.to == 8 and 3000 or 6000),
      "displayed series lost its destination-specific payout")
  end
end
restarted.settings.metric = "rate"
restarted.graphLayoutButton.handlers.OnClick()
assert(restarted.settings.graphLayout == "combined" and saved.TradePacksRateSettings.graphLayout == "combined")
restarted.graphOnlyButton.handlers.OnClick()
local combined = restarted.combinedGraph
assert(combined.window:IsVisible() and not restarted.window:IsVisible())
for _, graph in ipairs(restarted.miniGraphs) do assert(not graph.window:IsVisible()) end
assert(#combined.chart.layers == 3 and combined.lowValue == 90 and combined.highValue == 130,
  "combined graph did not include all selected route series on payout brackets")
local brackets = {}
for _, tick in ipairs(combined.chart.valueAxis) do if tick.visible then brackets[tick.value] = true end end
for _, value in ipairs({90, 100, 110, 120, 130}) do assert(brackets[value], "missing combined percentage bracket") end
local beforeCombined = combined
combined.expand.handlers.OnClick()
assert(restarted.window:IsVisible() and not combined.window:IsVisible())
restarted.graphOnlyButton.handlers.OnClick()
assert(restarted.combinedGraph == beforeCombined and combined.window:IsVisible(), "combined view leaked another window")

-- Root-background dragging uses the same detach/scaled persistence path as
-- the title, while read-only labels don't steal the root's mouse target.
combined.expand.handlers.OnClick()
restarted.settings.detached = false; restarted:place()
assert(restarted.window.drag and restarted.window.pick and restarted.rate.pick == false)
local function assertWindowPosition(window, x, y, message)
  local actualX, actualY = window:GetOffset()
  assert(math.abs(actualX - x) < 0.000001 and math.abs(actualY - y) < 0.000001, message)
end
for _, factor in ipairs({0.8, 1.5}) do
  ctx.scale = function() return factor end
  for _, point in ipairs({{320, 180}, {447, 235}, {-80, 30}, {1920 / factor - 90, 1080 / factor - 40}}) do
    local x, y = point[1], point[2]
    restarted.window.handlers.OnDragStart()
    restarted.window.x, restarted.window.y = x, y
    local anchors = restarted.window.anchorCalls
    restarted:place(); restarted:layoutComparison(6); restarted:render()
    assertWindowPosition(restarted.window, x, y, "layout refresh interrupted an active full-panel drag")
    assert(restarted.window.anchorCalls == anchors, "active full-panel drag rebuilt anchors from the old position")
    restarted.window.handlers.OnDragStop()
    assert(restarted.settings.detached and math.abs(saved.TradePacksRateSettings.x - x * factor) < 0.000001
      and math.abs(saved.TradePacksRateSettings.y - y * factor) < 0.000001,
      "background drag did not detach and persist scaled coordinates")
    assertWindowPosition(restarted.window, x, y, "full panel jumped on scaled release")
    assert(restarted.window.anchorCalls == anchors, "successful full-panel drop rebuilt its anchors")
    restarted:render(); restarted:place()
    assertWindowPosition(restarted.window, x, y, "full panel scaled or clamped a reachable saved position")
    restarted:toggle(); restarted:toggle()
    assertWindowPosition(restarted.window, x, y, "full panel moved on reopening")
    restarted = newWatch()
    assertWindowPosition(restarted.window, x, y, "full panel moved after restart")
  end
end
assert(restarted.fromButton.handlers.OnClick and restarted.chart.hits[15].handlers.OnClick,
  "broad drag surface removed interactive controls")
ctx.scale = function() return 1 end

-- Background controls share one saved preference across both floating layouts,
-- reuse their drawables, and never move or make the plot intercept clicks.
restarted.settings.graphLayout = "combined"
restarted:setGraphOnly(true)
local backdropGraph = restarted.combinedGraph
local graphX, graphY = backdropGraph.window:GetOffset()
local backgrounds = {}
for _, mode in ipairs({"shaded", "dark", "transparent"}) do
  backdropGraph.backgroundButton.handlers.OnClick()
  local alpha = mode == "shaded" and 0.5 or mode == "dark" and 0.9 or 0
  assert(restarted.settings.graphBackground == mode and saved.TradePacksRateSettings.graphBackground == mode,
    "background control did not save the shared preference")
  local graphs = {backdropGraph}
  for _, graph in ipairs(restarted.miniGraphs) do graphs[#graphs + 1] = graph end
  for _, graph in ipairs(graphs) do
    assert(graph.background.color[4] == alpha and graph.window.pick == false,
      "background choice did not update a graph or changed its mouse hitbox")
    assert(graph.background.layer == "background", "backdrop could cover chart content")
    if backgrounds[graph] then assert(backgrounds[graph] == graph.background, "background toggle leaked drawables") end
    backgrounds[graph] = graph.background
  end
  assertWindowPosition(backdropGraph.window, graphX, graphY, "background selection moved the graph")
end
restarted.backgroundButton.handlers.OnClick()
assert(restarted.settings.graphBackground == "shaded")
restarted = newWatch()
assert(restarted.settings.graphBackground == "shaded" and restarted.combinedGraph.background.color[4] == 0.5,
  "background preference was lost on restart")
for _, graph in ipairs(restarted.miniGraphs) do assert(graph.background.color[4] == 0.5) end
assert(#errors == 0, table.concat(errors, "; "))
print("Rates route tests passed: migration, independent routes, pricing, polling, history, missing replies and restart")
