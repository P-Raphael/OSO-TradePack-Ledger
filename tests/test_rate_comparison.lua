-- Run from Addon: lua TradePacks/tests/test_rate_comparison.lua
-- Mock tests cover data selection and chart instructions, not native rendering.
local now = 20000 * 86400 + 20 * 3600
local saved, widgets, errors, queries = {}, {}, {}, {}
local reads, writes = 0, 0
local lineMutations, markerAnchors = 0, 0
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
  LoadData = function(_, key) reads = reads + 1; return copy(saved[key]) end,
  SaveData = function(_, key, value) writes = writes + 1; saved[key] = copy(value) end,
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
  if self.kind == "drawable" and self.layer == "artwork" then markerAnchors = markerAnchors + 1 end
end
function Widget:RemoveAllAnchors() self.anchor = nil end
function Widget:EnablePick(pick) self.pick = pick end
function Widget:EnableDrag(drag) self.drag = drag end
function Widget:SetPoints(points) self.points = copy(points); lineMutations = lineMutations + 1 end
function Widget:ClearPoints() self.points = {}; lineMutations = lineMutations + 1 end
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
    local w = widget("window", name, nil, 100, 150, width, height)
    w:Show(false); w.popupResizeHeights = {}
    return w, function(newHeight)
      w.popupResizeHeights[#w.popupResizeHeights + 1] = newHeight
      w:SetExtent(width, newHeight)
    end
  end,
  costEstimate = function(name) return costs[name] end,
  reportSaveError = function(kind, err) errors[#errors + 1] = kind .. ": " .. tostring(err) end
}
local A, B, C = "Halcyona Preserved Gilda Specialty", "Cinderstone Preserved Gilda Specialty", "Pack without price"
TWOCROWNS_PRICE = {[A] = {3000}, [B] = {6000}}
X2Ability = {GetAllMyActabilityInfos = function() return {{name = "Commerce", point = 0, modifyPoint = 0}} end}
X2Store = {
  GetProductionZoneGroups = function() return {{id = 22, zoneGroupName = "Halcyona"}} end,
  GetSellableZoneGroups = function() return {{id = 8, zoneGroupName = "Two Crowns"}, {id = 5, zoneGroupName = "Solzreed"}} end,
  GetSpecialtyRatioBetween = function(_, from, to)
    queries[#queries + 1] = {from = from, to = to, at = now}; return 30000
  end
}
checkPackRatio = nil
dofile("TradePacks/MinuteHistory.lua")
dofile("TradePacks/RateRoutes.lua")
dofile("TradePacks/RateChart.lua")
dofile("TradePacks/RateCombined.lua")
dofile("TradePacks/RateWatch.lua")
local function newWatch(settings)
  if settings then saved.TradePacksRateSettings = copy(settings) end
  return TradePacksRateWatch.new(ctx)
end
local function drain(watch)
  local count = 0
  while watch.head <= watch.tail and count < 1000 do watch:workOne(); count = count + 1 end
  assert(count < 1000, "history queue failed to drain: " .. table.concat(errors, "; "))
end
local function selected(watch, expected)
  assert(equal(watch.settings.selectedPacks, expected), "selected packs differ from the expected ordered set")
end
local function seed(watch, name, points)
  local series = watch:seriesFor(watch.settings.from, watch.settings.to, name)
  for _, point in ipairs(points) do watch:sample(series, now + point[1] * 60, point[2]) end
  drain(watch)
end
local function data(watch, name)
  for _, series in ipairs(watch.comparisonData) do if series.name == name then return series end end
  error("comparison data missing for " .. name)
end
local function hasVisibleMarker(layer)
  for _, marker in ipairs(layer.markers) do if marker.visible then return true end end
  return false
end
local function clickDone()
  for _, w in pairs(widgets) do
    if w.text == "Done" and w.visible and w.handlers.OnClick then w.handlers.OnClick(); return end
  end
  error("multi-select menu has no Done action")
end

-- Existing single-pack preferences migrate, and focus never changes membership.
local watch = newWatch({from = 22, to = 8, pack = A})
selected(watch, {A})
watch.packs = {{name = A}, {name = B}, {name = C}}
watch:togglePack(B)
selected(watch, {A, B})
watch:setFocusPack(B)
assert(watch.settings.pack == B)
selected(watch, {A, B})
watch:togglePack(B)
selected(watch, {A})
assert(watch.settings.pack == A, "deselected focus was retained")
watch:togglePack(A)
selected(watch, {A})

-- The menu stays open for repeated selections, then closes explicitly.
watch:toggle()
local singlePackHeight = watch.window.height
local resizeCalls = #watch.window.popupResizeHeights
watch.packButton.handlers.OnClick()
assert(watch.menu:IsVisible())
local menuIndex
for index, option in ipairs(watch.menuOptions) do if option.name == B then menuIndex = index; break end end
assert(menuIndex, "available pack missing from selector")
watch.menuRows[menuIndex].handlers.OnClick()
assert(watch.menu:IsVisible(), "pack selector closed after one selection")
selected(watch, {A, B})
assert(watch.window.height > singlePackHeight and #watch.window.popupResizeHeights > resizeCalls,
  "comparison expansion bypassed the popup resize helper")
assert(watch.window.popupResizeHeights[#watch.window.popupResizeHeights] == watch.panelHeight,
  "popup background received the wrong expanded height")
clickDone()
assert(not watch.menu:IsVisible())
resizeCalls = #watch.window.popupResizeHeights
watch:togglePack(B)
assert(watch.window.height == singlePackHeight and #watch.window.popupResizeHeights > resizeCalls,
  "comparison shrink bypassed the popup resize helper")
assert(watch.window.popupResizeHeights[#watch.window.popupResizeHeights] == singlePackHeight)
watch:togglePack(B)

-- Keep the comparison bounded and preserve its order across a restart.
for i = 1, 5 do watch:togglePack("Additional pack " .. i) end
assert(#watch.settings.selectedPacks == 6, "comparison should be limited to six packs")
watch:saveSettings()
local persisted = copy(watch.settings.selectedPacks)
local restarted = newWatch()
selected(restarted, persisted)
assert(restarted.settings.pack == watch.settings.pack, "focused detail pack did not persist")

-- One route request supplies every selected pack; changing focus/selection must
-- neither bypass the cooldown nor multiply native server calls.
saved, queries, errors = {}, {}, {}
watch = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B}, recentHours = 0.25})
watch:toggle()
assert(#queries == 1, "comparison created more than one route request")
assert(watch:receive({{itemInfo = {name = A}, ratio = 120}, {itemInfo = {name = B}, ratio = 120},
  {itemInfo = {name = C}, ratio = 90}}))
drain(watch)
local revisionBefore = watch.revision
seed(watch, "Unselected source pack", {{0, 77}})
assert(watch.revision == revisionBefore, "unrelated pack observation unnecessarily dirtied the comparison")
for i = 1, 10 do watch:setFocusPack(i % 2 == 0 and A or B); watch:query() end
assert(#queries == 1, "changing focused pack bypassed the route cooldown")

-- Shared axes: equal rates must occupy the same Y; independent base prices must
-- produce different price values. Sparse observations must retain visible gaps.
seed(watch, A, {{-3, 100}, {-2, 110}})
seed(watch, B, {{-3, 100}, {-2, 110}})
watch.settings.metric = "rate"; watch:setFocusPack(A); watch:render()
assert(#watch.comparisonData == 2)
local a, b = data(watch, A), data(watch, B)
assert(a.count == 3 and b.count == 3 and a.layout.count == 15)
assert(a.columns[12].ratio == 100 and b.columns[13].ratio == 110)
assert(a.columns[14] == nil and b.columns[14] == nil, "missing minute became an observation")
local layerA, layerB = watch.chart.layers[1], watch.chart.layers[2]
assert(not equal(layerA.color, layerB.color), "comparison series share the same color")
assert(#layerA.line.points == 1 and #layerB.line.points == 1, "line joined observations across a missing minute")
assert(layerA.markers[12].anchor[5] == layerB.markers[12].anchor[5], "equal rates use different Y axes")
assert(layerA.markers[15].anchor[5] == layerB.markers[15].anchor[5])
watch.seriesLegend[2].handlers.OnClick()
assert(watch.settings.pack == B, "legend click did not focus its pack's details")
selected(watch, {A, B})
layerA.hits[12].handlers.OnClick()
assert(watch.settings.pack == A and watch.selectedPoint.at == now - 180,
  "point selection used the previously focused pack")
layerB.hits[13].handlers.OnClick()
assert(watch.settings.pack == B and watch.selectedPoint.at == now - 120)
selected(watch, {A, B})
watch.settings.metric = "price"; watch:render()
a, b = data(watch, A), data(watch, B)
assert(a.columns[15].priceCopper == 360000 and b.columns[15].priceCopper == 720000,
  "price comparison reused the focused pack's payout base")
assert(layerA.markers[15].anchor[5] ~= layerB.markers[15].anchor[5], "different prices collapsed onto separate Y scales")

-- Period changes apply to every selected pack, including hourly aggregation.
watch.settings.recentHours = 6; watch:loadSelectedHistory(); drain(watch); watch:render()
assert(data(watch, A).layout.count == 6 and data(watch, B).layout.count == 6)
assert(data(watch, A).count == 2 and data(watch, B).count == 2)
watch.settings.mode, watch.settings.hourlyDays = "hourly", 3
watch:loadSelectedHistory(); drain(watch); watch:render()
assert(data(watch, A).layout.hourly and data(watch, B).layout.hourly)
assert(data(watch, A).count == 2 and data(watch, B).count == 2)
watch.settings.mode, watch.settings.recentHours = "recent", 0.25
watch:loadSelectedHistory(); drain(watch); watch:render()
assert(data(watch, A).layout.count == 15 and data(watch, B).count == 3)

-- A pack lacking a price remains selected without inventing a price, and an
-- entirely unobserved selection does not borrow another pack's history.
watch:togglePack(C); drain(watch); watch:render()
assert(#watch.comparisonData == 3)
assert(data(watch, C).count == 1, "the route's observed third pack should have one reading")
assert(not hasVisibleMarker(watch.chart.layers[3]), "unsupported price was fabricated")
watch:togglePack("Unobserved pack"); drain(watch); watch:render()
assert(data(watch, "Unobserved pack").count == 0)
assert(not hasVisibleMarker(watch.chart.layers[4]), "unobserved pack borrowed comparison data")
watch:togglePack("Unobserved pack")

-- Missing profit costs for the focused pack must not conceal another pack whose
-- costs are complete; negative profit still has a zero break-even reference.
costs[A] = {missing = "Transport: not configured", missingComponents = {"Transport: not configured"}}
costs[B] = {totalCopper = 800000, stalePrices = true}
watch.settings.metric = "profit"; watch:setFocusPack(A); watch:render()
assert(not hasVisibleMarker(watch.chart.layers[1]), "profit was plotted with incomplete costs")
assert(hasVisibleMarker(watch.chart.layers[2]), "missing focused costs hid a valid comparison")
assert(data(watch, B).columns[15].profitCopper == -80000)
assert(not watch.chart.emptyTitle.visible, "empty-state message covered a valid comparison")
assert(watch.chart.zeroLine.visible, "negative-profit comparison lost break-even line")
assert(watch.chart.zeroLine.points[1].beginY >= 0 and watch.chart.zeroLine.points[1].beginY <= watch.chart.height,
  "break-even baseline fell outside the comparison plot")
assert(watch.seriesLegend[2].text:find("cached costs", 1, true),
  "non-focused pack's stale profit costs were not disclosed in its legend")
assert(watch.legend.text:find("cached costs", 1, true),
  "general profit legend ignored stale costs from a non-focused comparison")

-- Transparent mode separates the selected packs into independent mini-graphs
-- without adding clickable chart areas.
watch:setGraphOnly(true); watch:render()
assert(watch.overlay:IsVisible() and not watch.window:IsVisible())
assert(#watch.overlay.draws == 0)
assert(watch.miniGraphs[1].name == A and watch.miniGraphs[2].name == B)
assert(hasVisibleMarker(watch.miniGraphs[2].chart.layers[1]))
assert(watch.miniGraphs[2].status.text:find("cached", 1, true)
  or watch.miniGraphs[2].coverage.text:find("cached", 1, true),
  "transparent graph concealed its cached cost source")
for _, graph in ipairs(watch.miniGraphs) do
  for _, layer in ipairs(graph.chart.layers) do
    assert(layer.line.pick == false and #layer.hits == 0, "mini-graph intercepts chart clicks")
  end
end
watch:togglePack(C); watch:render()
assert(not watch.miniGraphs[3].window:IsVisible(), "deselected mini-graph remained visible")
watch:setGraphOnly(false); watch:render()
assert(not hasVisibleMarker(watch.chart.layers[3]) and not watch.chart.layers[3].line.visible,
  "deselected full chart layer remained visible")

-- Cached selections, focus, redraws and history loading must not reread the same
-- persisted histories. Selection settings writes are allowed, history writes are not.
drain(watch)
local beforeReads, beforeWrites = reads, writes
local beforeLines, beforeAnchors = lineMutations, markerAnchors
for i = 1, 5 do watch:render(); watch:loadSelectedHistory(); drain(watch) end
assert(reads == beforeReads and writes == beforeWrites, "cached comparison redraw reread or rewrote histories")
assert(lineMutations == beforeLines and markerAnchors == beforeAnchors,
  "unchanged comparison repeatedly rebuilt native lines or marker anchors")

-- Restart restores both selected histories, including the non-focused series.
watch:saveSettings()
local restored = newWatch()
restored:loadSelectedHistory(); drain(restored); restored:render()
selected(restored, {A, B})
assert(data(restored, A).count == 3 and data(restored, B).count == 3,
  "restart restored only the focused pack's minute history")
assert(data(restored, B).columns[15].profitCopper == -80000)

-- Browsing another route retains existing selected series and their history.
watch:selectRoute(22, 5)
selected(watch, {A, B})
drain(watch); watch:render()
for _, entry in ipairs(watch.comparisonData) do
  assert(entry.to == 8 and entry.count == 3, "browsing replaced a selected route's history")
end
assert(next(watch.latest) == nil)
now = now + 30
assert(watch:query())
assert(watch:receive({{itemInfo = {name = C}, ratio = 90}}))
drain(watch); watch:render()
selected(watch, {A, B})
watch:togglePack(C)
selected(watch, {A, B, C})
assert(#watch.comparisonData == 3 and data(watch, C).count == 1 and data(watch, C).to == 5)

-- An omitted pack remains selected with its own missing/last-known state.
local reconciled = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B}, recentHours = 0.25})
reconciled:toggle()
assert(reconciled:receive({{itemInfo = {name = A}, ratio = 130}, {itemInfo = {name = C}, ratio = 90}}))
drain(reconciled); reconciled:render()
selected(reconciled, {A, B})
assert(reconciled.settings.pack == A, "available focused pack changed during selection reconciliation")
reconciled:togglePack(C)
selected(reconciled, {A, B, C})
reconciled:togglePack(B)
for i = 1, 4 do reconciled:togglePack("Available extra pack " .. i) end
assert(#reconciled.settings.selectedPacks == 6,
  "removed unavailable selection continued occupying a comparison slot")
for _, name in ipairs(reconciled.settings.selectedPacks) do assert(name ~= B) end
assert(#errors == 0, table.concat(errors, "; "))
print("Rates comparison tests passed: selection, persistence, per-pack values, shared axes, gaps, mini-graphs and bounded work")
