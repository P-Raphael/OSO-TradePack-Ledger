-- Shared value axes for the comparison chart and transparent pack graphs.
-- Grid lines describe the scale only; observation gaps stay in RateWatch.
TradePacksRateChart = {}

local MAX_TICKS = 7
local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function niceStep(minimum)
  if not finite(minimum) or minimum <= 0 then return 1 end
  local power = 10 ^ math.floor(math.log(minimum) / math.log(10))
  local fraction = minimum / power
  if fraction <= 1 then return power end
  if fraction <= 2 then return 2 * power end
  if fraction <= 5 then return 5 * power end
  return 10 * power
end

local function roundedBounds(low, high, step)
  -- A small tolerance avoids an extra bracket caused by decimal round-off.
  return math.floor(low / step + 1e-9) * step, math.ceil(high / step - 1e-9) * step
end

local function tickLabel(value, step, metric)
  if math.abs(value) < step * 1e-8 then value = 0 end
  if metric == "rate" then return string.format("%.0f%%", value) end
  local divisor, suffix = 1, "g"
  if math.abs(value) >= 1000000 then divisor, suffix = 1000000, "Mg"
  elseif math.abs(value) >= 10000 then divisor, suffix = 1000, "kg" end
  local decimals = math.max(0, math.min(4, -math.floor(math.log(step / divisor) / math.log(10) + 1e-9)))
  return string.format("%." .. decimals .. "f", value / divisor) .. suffix
end

function TradePacksRateChart.install(Watch)
  function Watch:chartBounds(low, high, metricOverride)
    if not finite(low) or not finite(high) then return nil, nil end
    if high < low then low, high = high, low end
    local metric = metricOverride or self.settings.metric
    if metric == "both" then metric = "rate" end
    if metric == "rate" then
      low, high = math.min(90, low), math.max(130, high)
    else
      if metric == "profit" then low, high = math.min(0, low), math.max(0, high) end
      local padding = math.max((high - low) * 0.1, 0.1)
      low, high = low - padding, high + padding
      if metric ~= "profit" then low = math.max(0, low) end
    end
    local step = niceStep(math.max(metric == "rate" and 10 or 0, (high - low) / (MAX_TICKS - 1)))
    local lower, upper = roundedBounds(low, high, step)
    while (upper - lower) / step > MAX_TICKS - 1 + 1e-8 do
      step = niceStep(step * 1.01)
      lower, upper = roundedBounds(low, high, step)
    end
    return lower, upper
  end

  function Watch:renderValueAxis(chart, low, high, metricOverride)
    local metric = metricOverride or self.settings.metric
    if metric == "both" then metric = "rate" end
    local visible = finite(low) and finite(high) and high > low
    local signature = table.concat({metric, tostring(low), tostring(high), tostring(chart.width),
      tostring(chart.height), tostring(chart.transparent), tostring(self.ctx.dark), tostring(chart.axisFont)}, "|")
    if chart.axisSignature == signature then return end
    local ticks = chart.valueAxis or {}
    chart.valueAxis = ticks
    local values, step = {}, nil
    if visible then
      local cap = metric == "rate" and 13 or MAX_TICKS
      local spacing = metric == "rate" and math.max(22, (chart.axisFont or 11) + 8) or 20
      local maxTicks = math.max(2, math.min(cap, math.floor(chart.height / spacing) + 1))
      step = niceStep(math.max(metric == "rate" and 5 or 0, (high - low) / (maxTicks - 1)))
      local first = math.ceil(low / step - 1e-9) * step
      for i = 0, cap - 1 do
        local value = first + i * step
        if value > high + step * 1e-8 then break end
        values[#values + 1] = value
      end
    end
    for i = 1, math.max(#values, #ticks) do
      local tick, value = ticks[i], values[i]
      if value ~= nil then
        if not tick then
          local id = chart.id .. "ValueTick" .. i
          local line = self.ctx.widget("line", id .. "Grid", chart.plot, 0, 0, chart.width, chart.height)
          line:EnablePick(false)
          line:SetLineThickness(1)
          -- Native line widgets are translucent and have no filled background.
          local light = chart.transparent or self.ctx.dark
          line:SetLineColor(light and 0.85 or 0.35, light and 0.85 or 0.25, light and 0.85 or 0.1,
            chart.transparent and 0.24 or 0.2)
          local label = self.ctx.label(id .. "Label", chart.plot, -58, 0, 52, 18, "")
          label:EnablePick(false)
          pcall(function() label:SetAutoResize(false); label.style:SetEllipsis(true) end)
          pcall(function()
            label.style:SetFontSize(11)
            if ALIGN_RIGHT or RIGHT then label.style:SetAlign(ALIGN_RIGHT or RIGHT) end
            if chart.transparent then label.style:SetColor(1, 1, 1, 1); label.style:SetOutline(true) end
          end)
          tick = {line = line, label = label}
          ticks[i] = tick
        end
        local y = chart.height * (value - low) / (high - low)
        local geometry = table.concat({tostring(chart.width), tostring(chart.height), tostring(y)}, ":")
        if tick.geometry ~= geometry then
          tick.line:SetExtent(chart.width, chart.height)
          tick.line:ClearPoints()
          tick.line:SetPoints({{beginX = 0, beginY = y, endX = chart.width, endY = y}})
          tick.label:RemoveAllAnchors()
          tick.label:AddAnchor("TOPLEFT", chart.plot, chart.rightAxis and chart.width + 6 or -58, chart.height - y - 9)
          tick.geometry = geometry
        end
        local text = tickLabel(value, step, metric)
        if tick.text ~= text then tick.label:SetText(text); tick.label:SetExtent(52, 18); tick.text = text end
        if tick.visible ~= true then tick.line:Show(not chart.rightAxis); tick.label:Show(true); tick.visible = true end
        tick.value = value
      elseif tick and tick.visible ~= false then
        tick.line:Show(false); tick.label:Show(false); tick.visible = false
      end
    end
    chart.axisSignature = signature
  end
end
