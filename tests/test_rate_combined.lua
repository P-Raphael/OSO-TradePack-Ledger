-- Run from Addon: lua TradePacks/tests/test_rate_combined.lua
-- Covers the combined view's lifecycle, identities, and render instructions;
-- native drawing and mouse hit testing still require the game client.
local widgets, now, scale, writes = {}, 10000, 1, 0
local screenWidth, screenHeight = 1920, 1080
local Widget = {}
Widget.__index = function(_, key) return Widget[key] or function() end end
local function widget(kind, name, parent, x, y, width, height)
  local value = setmetatable({kind = kind, name = name, parent = parent, x = x, y = y,
    width = width, height = height, visible = true, handlers = {}}, Widget)
  value.style = setmetatable({}, Widget)
  widgets[#widgets + 1] = value
  return value
end
function Widget:SetText(text) self.text = text end
function Widget:SetHandler(event, fn) self.handlers[event] = fn end
function Widget:SetExtent(width, height) self.width, self.height = width, height end
function Widget:SetHeight(height) self.height = height end
function Widget:SetInset(...) self.inset = {...} end
function Widget:SetAlign(value) self.align = value end
function Widget:RemoveAllAnchors() self.anchors = {}; self.anchor = nil end
function Widget:EnablePick(value) self.pick = value end
function Widget:EnableDrag(value) self.drag = value end
function Widget:Show(value) self.visible = value end
function Widget:IsVisible() return self.visible end
function Widget:GetOffset() return self.x, self.y end
function Widget:GetWidth() return self.width end
function Widget:GetHeight() return self.height end
function Widget:AddAnchor(...)
  self.anchor = {...}
  self.anchors = self.anchors or {}
  self.anchors[#self.anchors + 1] = self.anchor
  if self.anchor[2] == "UIParent" then self.x, self.y = self.anchor[3], self.anchor[4] end
  if self.anchor[1] == "TOPRIGHT" and self.anchor[3] == "TOPRIGHT" and #self.anchors == 2 then
    self.x, self.y = self.anchors[1][4], self.anchors[1][5]
    self.width = self.anchor[2].width + self.anchor[4] - self.x
  end
  self.anchorCalls = (rawget(self, "anchorCalls") or 0) + 1
end
function Widget:SetColor(...) self.color = {...} end
function Widget:StartMoving() self.moving = true end
function Widget:StopMovingOrSizing() self.moving = false end
local function label(name, parent, x, y, width, height, text)
  local value = widget("label", name, parent, x, y, width, height)
  value:SetText(text)
  return value
end
local function button(name, parent, x, y, width, height, text, handler)
  local value = label(name, parent, x, y, width, height, text)
  value:EnablePick(true); value:SetHandler("OnClick", handler)
  return value
end
UIParent = {GetScreenWidth = function() return screenWidth end, GetScreenHeight = function() return screenHeight end}
DC_ALWAYS = 1
ALIGN_LEFT = "left"
local Watch = {}
Watch.__index = Watch
function Watch:saveSettings() writes = writes + 1 end
function Watch:visibility() self:syncCombinedGraph() end
function Watch:setGraphOnly(value) self.settings.graphOnly = value; self:visibility() end
function Watch:refreshStatus() return "Next update in 15s." end
function Watch:createLineChart(id, parent, x, y, width, height, transparent, onClick)
  assert(transparent and onClick == nil, "combined plot should remain click-through")
  return {plot = widget("plot", id, parent, x, y, width, height), width = width, height = height,
    layers = {}, transparent = transparent}
end
function Watch:chartBounds(low, high)
  self.inputLow, self.inputHigh = low, high
  if low == nil then return nil, nil end
  if self.settings.metric == "profit" then low, high = math.min(0, low), math.max(0, high) end
  local padding = math.max((high - low) * 0.1, 0.5)
  return low - padding, high + padding
end
function Watch:renderComparison(chart, low, high, layout)
  self.renderedComparison = {low = low, high = high, layout = layout, chart = chart}
  for i = 1, #self.comparisonData do chart.layers[i] = {color = {i / 6, 0.5, 0.75}} end
end
function Watch:renderValueAxis(chart, low, high) self.renderedAxis = {chart, low, high} end
function Watch:renderTicks(ticks, chart, layout) self.renderedTicks = {ticks, chart, layout} end
function Watch:renderEmptyState(chart, title, detail) chart.emptyTitleText, chart.emptyDetailText = title, detail end
local layout = {count = 60, units = 60, minute = true, firstAt = 6400}
function Watch:chartData() return {}, nil, 0, layout end
dofile("TradePacks/RateCombined.lua")
TradePacksRateCombined.install(Watch)
local settings = {open = false, graphOnly = false, graphLayout = "separate", metric = "rate", mode = "recent",
  recentHours = 1, hourlyDays = 7, offset = -3, graphX = 700, graphY = 800,
  graphPositions = {pack = {x = 40, y = 50}}, selectedPacks = {"A", "B"}}
local watch = setmetatable({settings = settings, comparisonData = {}, historyLoading = 0, ctx = {
  widget = widget, label = label, textButton = button, now = function() return now end,
  scale = function() return scale end,
  fit = function(text, count) return #text > count and text:sub(1, count - 3) .. "..." or text end,
  money = function(value) return string.format("%.2fg", value / 10000) end
}}, Watch)
watch:syncCombinedGraph()
assert(watch.combinedGraph == nil and #widgets == 0, "inactive combined view allocated widgets")
settings.open, settings.graphOnly = true, true
watch:syncCombinedGraph()
assert(watch.combinedGraph == nil, "separate graph mode allocated a combined window")
settings.graphLayout = "combined"
watch:syncCombinedGraph()
local graph = assert(watch.combinedGraph)
assert(graph.window:IsVisible() and graph.window.pick == false)
assert(graph.title.pick == true and graph.title.drag == true and graph.expand.pick and graph.close.pick)
for _, entry in ipairs(graph.legends) do assert(entry.name.pick == false and entry.detail.pick == false) end
assert(settings.combinedX == 180 and settings.combinedY == 120 and writes == 1)
local widgetCount = #widgets
watch:renderCombinedGraph()
assert(graph.chart.emptyTitleText == "Choose packs to compare")
assert(watch.renderedTicks[3] == layout, "empty combined chart lost the selected time axis")

-- The same pack on two routes remains two independent, identifiable series.
local function entry(id, name, route, value, at)
  return {id = id, name = name, from = 22, to = 8, routeLabel = route,
    columns = {{value = value}}, count = 1, layout = layout,
    quote = {ratio = value, at = at}, pricing = {base = 10000, skill = 0}, quotePrice = value * 100}
end
watch.comparisonData = {
  entry("22_8_A", "Halcyona Preserved Gilda Specialty", "Halcyona > Two Crowns", 130, now - 15),
  entry("22_5_A", "Halcyona Preserved Gilda Specialty", "Halcyona > Solzreed", 90, now - 180)
}
watch:renderCombinedGraph()
assert(watch.inputLow == 90 and watch.inputHigh == 130, "combined graph did not share both series' range")
assert(graph.lowValue == 86 and graph.highValue == 134)
assert(watch.renderedAxis[1] == graph.chart and watch.renderedAxis[2] == graph.lowValue)
assert(graph.legends[1].name.text:find("Halcyona Preserved Gilda Specialty", 1, true))
assert(graph.legends[1].detail.text:find("Two Crowns", 1, true))
assert(graph.legends[2].detail.text:find("Solzreed", 1, true))
assert(graph.legends[1].detail.text:find("130.0%", 1, true))
assert(graph.legends[2].detail.text:find("3m ago stale", 1, true))
assert(graph.legends[1].name.style.color[1] ~= graph.legends[2].name.style.color[1])
assert(graph.height == 366 and graph.status.anchor[4] == 344)
assert(graph.subtitle.text == "1h | UTC-3 | shared scale")
local anchorCalls, beforeWrites = graph.window.anchorCalls, writes
for _ = 1, 5 do watch:renderCombinedGraph(); watch:syncCombinedGraph(); watch:renderCombinedStatus() end
assert(#widgets == widgetCount and writes == beforeWrites and graph.window.anchorCalls == anchorCalls,
  "unchanged combined redraw allocated windows, wrote settings, or changed window anchors")
now = now + 80
watch:renderCombinedStatus()
assert(graph.legends[1].detail.text:find("1m ago stale", 1, true), "reading age stopped updating")

-- Independent position persists in scaled coordinates and does not overwrite
-- individual mini-graph positions or their legacy fallback.
scale = 1.5
graph.title.handlers.OnDragStart()
assert(graph.window.moving)
graph.window.x, graph.window.y = 240, 200
watch:syncCombinedGraph(true)
assert(graph.window.x == 240 and graph.window.y == 200, "refresh interrupted dragging")
local dragAnchors = graph.window.anchorCalls
graph.title.handlers.OnDragStop()
assert(not graph.window.moving and settings.combinedX == 360 and settings.combinedY == 300)
assert(graph.window.x == 240 and graph.window.y == 200, "combined graph jumped on scaled drag release")
assert(graph.window.anchorCalls == dragAnchors, "successful combined drop unnecessarily rebuilt its anchors")
assert(settings.graphX == 700 and settings.graphY == 800)
assert(settings.graphPositions.pack.x == 40 and settings.graphPositions.pack.y == 50)
settings.graphLayout = "separate"
watch:syncCombinedGraph()
assert(not graph.window:IsVisible())
settings.graphLayout = "combined"
watch:syncCombinedGraph(true)
assert(graph.window:IsVisible() and graph.window.x == 240 and graph.window.y == 200 and #widgets == widgetCount,
  "combined graph applied UI scaling twice when reopened")
scale = 1

-- Pack-specific failures are disclosed while valid series stay on the chart.
settings.metric = "price"
watch.comparisonData[2].pricing.base = nil
watch.comparisonData[2].columns[1].value = nil
watch:renderCombinedGraph()
assert(graph.legends[2].detail.text:find("missing payout price", 1, true))
assert(watch.inputLow == 130 and watch.inputHigh == 130 and graph.chart.emptyTitleText == nil)
settings.metric = "profit"
watch.comparisonData[1].quotePrice, watch.comparisonData[1].cost = 15000, 25000
watch.comparisonData[1].costs = {stalePrices = true}
watch.comparisonData[1].columns[1].value = -1
watch.comparisonData[2].pricing.base = 10000
watch:renderCombinedGraph()
assert(graph.lowValue < -1 and graph.highValue > 0, "negative profit omitted break-even range")
assert(graph.legends[1].name.text:find("cached costs", 1, true))
assert(graph.legends[1].detail.text:find("~-1.00g", 1, true))
assert(graph.legends[2].detail.text:find("costs incomplete", 1, true))
assert(graph.subtitle.text:find("current costs", 1, true))
settings.mode, settings.hourlyDays, settings.offset = "hourly", 3, 2
watch:renderCombinedGraph()
assert(graph.subtitle.text:find("3d time%-of%-day averages | UTC%+2"))

-- Six legends fit a bounded window and the same widgets are reused when the
-- selection shrinks. Long route/name/status combinations remain bounded.
settings.metric, settings.mode, settings.recentHours = "rate", "recent", 0.25
for i = 1, 6 do
  watch.comparisonData[i] = entry(tostring(i), string.rep("Long pack ", 10), string.rep("Long route ", 10), 100 + i, now)
end
watch:renderCombinedGraph()
assert(graph.height == 510 and #widgets == widgetCount)
assert(graph.subtitle.text:find("15m", 1, true))
for _, labels in ipairs(graph.legends) do
  assert(labels.name.visible and labels.detail.visible)
  local chars = math.floor((graph.width - 20) / (graph.font * 0.55))
  assert(#labels.name.text <= chars and #labels.detail.text <= chars, "legend exceeds its bounded text width")
end
watch.comparisonData = {watch.comparisonData[1]}
watch:renderCombinedGraph()
assert(graph.height == 330)
for i = 2, 6 do assert(not graph.legends[i].name.visible and not graph.legends[i].detail.visible) end

-- Reopening and returning to controls do not clear selected packs.
graph.close.handlers.OnClick()
assert(settings.open == false and not graph.window:IsVisible() and #settings.selectedPacks == 2)
settings.open = true
watch:syncCombinedGraph()
assert(graph.window:IsVisible() and #widgets == widgetCount)
graph.expand.handlers.OnClick()
assert(not settings.graphOnly and not graph.window:IsVisible() and #settings.selectedPacks == 2)
settings.graphOnly = true
settings.combinedX, settings.combinedY = 0 / 0, math.huge
watch:syncCombinedGraph(true)
assert(settings.combinedX == 180 and settings.combinedY == 120)
settings.combinedX, settings.combinedY = 99999, 99999
screenWidth, screenHeight = 800, 600
watch:syncCombinedGraph(true)
local function assertPosition(value, x, y, message)
  local actualX, actualY = value.window:GetOffset()
  assert(math.abs(actualX - x) < 0.000001 and math.abs(actualY - y) < 0.000001, message)
end
local function titleReachable(value)
  local x, y = value.window:GetOffset()
  local visibleTitle = math.min(screenWidth / scale, x + 28 + value.title.width) - math.max(0, x + 28)
  assert(visibleTitle >= 32 and y >= 0 and y + 18 <= screenHeight / scale,
    "offscreen combined graph did not recover an accessible title")
end
titleReachable(graph)
screenWidth, screenHeight = 1920, 1080

-- Repeated drags preserve the native release position at both larger and smaller
-- UI scales, including placement with transparent margins beyond a screen edge.
for _, factor in ipairs({0.8, 1.5}) do
  scale = factor
  for _, point in ipairs({{240, 200}, {317, 263}, {-100, 40},
    {screenWidth / factor - 100, screenHeight / factor - 35}}) do
    local x, y = point[1], point[2]
    graph.title.handlers.OnDragStart()
    graph.window.x, graph.window.y = x, y
    local anchors = graph.window.anchorCalls
    graph.title.handlers.OnDragStop()
    assertPosition(graph, x, y, "combined graph jumped when dropped")
    assert(graph.window.anchorCalls == anchors, "combined drop rebuilt its anchors")
    assert(math.abs(settings.combinedX - x * factor) < 0.000001
      and math.abs(settings.combinedY - y * factor) < 0.000001, "combined saved coordinates ignored scaling")
    watch:renderCombinedGraph(); watch:syncCombinedGraph()
    assertPosition(graph, x, y, "combined graph moved on refresh")
    settings.open = false; watch:syncCombinedGraph()
    settings.open = true; watch:syncCombinedGraph(true)
    assertPosition(graph, x, y, "combined graph moved when reopened")
    local resumed = setmetatable({settings = settings, comparisonData = watch.comparisonData,
      historyLoading = 0, ctx = watch.ctx}, Watch)
    resumed:syncCombinedGraph(); resumed:renderCombinedGraph()
    assertPosition(resumed.combinedGraph, x, y, "combined graph moved after rebuilding from saved coordinates")
    titleReachable(resumed.combinedGraph)
  end
end
scale = 1

-- Growing/shrinking the legend must leave a user's near-edge top-left fixed.
graph.title.handlers.OnDragStart()
graph.window.x, graph.window.y = 1710, 1030
graph.title.handlers.OnDragStop()
local heightAnchors = graph.window.anchorCalls
for i = 1, 6 do watch.comparisonData[i] = entry(tostring(i), "Pack " .. i, "Route " .. i, 100 + i, now) end
watch:renderCombinedGraph()
assert(graph.height == 510)
assertPosition(graph, 1710, 1030, "additional legends pulled the combined graph inward")
watch.comparisonData = {watch.comparisonData[1]}; watch:renderCombinedGraph()
assertPosition(graph, 1710, 1030, "fewer legends shifted the combined graph")
assert(graph.window.anchorCalls == heightAnchors, "combined legend resizing reanchored the window")
-- Model the game's wide, spaced lettering: character-count fitting used to
-- let the selected pack rows run beyond the shaded background.
local measurements = 0
local originalSetText = Widget.SetText
function Widget:SetAutoResize(value) self.autoResize = value end
function Widget:SetEllipsis(value) self.ellipsis = value end
function Widget:SetText(text)
  originalSetText(self, text)
  if self.kind == "label" and rawget(self, "autoResize") ~= false then self.width = #text * 15 end
end
function Widget:SetFontSize(value) self.fontSize = value end
function Widget:GetTextWidth(text)
  measurements = measurements + 1
  local width, font = 0, rawget(self, "fontSize") or 12
  for i = 1, #text do
    local ch = text:sub(i, i)
    width = width + font * ((ch == "W" or ch == "M") and 1.1 or ch == "i" and 0.25 or 0.65) + 1.5
  end
  return width
end
watch.comparisonData = {entry("wide", "WWW Windscour Wide Specialty", "Windscour > Two Crowns", 121, now - 6)}
for _, font in ipairs({10, 12, 14}) do
  for _, width in ipairs({320, 360, 560, 1000}) do
    for _, compact in ipairs({true, false}) do
      settings.combinedStyle = {width = width, font = font, compact = compact, plotHeight = 100}
      watch:renderCombinedGraph()
      for _, labels in ipairs(graph.legends) do
        for _, label in ipairs({labels.name, labels.detail}) do
          if label.visible then
            assert(label.autoResize == false and label.style.ellipsis == true and label.width == width - 20,
              "native label can grow or paint outside the background after SetText")
            assert(label.style.align == "left" and label.inset[1] == 0 and label.inset[3] == 0,
              "legend inherited centered alignment or a text inset")
            assert(label.x == 10 and label.x + label.width == width - 10,
              "legend edges are not bound to the background with equal margins")
            assert(#label.anchors == 2 and label.anchors[1][2] == graph.window and label.anchors[2][2] == graph.window,
              "legend bounds use a different coordinate parent from the background")
            assert(label.style:GetTextWidth(label.text) <= width - 26,
              "measured legend text extends outside the padded background")
          end
        end
      end
      assert((compact and graph.legends[1].name.text or graph.legends[1].detail.text):find("121.0%%"),
        "fitting the name unnecessarily removed the current value")
      local before = measurements
      watch:renderCombinedStatus()
      assert(measurements == before, "unchanged legend text was remeasured")
    end
  end
end
-- Price gets its own bounded row even in compact mode, without widening the
-- window. At small sizes truncate the age after the price, not the price itself.
settings.showRatePrice = true
watch.comparisonData[1].quotePrice = 704785
watch.comparisonData[1].pricing = {base = 1, skill = 1}
watch.comparisonData[2] = watch.comparisonData[1]
for _, font in ipairs({10, 12, 14}) do
  for _, compact in ipairs({true, false}) do
    settings.combinedStyle = {width = 320, font = font, compact = compact, plotHeight = 100}
    watch:renderCombinedGraph()
    for _, labels in ipairs({graph.legends[1], graph.legends[2]}) do
      assert(labels.name.text:find("121.0%%") and not labels.name.text:find("~"))
      assert(labels.detail.visible and labels.detail.text:find("Price: ~", 1, true))
      assert(labels.detail.text:find(watch.ctx.money(704785), 1, true), "price truncated on its dedicated row")
      assert(labels.detail.y == labels.name.y + 17 and labels.detail.y + 18 < graph.height - 22)
      assert(labels.detail.style:GetTextWidth(labels.detail.text) <= 294)
      assert(labels.detail.x == 10 and labels.detail.width == 300)
    end
    assert(graph.legends[2].name.y >= graph.legends[1].detail.y + 18, "price rows overlap next pack")
    assert(graph.width == 320, "two-line labels widened the graph")
  end
end
print("PASS: combined transparent graph lifecycle, bounded stacked prices, per-route legends, shared bounds, missing data, and saved position")
