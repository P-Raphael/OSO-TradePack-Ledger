-- Run from Addon: lua TradePacks/tests/test_rate_mini_graphs.lua
-- Mock tests cover data selection and chart instructions, not native rendering.
local now = 20000 * 86400 + 20 * 3600
local saved, widgets, errors, queries = {}, {}, {}, {}
local reads, writes = 0, 0
local lineMutations, markerAnchors, windowAnchors = 0, 0, 0
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
  if self.kind == "window" and self.anchor[1] == "TOPLEFT" and self.anchor[2] == "UIParent" then
    self.x, self.y = self.anchor[3], self.anchor[4]
    self.anchorCalls, windowAnchors = (rawget(self, "anchorCalls") or 0) + 1, windowAnchors + 1
  end
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
local routeA, routeB = "22_8:" .. A, "22_8:" .. B
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

-- Independent transparent windows share collection and period controls while
-- keeping pack data, position, scale and missing-data messages separate.
local function graphFor(watch, name)
  for _, graph in ipairs(watch.miniGraphs) do
    if graph.name == name and graph.window:IsVisible() then return graph end
  end
  error("visible mini-graph missing for " .. name)
end
local function visibleGraphs(watch)
  local count = 0
  for _, graph in ipairs(watch.miniGraphs) do if graph.window:IsVisible() then count = count + 1 end end
  return count
end
local function position(graph)
  -- Native movement changes GetOffset without updating the last AddAnchor call.
  return graph.window:GetOffset()
end
local function drag(graph, x, y)
  assert(graph.title.handlers.OnDragStart and graph.title.handlers.OnDragStop, "mini-graph has no drag handlers")
  graph.title.handlers.OnDragStart()
  graph.window.x, graph.window.y = x, y
  graph.title.handlers.OnDragStop()
end
local function withinScreen(graph)
  local x, y = position(graph)
  assert(x >= 0 and y >= 0 and x + graph.window.width <= UIParent:GetScreenWidth()
    and y + graph.window.height <= UIParent:GetScreenHeight(), "default mini-graph is outside the screen")
end
local function titleReachable(graph)
  local x, y = position(graph)
  local scale = ctx.scale()
  local screenWidth, screenHeight = UIParent:GetScreenWidth() / scale, UIParent:GetScreenHeight() / scale
  local visibleTitle = math.min(screenWidth, x + 390) - math.max(0, x + 28)
  assert(visibleTitle >= 32 and y >= 0 and y + 18 <= screenHeight,
    "saved mini-graph did not recover an accessible drag handle")
end
local function assertPosition(graph, x, y, message)
  local actualX, actualY = position(graph)
  assert(math.abs(actualX - x) < 0.000001 and math.abs(actualY - y) < 0.000001, message)
end
local function positionCount(positions)
  local count = 0
  for _ in pairs(positions) do count = count + 1 end
  return count
end
local function separate(first, second, message)
  local ax, ay = position(first)
  local bx, by = position(second)
  assert(ax + first.window.width <= bx or bx + second.window.width <= ax
    or ay + first.window.height <= by or by + second.window.height <= ay, message)
end

local watch = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B}, recentHours = 0.25,
  graphX = 90, graphY = 70})
