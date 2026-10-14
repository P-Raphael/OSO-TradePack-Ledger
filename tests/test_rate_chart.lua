-- Run from Addon: lua TradePacks/tests/test_rate_chart.lua
-- Validate scale planning and native drawing instructions, not client rendering.
local calls, widgets = 0, {}
local function count() calls = calls + 1 end
local Widget = {}
Widget.__index = Widget
function Widget:EnablePick(pick) count(); self.pick = pick end
function Widget:SetLineThickness(thickness) count(); self.thickness = thickness end
function Widget:SetLineColor(...) count(); self.color = {...} end
function Widget:SetExtent(width, height) count(); self.width, self.height = width, height end
function Widget:ClearPoints() count(); self.points = {} end
function Widget:SetPoints(points) count(); self.points = points end
function Widget:RemoveAllAnchors() count(); self.anchor = nil end
function Widget:AddAnchor(...) count(); self.anchor = {...} end
function Widget:SetText(text) count(); self.text = text end
function Widget:Show(visible) count(); self.visible = visible end
local function widget(kind, id, parent, x, y, width, height)
  assert(not widgets[id], "duplicate widget identity: " .. id)
  count()
  local w = setmetatable({kind = kind, id = id, parent = parent, x = x, y = y,
    width = width, height = height}, Widget)
  w.style = {
    SetFontSize = function(_, size) count(); w.fontSize = size end,
    SetAlign = function(_, align) count(); w.align = align end,
    SetColor = function(_, ...) count(); w.textColor = {...} end,
    SetOutline = function(_, outline) count(); w.outline = outline end
  }
  widgets[id] = w
  return w
end
local function label(id, parent, x, y, width, height, text)
  local w = widget("label", id, parent, x, y, width, height)
  w:SetText(text)
  return w
end
ALIGN_RIGHT = "right"
dofile("TradePacks/RateChart.lua")
local Watch = {}
TradePacksRateChart.install(Watch)
local watch = setmetatable({settings = {metric = "rate"}, ctx = {widget = widget, label = label}}, {__index = Watch})
local function chart(id, transparent, height)
  return {id = id, plot = {}, width = 360, height = height or 120, transparent = transparent}
end
local function draw(target, low, high)
  local lower, upper = watch:chartBounds(low, high)
  watch:renderValueAxis(target, lower, upper)
  return lower, upper