watch:toggle()
assert(#queries == 1)
assert(watch:receive({{itemInfo = {name = A}, ratio = 120}, {itemInfo = {name = B}, ratio = 240},
  {itemInfo = {name = C}, ratio = 95}}))
drain(watch)
seed(watch, A, {{-2, 100}, {-1, 110}})
seed(watch, B, {{-2, 200}, {-1, 220}})
watch:setGraphOnly(true); watch:render()
assert(visibleGraphs(watch) == 2 and not watch.window:IsVisible(), "graph-only did not create two independent windows")
local a, b = graphFor(watch, A), graphFor(watch, B)
assert(a.window ~= b.window and a.chart ~= b.chart, "selected packs share a single mini-graph")
assert(watch.overlay == a.window and watch.overlayChart == a.chart, "legacy first-graph aliases changed")
assert(#a.window.draws == 0 and #b.window.draws == 0, "mini-graph has an opaque background")
assert(a.window.height == 264 and b.window.height == 264, "mini-graphs grew into a combined legend panel")
local ax, ay = position(a)
assert(ax == 90 and ay == 70, "legacy graph position did not migrate to the first selected pack")
local bx, by = position(b)
assert(ax ~= bx or ay ~= by, "default mini-graphs overlap at the same origin")
withinScreen(a); withinScreen(b)
assert(a.title.text:find("Halcyona", 1, true) and b.title.text:find("Cinderstone", 1, true),
  "mini-graph title does not identify its own pack")
assert(a.quoteAt == now and b.quoteAt == now)
assert(a.highValue ~= b.highValue, "a pack above 130% should extend only its own graph scale")
assert(#a.chart.layers == 1 and #b.chart.layers == 1, "a mini-graph includes comparison series from another pack")
for _, fixture in ipairs({{a, 100}, {b, 200}}) do
  local graph, value = fixture[1], fixture[2]
  local expected = -graph.chart.height * (value - graph.lowValue) / (graph.highValue - graph.lowValue)
  assert(math.abs(graph.chart.layers[1].markers[13].anchor[5] - expected) < 0.000001,
    "mini-graph point uses another pack's value scale")
end
for _, graph in ipairs({a, b}) do
  assert(graph.chart.layers[1].line.pick == false and #graph.chart.layers[1].hits == 0,
    "transparent mini-graph intercepts gameplay clicks")
end

-- Moving one graph is saved under its exact pack and route and leaves all others
-- unchanged; opening or moving windows does not issue extra native queries.
local queryCount = #queries
local bBeforeX, bBeforeY = position(b)
local bBeforeAnchors = b.window.anchorCalls
drag(a, 310, 170)
assert(saved.TradePacksRateSettings.graphPositions[routeA].x == 310
  and saved.TradePacksRateSettings.graphPositions[routeA].y == 170, "first pack position was not persisted")
assert(position(b) == bBeforeX and select(2, position(b)) == bBeforeY, "dragging one graph moved another")
assert(b.window.anchorCalls == bBeforeAnchors, "dragging one graph reanchored another window")
drag(b, 1040, 580)
assert(saved.TradePacksRateSettings.graphPositions[routeB].x == 1040
  and saved.TradePacksRateSettings.graphPositions[routeB].y == 580, "second pack position was not persisted")
assert(saved.TradePacksRateSettings.graphPositions[routeA].x == 310, "second drag overwrote the first pack's position")
assert(#queries == queryCount, "dragging graphs issued duplicate route requests")

-- Positions and each pack's minute data survive a restart, including when the
-- selected pack order changes and the same widget slots are reassigned.
local stored = copy(saved.TradePacksRateSettings)
local restarted = newWatch()
restarted:loadSelectedHistory(); drain(restarted); restarted:render()
assert(visibleGraphs(restarted) == 2)
a, b = graphFor(restarted, A), graphFor(restarted, B)
assert(position(a) == 310 and select(2, position(a)) == 170, "first position was not restored")
assert(position(b) == 1040 and select(2, position(b)) == 580, "second position was not restored")
assert(hasVisibleMarker(a.chart.layers[1]) and hasVisibleMarker(b.chart.layers[1]), "restart lost a pack's minute plot")
local firstSlot = restarted.miniGraphs[1]
a.close.handlers.OnClick()
selected(restarted, {B})
assert(visibleGraphs(restarted) == 1 and restarted.miniGraphs[1] == firstSlot, "closing one graph failed to reuse bounded slots")
b = graphFor(restarted, B)
assert(position(b) == 1040 and select(2, position(b)) == 580, "slot reassignment used the removed pack's position")
drag(b, 930, 470)
assert(saved.TradePacksRateSettings.graphPositions[routeB].x == 930
  and saved.TradePacksRateSettings.graphPositions[routeA].x == 310,
  "reassigned slot drag handler persisted the previous pack name")
restarted:togglePack(A); restarted:render()
selected(restarted, {B, A})
a, b = graphFor(restarted, A), graphFor(restarted, B)
assert(position(a) == 310 and position(b) == 930, "readding a pack lost its independent saved position")

-- Opening controls from a mini-graph selects its details without removing any
-- selected pack. Re-entering graph-only restores every window and its position.
a.expand.handlers.OnClick()
assert(restarted.window:IsVisible() and visibleGraphs(restarted) == 0,
  "expand did not return to the complete controls")
assert(restarted.settings.pack == A, "expand focused a different pack's details")
selected(restarted, {B, A})
restarted:setGraphOnly(true); restarted:render()
assert(visibleGraphs(restarted) == 2)
assert(position(graphFor(restarted, A)) == 310 and position(graphFor(restarted, B)) == 930)

-- The graph period applies consistently to every window and is redrawn from
-- memory; each mini-graph retains its own data and value range.
restarted.settings.recentHours = 6
restarted:loadSelectedHistory(); drain(restarted); restarted:render()
assert(data(restarted, A).layout.count == 6 and data(restarted, B).layout.count == 6)
a, b = graphFor(restarted, A), graphFor(restarted, B)
assert(a.ticks[1].text == b.ticks[1].text and a.ticks[5].text == b.ticks[5].text,
  "mini-graph time axes disagree after a period change")
assert(a.coverage.text:find("6", 1, true) and b.coverage.text:find("6", 1, true),
  "a mini-graph kept the previous period coverage")
restarted.settings.mode, restarted.settings.hourlyDays = "hourly", 3
restarted:loadSelectedHistory(); drain(restarted); restarted:render()
assert(data(restarted, A).layout.hourly and data(restarted, B).layout.hourly)
restarted.settings.mode, restarted.settings.recentHours = "recent", 0.25
restarted:loadSelectedHistory(); drain(restarted); restarted:render()
assert(data(restarted, A).layout.count == 15 and data(restarted, B).layout.count == 15)
assert(a.ticks[1].text == b.ticks[1].text)

-- Price and profit failures belong to the affected mini-graph. Other packs
-- stay plotted, and cached pricing is disclosed on the matching pack's graph.
restarted:togglePack(C); drain(restarted)
restarted.settings.metric = "price"; restarted:render()
a, b = graphFor(restarted, A), graphFor(restarted, B)
local c = graphFor(restarted, C)
assert(hasVisibleMarker(a.chart.layers[1]) and hasVisibleMarker(b.chart.layers[1]))
assert(not hasVisibleMarker(c.chart.layers[1]) and c.chart.emptyTitle.visible,
  "missing payout reference did not show an isolated empty state")
assert(not a.chart.emptyTitle.visible and not b.chart.emptyTitle.visible)
costs[A] = {missing = "Transport: not configured", missingComponents = {"Transport: not configured"}}
costs[B] = {totalCopper = 1600000, stalePrices = true}
restarted.settings.metric = "profit"; restarted:render()
assert(not hasVisibleMarker(a.chart.layers[1]) and a.chart.emptyTitle.visible,
  "unconfigured pack has a fabricated profit line")
assert(hasVisibleMarker(b.chart.layers[1]) and not b.chart.emptyTitle.visible,
  "another pack's missing costs hid the valid profit graph")
assert(b.chart.zeroLine.visible, "independent negative-profit plot lost its zero baseline")
assert((b.coverage.text .. " " .. b.status.text):find("cached", 1, true),
  "cached cost assumption was not disclosed on its own graph")

-- A current observation for one pack cannot freshen another pack's stale
-- headline or age timer, even when the stale pack is not the focused details.
local oldA, oldB = restarted.latest[A], restarted.latest[B]
restarted.latest[A], restarted.latest[B] = {ratio = 120, at = now}, {ratio = 240, at = now - 125}
restarted:render(); restarted:renderStatus()
assert(a.quoteAt == now and b.quoteAt == now - 125, "mini-graphs share the focused quote timestamp")
assert(a.status.text:find("Updated 0s ago", 1, true) and not a.status.text:find("stale", 1, true),
  "a fresh pack inherited another pack's stale status")
assert(b.status.text:find("Updated 2m ago - stale", 1, true) and b.quoteLabel.text:find("stale", 1, true),
  "a stale pack inherited the focused pack's fresh status")
restarted.latest[A], restarted.latest[B] = oldA, oldB
restarted:render()

-- Drawing unchanged windows must not re-query, reload persisted history, or
-- rebuild native chart geometry. A status refresh must not rebuild lines.
drain(restarted)
local beforeReads, beforeWrites, beforeQueries = reads, writes, #queries
local beforeLines, beforeAnchors = lineMutations, markerAnchors
local beforeWindowAnchors = windowAnchors
for i = 1, 8 do restarted:render(); restarted:loadSelectedHistory(); drain(restarted); restarted:renderStatus() end
assert(reads == beforeReads and writes == beforeWrites, "unchanged mini-graphs performed persistence I/O")
assert(#queries == beforeQueries, "mini-graph redraw multiplied native route requests")
assert(lineMutations == beforeLines and markerAnchors == beforeAnchors,
  "unchanged mini-graphs repeatedly rebuilt native chart geometry")
assert(windowAnchors == beforeWindowAnchors, "unchanged mini-graphs repeatedly repositioned their windows")

-- Close affects only its graph until the last selection; closing the last
-- hides Rates without discarding the pack needed to reopen it.
c.close.handlers.OnClick()
selected(restarted, {B, A})
graphFor(restarted, A).close.handlers.OnClick()
selected(restarted, {B})
graphFor(restarted, B).close.handlers.OnClick()
assert(not restarted.settings.open and visibleGraphs(restarted) == 0)
selected(restarted, {B})
restarted:toggle()
assert(visibleGraphs(restarted) == 1 and graphFor(restarted, B).name == B,
  "last closed mini-graph could not reopen")

-- Saved placement data is bounded even after visiting many pack types, and
-- invalid/huge offsets cannot spawn windows outside the visible screen.
local positions = {[A] = {x = 310, y = 170, used = now}, [B] = {x = 1040, y = 580, used = now - 1},
  ["NaN offset"] = {x = 0 / 0, y = 100}, ["Infinite offset"] = {x = math.huge, y = 100},
  ["String offset"] = {x = "garbage", y = 100}}
for i = 1, 40 do positions["Old position " .. i] = {x = 30, y = 30, used = now - i - 10} end
local bounded = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B}, graphPositions = positions,
  graphOnly = true, open = true, recentHours = 0.25})
bounded:saveSettings()
assert(positionCount(saved.TradePacksRateSettings.graphPositions) <= 24, "position history grew beyond its fixed persistence bound")
assert(saved.TradePacksRateSettings.graphPositions[routeA] and saved.TradePacksRateSettings.graphPositions[routeB],
  "position eviction removed active selected packs")
for name, value in pairs(saved.TradePacksRateSettings.graphPositions) do
  assert(type(value.x) == "number" and value.x == value.x and math.abs(value.x) ~= math.huge
    and type(value.y) == "number" and value.y == value.y and math.abs(value.y) ~= math.huge,
    "invalid position survived validation: " .. name)
end
local clamped = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B}, graphOnly = true, open = true,
  graphPositions = {[A] = {x = -900000, y = -900000}, [B] = {x = 900000, y = 900000}}})
titleReachable(graphFor(clamped, A)); titleReachable(graphFor(clamped, B))
local six = {A, B, "Extra pack 1", "Extra pack 2", "Extra pack 3", "Extra pack 4"}
local grid = newWatch({from = 22, to = 8, pack = A, selectedPacks = six, graphOnly = true, open = true})
assert(visibleGraphs(grid) == 6 and #grid.miniGraphs <= 6, "mini-graph widget count is not bounded by selection limit")
local rectangles = {}
for _, graph in ipairs(grid.miniGraphs) do
  withinScreen(graph)
  local x, y = position(graph)
  for _, rect in ipairs(rectangles) do
    assert(x + graph.window.width <= rect.x or rect.x + rect.width <= x
      or y + graph.window.height <= rect.y or rect.y + rect.height <= y,
      "default mini-graphs overlap despite available screen space")
  end
  rectangles[#rectangles + 1] = {x = x, y = y, width = graph.window.width, height = graph.window.height}
end

-- Closing the first tile preserves the second pack's chosen position. A newly
-- added pack must use a free tile instead of landing on that surviving graph.
local changing = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B}, graphOnly = true, open = true})
local remainingX, remainingY = position(graphFor(changing, B))
graphFor(changing, A).close.handlers.OnClick()
selected(changing, {B})
changing:togglePack(C); changing:render()
selected(changing, {B, C})
assert(position(graphFor(changing, B)) == remainingX and select(2, position(graphFor(changing, B))) == remainingY,
  "adding a new pack shifted an existing saved graph")