end
local function visibleTicks(target)
  local out = {}
  for _, tick in ipairs(target.valueAxis or {}) do if tick.visible then out[#out + 1] = tick end end
  return out
end
local function checkAxis(target, low, high)
  local ticks = visibleTicks(target)
  assert(#ticks <= 7, "a compact plot has too many labels")
  local previousY
  for _, tick in ipairs(ticks) do
    assert(tick.value >= low and tick.value <= high, "tick escaped axis bounds")
    assert(tick.line.pick == false and tick.label.pick == false, "axis steals input from the window")
    assert(tick.label.align == "right" and tick.label.fontSize == 11, "axis labels do not fit their gutter")
    assert(tick.line.thickness == 1 and tick.line.color[4] < 0.3, "grid obscures observation lines")
    assert(#tick.line.points == 1, "grid should contain one horizontal segment")
    local p = tick.line.points[1]
    assert(p.beginX == 0 and p.endX == target.width and p.beginY == p.endY, "invalid grid segment")
    assert(p.beginY >= 0 and p.beginY <= target.height, "grid escaped the plot")
    assert(tick.label.anchor[3] == -58 and tick.label.anchor[4] == target.height - p.beginY - 9,
      "labels are not aligned with native bottom-up line coordinates")
    if previousY then assert(p.beginY - previousY >= 19, "labels overlap vertically") end
    previousY = p.beginY
  end
  return ticks
end

local full = chart("Full", false, 126)
local low, high = draw(full, 125.5, 128.5)
assert(low == 90 and high == 130, "rate scale should include familiar brackets even for flat routes")
local ticks = checkAxis(full, low, high)
assert(#ticks == 5, "default rate axis needs five bracket labels")
for i, value in ipairs({90, 100, 110, 120, 130}) do
  assert(ticks[i].value == value and ticks[i].label.text == value .. "%", "missing payout bracket")
end
local before = calls
for i = 1, 10 do draw(full, 125.5, 128.5) end
assert(calls == before, "unchanged axis repeats native mutations")

low, high = draw(full, 78.1, 139.9)
assert(low == 60 and high == 140, "broader rates should extend the axis")
-- The rounded 10-point scale would need eight labels; coarsen to 20 points.
assert(#visibleTicks(full) <= 7, "extended axis exceeds the tick budget")
checkAxis(full, low, high)

low, high = draw(full, 1, 500)
assert(low <= 1 and high >= 500, "unusual rates clipped observations")
checkAxis(full, low, high)
local allocated = #full.valueAxis
draw(full, 126, 126)
assert(#visibleTicks(full) == 5 and #full.valueAxis == allocated, "axis recreated its widget pool")

local mini = chart("Mini", true)
low, high = draw(mini, 127, 128)
for _, tick in ipairs(checkAxis(mini, low, high)) do
  assert(tick.label.outline == true and tick.label.textColor[1] == 1, "transparent axis text lacks contrast")
  assert(tick.line.color[4] == 0.24, "transparent chart grid should remain translucent")
end
assert(mini.valueAxis[1].line ~= full.valueAxis[1].line, "independent charts share native widgets")
local unaffected = full.valueAxis[1].line.points
mini.height, mini.width = 150, 400
draw(mini, 127, 128)
assert(full.valueAxis[1].line.points == unaffected, "resizing one axis rebuilt another")
checkAxis(mini, 90, 130)

watch.settings.metric = "price"
low, high = draw(full, 81.2, 84.4)
assert(low >= 0 and low <= 81.2 and high >= 84.4 and high - low < 10, "price axis should be adaptive")
for _, tick in ipairs(checkAxis(full, low, high)) do assert(tick.label.text:sub(-1) == "g", "price units missing") end
low, high = draw(full, 0, 0)
assert(low == 0 and high > 0, "a zero price needs a usable scale")
checkAxis(full, low, high)
low, high = draw(full, 0.003, 0.008)
checkAxis(full, low, high)
local texts = {}
for _, tick in ipairs(visibleTicks(full)) do
  assert(not texts[tick.text], "small price axis labels round to duplicates")
  texts[tick.text] = true
end

watch.settings.metric = "profit"
for _, range in ipairs({{-10, -5}, {80, 81}, {-2, 3}, {0, 0}}) do
  low, high = draw(full, range[1], range[2])
  assert(low < 0 and high > 0 and low <= range[1] and high >= range[2], "profit must include break-even")
  local zero = false
  for _, tick in ipairs(checkAxis(full, low, high)) do if tick.value == 0 then zero = true end end
  assert(zero, "profit axis should label zero")
end

for _, range in ipairs({{nil, nil}, {0, math.huge}, {0 / 0, 1}, {0, -math.huge}}) do
  low, high = draw(full, range[1], range[2])
  assert(low == nil and high == nil and #visibleTicks(full) == 0, "missing data leaves a misleading old axis")
end
before = calls
draw(full, nil, nil)
assert(calls == before, "an already hidden axis repeats native calls")
local empty = chart("Empty", true)
before = calls
draw(empty, nil, nil)
assert(calls == before and #empty.valueAxis == 0, "missing data unnecessarily creates axis widgets")
watch.settings.metric = "rate"
draw(full, 126, 128)
assert(#visibleTicks(full) == 5, "hidden axis did not recover when observations resumed")

-- Wide spans never create an unbounded widget collection.
for i = 1, 120 do
  low, high = draw(full, math.max(0, 120 - i * 2), 130 + i * 50)
  checkAxis(full, low, high)
  assert(#full.valueAxis <= 7, "axis widget pool grew past its cap")
end
local adaptive = chart("Adaptive", true, 240)
low, high = draw(adaptive, 125, 128)
local detailed = visibleTicks(adaptive)
assert(#detailed == 9 and detailed[6].value == 115 and detailed[8].value == 125,
  "tall rate graph lacks five-percent marks")
local pool = #adaptive.valueAxis
adaptive.height = 120
draw(adaptive, 125, 128)
assert(#visibleTicks(adaptive) == 5 and #adaptive.valueAxis == pool,
  "short graph did not hide/reuse intermediate marks")
adaptive.height = 80
draw(adaptive, 125, 128)
assert(#visibleTicks(adaptive) <= 4)
adaptive.height = 240
draw(adaptive, 125, 128)
assert(#visibleTicks(adaptive) == 9 and #adaptive.valueAxis == pool)
before = calls
draw(adaptive, 125, 128)
assert(calls == before, "unchanged detailed axis rebuilds native widgets")
watch.ctx.dark = true
local darkAxis = chart("DarkFull", false, 240)
draw(darkAxis, 122, 126)
for _, tick in ipairs(visibleTicks(darkAxis)) do
  assert(tick.label.textColor[1] == 1 and tick.label.textColor[2] == 1 and tick.label.textColor[3] == 1)
  assert(tick.line.color[1] > 0.8, "dark full-panel grid uses light-theme dark lines")
end
print("PASS: RateChart adaptive marks, dark-theme contrast, bounds, reuse, and geometry cache")