separate(graphFor(changing, B), graphFor(changing, C), "new pack's default position overlaps the surviving saved graph")

-- A legacy first graph may already occupy the second or a later default tile.
-- Its migration must remain exact while all newly created graphs avoid it.
local legacyX, legacyY = position(grid.miniGraphs[4])
local migrated = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B, C},
  graphOnly = true, open = true, graphX = legacyX, graphY = legacyY})
assert(position(graphFor(migrated, A)) == legacyX and select(2, position(graphFor(migrated, A))) == legacyY,
  "legacy graph moved instead of retaining its existing tile")
separate(graphFor(migrated, A), graphFor(migrated, B), "new graph overlaps a legacy graph on a later tile")
separate(graphFor(migrated, A), graphFor(migrated, C), "third graph overlaps a migrated legacy graph")
separate(graphFor(migrated, B), graphFor(migrated, C), "new graphs overlap after legacy migration")
-- The second tile is the immediate collision case when adding the next pack.
legacyX, legacyY = position(grid.miniGraphs[2])
local migratedSecond = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B},
  graphOnly = true, open = true, graphX = legacyX, graphY = legacyY})
separate(graphFor(migratedSecond, A), graphFor(migratedSecond, B), "new graph overlaps legacy position at the next default tile")

-- Numeric strings from saved data become finite numeric offsets, and an empty
-- name cannot consume the limited per-pack position storage.
local normalized = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A}, graphOnly = true, open = true,
  graphPositions = {[A] = {x = "250", y = "140", used = "123"}, [""] = {x = 10, y = 20, used = now}}})
normalized:saveSettings()
local normalizedSaved = saved.TradePacksRateSettings.graphPositions
assert(type(normalizedSaved[routeA].x) == "number" and normalizedSaved[routeA].x == 250
  and type(normalizedSaved[routeA].y) == "number" and normalizedSaved[routeA].y == 140,
  "numeric saved offsets were not normalized")
assert(normalizedSaved[""] == nil, "empty pack name survived saved-position validation")

-- A route reply or deselection may replace a widget's pack during its native
-- drag. Ending that old drag must restore the replacement pack's own position.
local racing = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B}, graphOnly = true, open = true,
  graphPositions = {[A] = {x = 100, y = 100}, [B] = {x = 1040, y = 580}}})
local dragged = graphFor(racing, A)
dragged.title.handlers.OnDragStart()
dragged.window.x, dragged.window.y = 430, 310
racing:togglePack(A)
assert(dragged == graphFor(racing, B) and dragged.name == B, "test did not reassign the dragged widget's pack")
dragged.title.handlers.OnDragStop()
assert(position(dragged) == 1040 and select(2, position(dragged)) == 580,
  "replacement pack inherited a drag started for the removed pack")
assert(racing.settings.graphPositions[routeA].x == 100 and racing.settings.graphPositions[routeA].y == 100
  and racing.settings.graphPositions[routeB].x == 1040 and racing.settings.graphPositions[routeB].y == 580,
  "drag completion corrupted saved positions after slot reassignment")

-- Persist physical coordinates, but native movement and AddAnchor use UI units.
-- A drop must not jump, and successive drags/render/reopen must not accumulate scale.
for _, factor in ipairs({0.8, 1.5}) do
  ctx.scale = function() return factor end
  local scaled = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A}, graphOnly = true, open = true})
  for _, point in ipairs({{200, 160}, {317, 243}}) do
    local graph, x, y = graphFor(scaled, A), point[1], point[2]
    local beforeAnchors = graph.window.anchorCalls
    drag(graph, x, y)
    assertPosition(graph, x, y, "scaled mini-graph jumped when released")
    assert(graph.window.anchorCalls == beforeAnchors, "successful drop unnecessarily rebuilt mini-graph anchors")
    local persisted = saved.TradePacksRateSettings.graphPositions[routeA]
    assert(math.abs(persisted.x - x * factor) < 0.000001 and math.abs(persisted.y - y * factor) < 0.000001,
      "drag persistence ignored UI scaling")
    scaled:render(); scaled:syncMiniGraphs()
    assertPosition(graph, x, y, "normal refresh shifted a scaled mini-graph")
    scaled:toggle(); scaled:toggle()
    assertPosition(graph, x, y, "reopening applied UI scaling twice")
    scaled = newWatch()
    assertPosition(graphFor(scaled, A), x, y, "restart applied UI scaling twice")
  end
  -- Empty transparent space can extend offscreen if the title remains reachable.
  for _, point in ipairs({{-100, 40}, {1920 / factor - 100, 1080 / factor - 35}}) do
    local graph, x, y = graphFor(scaled, A), point[1], point[2]
    drag(graph, x, y)
    scaled:render(); scaled:syncMiniGraphs(true)
    assertPosition(graph, x, y, "reachable graph snapped inward to fit its invisible rectangle")
    scaled = newWatch()
    assertPosition(graphFor(scaled, A), x, y, "partially offscreen graph moved on restart")
    titleReachable(graphFor(scaled, A))
  end
end
ctx.scale = function() return 1 end

-- Before the route has returned its first available pack list, a visible
-- placeholder keeps both collection and the controls accessible. The first
-- response reuses this window instead of creating a hidden-query deadlock.
local empty = newWatch({from = 22, to = 8, graphOnly = true, open = true, recentHours = 0.25})
assert(#empty:selectedPackNames() == 0 and visibleGraphs(empty) == 1,
  "no initial pack selection hid the graph-only controls")
local placeholder = empty.miniGraphs[1]
assert(empty:shouldCollect() and placeholder.expand.handlers.OnClick and placeholder.close.handlers.OnClick,
  "empty graph-only state cannot collect or reopen controls")
local beforeEmptyQuery = #queries
assert(empty:query() and #queries == beforeEmptyQuery + 1,
  "empty graph-only state never requested its first pack list")
assert(empty:receive({{itemInfo = {name = A}, ratio = 125}}))
drain(empty); empty:render()
selected(empty, {A})
assert(graphFor(empty, A) == placeholder and hasVisibleMarker(placeholder.chart.layers[1]),
  "first route response did not populate the existing placeholder graph")

-- New readings redraw the visible mini-graphs without also rebuilding the
-- hidden combined chart. Returning to controls catches the overview up.
local work = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B},
  detached = true, open = true, recentHours = 0.25})
seed(work, A, {{-2, 100}, {-1, 110}, {0, 120}})
seed(work, B, {{-2, 200}, {-1, 220}, {0, 240}})
work:render()
local overviewSignature = work.chart.layers[1].renderSignature
assert(overviewSignature and work.window:IsVisible())
work:setGraphOnly(true)
local visibleSignature = graphFor(work, A).chart.layers[1].renderSignature
now = now + 60
seed(work, A, {{0, 180}})
work:render()
assert(work.chart.layers[1].renderSignature == overviewSignature,
  "fresh mini-graph data rebuilt the hidden overview")
assert(graphFor(work, A).chart.layers[1].renderSignature ~= visibleSignature,
  "skipping the hidden overview also stopped the visible mini-graph")
graphFor(work, A).expand.handlers.OnClick()
assert(work.window:IsVisible() and work.chart.layers[1].renderSignature ~= overviewSignature,
  "reopening controls did not update the overview with the latest observations")
assert(#errors == 0, table.concat(errors, "; "))
-- Resize uses native logical extents, redraws real line geometry, and saves only
-- at release. Each route and the combined graph retain independent styles.
local custom = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B},
  detached = true, open = true, graphOnly = true, recentHours = 0.25})
seed(custom, A, {{-2, 100}, {-1, 110}, {0, 120}})
seed(custom, B, {{-2, 105}, {-1, 115}, {0, 125}})
custom:render()
local first, second = graphFor(custom, A), graphFor(custom, B)
local px, py = position(first)
local beforePoints = copy(first.chart.line.points)
local function resize(graph, width, plotHeight)
  graph.resizeGrip.handlers.OnDragStart()
  graph.window.width, graph.window.height = width, plotHeight + graph.height - graph.chart.height
  local before = writes
  graph.window.handlers.OnUpdate(graph.window, 80)
  assert(writes == before, "live resizing wrote settings every frame")
  graph.resizeGrip.handlers.OnDragStop()
end
ctx.scale = function() return 1.5 end
resize(first, 800, 240)
assert(first.width == 800 and first.chart.width == 720 and first.chart.height == 240)
assert(first.chart.layers[1].line.width == 720 and first.chart.zeroLine.height == 240)
assert(not equal(beforePoints, first.chart.line.points), "resize did not invalidate unchanged data geometry")
assertPosition(first, px, py, "resize moved the graph")
assert(second.width == 440 and second.chart.height == 120, "resizing one pack affected another")
assert(saved.TradePacksRateSettings.graphStyles[routeA].width == 800, "logical sizes were scaled twice")
first.textButton.handlers.OnClick()
assert(first.compact and not first.routeLabel.visible and not first.quoteLabel.visible and not first.coverage.visible)
assert(first.title.text:find("%%") and first.height < 72 + 240 + 72, "compact layout did not collapse header")
assert(first.chart.height == 240 and first.title.visible)
first.fontButton.handlers.OnClick()
assert(first.font == 14 and custom.settings.graphStyles[routeA].font == 14)
drag(first, px + 10, py + 10)
custom = newWatch()
first, second = graphFor(custom, A), graphFor(custom, B)
assert(first.width == 800 and first.chart.height == 240 and first.compact and first.font == 14,
  "restart or dragging lost custom graph settings")
assert(second.width == 440 and not second.compact)
resize(first, 100, 20)
assert(first.width == 320 and first.chart.height == 80, "minimum size was not enforced")
resize(first, 2000, 900)
assert(first.width == 1200 and first.chart.height == 500, "maximum size was not enforced")
custom.settings.graphLayout = "combined"; custom:render()
local comparison = custom.combinedGraph
resize(comparison, 900, 300)
comparison.textButton.handlers.OnClick()
comparison.fontButton.handlers.OnClick()
assert(comparison.width == 900 and comparison.chart.height == 300 and comparison.compact and comparison.font == 14)
assert(comparison.legends[1].name.visible and not comparison.legends[1].detail.visible,
  "compact comparison still uses two lines per pack")
local cx, cy = comparison.window:GetOffset()
custom:togglePack(B)
assert(comparison.width == 900 and comparison.chart.height == 300,
  "selection change reset the combined plot size")
assertPosition(comparison, cx, cy, "selection change moved the customized combined graph")
custom = newWatch()
assert(custom.combinedGraph.width == 900 and custom.combinedGraph.chart.height == 300
  and custom.combinedGraph.compact, "combined customization was lost after restart")
assert(custom.settings.graphStyles[routeA].width == 1200, "combined style overwrote pack style")
ctx.scale = function() return 1 end
local resizeRace = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B},
  open = true, graphOnly = true,
  graphPositions = {[routeA] = {x = 100, y = 100}, [routeB] = {x = 800, y = 200}},
  graphStyles = {[routeA] = {width = 620}, [routeB] = {width = 880, plotHeight = 200, compact = true}}})
local replacing = graphFor(resizeRace, A)
replacing.resizeGrip.handlers.OnDragStart()
resizeRace:togglePack(A)
replacing.window.width, replacing.window.height = 1100, 600
replacing.resizeGrip.handlers.OnDragStop()
assert(replacing.id == routeB and replacing.width == 880 and replacing.chart.height == 200,
  "reused graph inherited a resize started for another route")
assert(resizeRace.settings.graphStyles[routeA].width == 620 and resizeRace.settings.graphStyles[routeB].width == 880,
  "resize completion overwrote another route's saved preferences")

-- Both modes share observations and pricing, but two independent value axes.
saved = {}
local dual = newWatch({from = 22, to = 8, pack = A, selectedPacks = {A, B, C},
  open = true, detached = true, recentHours = 0.25, metric = "rate"})
for _, name in ipairs({A, B, C}) do seed(dual, name, {{-4, 110}, {-2, 120}, {-1, 125}}) end
dual:render()
local queryCount = #queries
dual.valuesButton.handlers.OnClick()
assert(dual.settings.showRatePrice and dual.settings.metric == "rate", "value option changed the plotted metric")
dual:setGraphOnly(true)
assert(graphFor(dual, A).title.text:find("%%") and graphFor(dual, A).quoteLabel.text:find("Price: ~"),
  "separate graph does not show both current values")
dual.settings.graphLayout = "combined"; dual:render()
assert(dual.combinedGraph.legends[1].name.text:find("%%")
  and dual.combinedGraph.legends[1].detail.text:find("Price: ~"))
dual:setGraphOnly(false)
dual.metricButton.handlers.OnClick(); dual.metricButton.handlers.OnClick(); dual.metricButton.handlers.OnClick()
assert(dual.settings.metric == "both" and dual.chart.priceChart, "Graph: Both mode not reachable")
local function checkDual(chart)
  local price = assert(chart.priceChart)
  assert(price.rightAxis and price.dashed and price.plot.visible)
  assert(price.width == chart.width and price.height == chart.height, "price overlay dimensions differ")
  local rates, prices = 0, 0
  for _, tick in ipairs(chart.valueAxis) do if tick.visible then
    rates = rates + 1; assert(tick.label.text:find("%%"))
  end end
  for _, tick in ipairs(price.valueAxis) do if tick.visible then
    prices = prices + 1; assert(tick.label.text:find("g") and tick.label.anchor[3] == chart.width + 6)
    assert(not tick.line.visible, "second grid obscures the percentage grid")
  end end
  assert(rates > 0 and prices > 0, "one of the two scales is absent")
  assert(chart.layers[1].line.visible and price.layers[1].line.visible)
  assert(#price.layers[1].line.points > #chart.layers[1].line.points, "price line is not dashed")
end
checkDual(dual.chart)
assert(dual.chart.layers[3].line.visible and not dual.chart.priceChart.layers[3].line.visible,
  "unpriced pack lost its rate or gained fabricated price data")
for _, data in ipairs(dual.comparisonData) do for _, point in pairs(data.columns) do
  assert(point.value == point.ratio, "price values replaced the left percentage series")
  assert(point.priceCopper == dual:estimatePrice(data.pricing, point.ratio), "secondary prices use a different formula")
end end
local beforeLines = lineMutations
dual:render()
assert(lineMutations == beforeLines, "unchanged dual graph rebuilt line geometry")
dual.settings.graphLayout = "combined"; dual:setGraphOnly(true)
checkDual(dual.combinedGraph.chart)
resize(dual.combinedGraph, 820, 240)
checkDual(dual.combinedGraph.chart)
local oldOverlay = dual.combinedGraph.chart.priceChart
dual.settings.metric = "rate"; dual:render()
assert(not oldOverlay.plot.visible and dual.combinedGraph.chart.width == 740, "single-metric view retained price overlay/gutter")
dual.settings.metric = "both"; dual:saveSettings(); dual:render()
assert(dual.combinedGraph.chart.priceChart == oldOverlay, "mode toggle recreated the price overlay")
dual.settings.graphLayout = "separate"; dual:saveSettings(); dual:render()
checkDual(graphFor(dual, A).chart)
local missingGraph = graphFor(dual, C)
assert(missingGraph.chart.line.visible and not missingGraph.chart.priceChart.line.visible
  and missingGraph.quoteLabel.text:find("no payout price"), "missing-price status hid the rate")
dual = newWatch()
assert(dual.settings.metric == "both" and dual.settings.showRatePrice, "display options were not restored")
assert(#queries == queryCount, "display options made additional native price requests")

-- The floating controls must work with the full panel hidden, including paged
-- presets, custom values, and route-specific colors in a combined-only setup.
local function chooseMenu(watch, id)
  for i, option in ipairs(watch.menuOptions) do
    if option.id == id then
      watch.menuPage = math.ceil(i / 8); watch:renderMenu()
      watch.menuRows[(i - 1) % 8 + 1].handlers.OnClick()
      return
    end
  end
  error("missing menu option " .. tostring(id))
end
local floating = graphFor(dual, A)
for _, hours in ipairs({2, 3}) do
  floating.periodButton.handlers.OnClick()
  assert(dual.menu.visible and rawget(dual.menu, "parent") == nil and not dual.window.visible,
    "floating period picker depends on the hidden full window")
  chooseMenu(dual, hours)
  assert(dual.settings.recentHours == hours and floating.periodButton.text == hours .. "h")
  assert(dual.settings.graphOnly and not dual.menu.visible and not dual.window.visible)
end
floating.periodButton.handlers.OnClick(); floating.periodButton.handlers.OnClick()
assert(not dual.menu.visible, "period selector does not toggle its menu closed")
floating.periodButton.handlers.OnClick(); chooseMenu(dual, "custom")
assert(dual.periodEditor.visible and rawget(dual.periodEditor, "parent") == nil)
dual.periodInput:SetText("5"); widgets.TradePacksRatesPeriodApply.handlers.OnClick()
assert(dual.settings.recentHours == 5 and not dual.periodEditor.visible)
dual.settings.graphLayout = "combined"; dual:render()
local combined = dual.combinedGraph
dual.settings.graphPositions = {} -- colors must not require a separate graph position
combined.colorButton.handlers.OnClick(); chooseMenu(dual, routeA); chooseMenu(dual, "FF6688")
assert(dual.settings.seriesColors[routeA] == "FF6688" and not dual.settings.seriesColors[routeB])
for _, name in ipairs({A, B, C}) do seed(dual, name, {{-4, 110}, {-2, 120}, {-1, 125}}) end
dual:render()
local function checkColor(graph)
  local color = graph.chart.layers[1].line.color
  assert(color[1] == 1 and color[2] == 102 / 255 and color[3] == 136 / 255,
    "custom line color did not reach the renderer")
  local priceColor = graph.chart.priceChart.layers[1].line.color
  for i = 1, 3 do assert(color[i] == priceColor[i], "price overlay lost its pack color") end
end
checkColor(combined)
assert(equal(combined.legends[1].name.style.color, combined.chart.layers[1].line.color))
local colorMutations = lineMutations
dual:render(); assert(lineMutations == colorMutations, "unchanged colors invalidate line geometry")
combined.colorButton.handlers.OnClick(); chooseMenu(dual, routeB); chooseMenu(dual, "custom")
dual.periodInput:SetText("bad-color"); widgets.TradePacksRatesPeriodApply.handlers.OnClick()
assert(dual.periodEditor.visible and not dual.settings.seriesColors[routeB])
dual.periodInput:SetText("#abcdef"); widgets.TradePacksRatesPeriodApply.handlers.OnClick()
assert(dual.settings.seriesColors[routeB] == "ABCDEF" and not dual.periodEditor.visible)
dual = newWatch()
assert(dual.settings.seriesColors[routeA] == "FF6688" and dual.settings.seriesColors[routeB] == "ABCDEF",
  "combined-only colors were lost after restart")
assert(dual.settings.recentHours == 5, "floating period was not saved")
dual.settings.graphLayout = "separate"; dual:render()
floating = graphFor(dual, A)
checkColor(floating)
floating.colorButton.handlers.OnClick(); chooseMenu(dual, "default")
assert(not dual.settings.seriesColors[routeA] and dual.settings.seriesColors[routeB] == "ABCDEF")
floating.periodButton.handlers.OnClick(); floating.close.handlers.OnClick()
assert(not dual.menu.visible, "closing a floating window left its picker open")
assert(#queries == queryCount, "period/color changes made additional native requests")
assert(#errors == 0, table.concat(errors, "; "))
print("Rates mini-graph tests passed: independent windows/scales, dragging, restart, slot reuse, controls, periods, isolated failures and bounded work")
