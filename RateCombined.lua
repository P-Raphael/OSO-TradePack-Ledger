-- A transparent comparison view using the same observations and query driver
-- as the full Rates window. Only its header controls capture mouse input.
TradePacksRateCombined = {}

local WIDTH, PLOT_WIDTH, PLOT_HEIGHT = 560, 480, 170
local LEGEND_Y, LEGEND_STEP, MAX_SERIES = 256, 36, 6
local function number(value)
  local n = tonumber(value)
  if n and n == n and n ~= math.huge and n ~= -math.huge then return n end
end

local function periodText(settings)
  if settings.mode == "hourly" then return tostring(settings.hourlyDays) .. "d time-of-day averages" end
  local hours = number(settings.recentHours) or 24
  if hours < 1 then return string.format("%dm", hours * 60) end
  if hours > 48 and hours % 24 == 0 then return string.format("%dd", hours / 24) end
  return string.format("%gh", hours)
end

local function ageText(at, now, staleAfter)
  if not number(at) then return "no reading" end
  local age = math.max(0, now - at)
  return (age < 60 and (math.floor(age) .. "s") or (math.floor(age / 60) .. "m"))
    .. " ago" .. (age > staleAfter and " stale" or "")
end

local function quoteText(data, metric, money)
  local pricing = data.pricing or {}
  if metric ~= "rate" and not pricing.base then return "missing payout price" end
  if metric ~= "rate" and not pricing.skill then return "waiting for Commerce" end
  if metric == "profit" and data.cost == nil then return "costs incomplete" end
  if metric == "profit" and data.quotePrice ~= nil then
    return "~" .. money(data.quotePrice - data.cost)
  end
  if metric == "price" and data.quotePrice ~= nil then return "~" .. money(data.quotePrice) end
  if metric == "rate" and data.quote and number(data.quote.ratio) then
    return string.format("%.1f%%", data.quote.ratio)
  end
  return "waiting for a reading"
end

function TradePacksRateCombined.install(Watch)
  function Watch:graphPeriodLabel()
    if self.settings.mode == "hourly" then return tostring(self.settings.hourlyDays) .. "d" end
    return periodText(self.settings)
  end

  function Watch:anchorGraphLegend(label, parent, y)
    self.graphLegendBounds = self.graphLegendBounds or {}
    self.graphLegendBounds[label] = {parent = parent, y = y}
    pcall(function() label:SetAutoResize(false) end)
    pcall(function() label:SetInset(0, 0, 0, 0) end)
    pcall(function() label.style:SetAlign(ALIGN_LEFT or LEFT) end)
    pcall(function() label.style:SetEllipsis(true) end)
    label:RemoveAllAnchors()
    label:AddAnchor("TOPLEFT", parent, "TOPLEFT", 10, y)
    label:AddAnchor("TOPRIGHT", parent, "TOPRIGHT", -10, y)
    label:SetHeight(18)
  end

  function Watch:setGraphLabel(label, text, width, font, tail)
    -- Native labels can auto-grow after SetText; measuring the string alone
    -- cannot constrain that widget. Enforce its bounds and native ellipsis too.
    pcall(function() label:SetAutoResize(false) end)
    pcall(function() label.style:SetEllipsis(true) end)
    label:SetText(self:fitGraphLabel(label, text, width, font, tail))
    local footer = self.graphFooterBounds and self.graphFooterBounds[label]
    local bounds = self.graphLegendBounds and self.graphLegendBounds[label]
    if footer then self:anchorGraphStatus(footer.graph, footer.left)
    elseif bounds then
      -- Keep text left-aligned and bind both edges to the window, rather than
      -- leaving a centered label's extent independent of its background.
      self:anchorGraphLegend(label, bounds.parent, bounds.y)
    else label:SetExtent(width, 18) end
  end

  function Watch:anchorGraphStatus(graph, left)
    local label = graph.status
    self.graphFooterBounds = self.graphFooterBounds or {}
    self.graphFooterBounds[label] = {graph = graph, left = left}
    pcall(function() label:SetAutoResize(false); label:SetInset(0, 0, 0, 0) end)
    pcall(function() label.style:SetAlign(ALIGN_RIGHT or RIGHT); label.style:SetEllipsis(true) end)
    label:RemoveAllAnchors()
    label:AddAnchor("TOPLEFT", graph.window, "TOPLEFT", left, graph.height - 22)
    label:AddAnchor("TOPRIGHT", graph.resizeGrip, "TOPLEFT", -26, -2)
    label:SetHeight(18)
  end

  function Watch:ratePriceText(data)
    local rate = data and data.quote and number(data.quote.ratio)
    local price = data and number(data.quotePrice)
    local text = rate and string.format("%.1f%%", rate) or "rate unavailable"
    if price then return text .. " | ~" .. self.ctx.money(price) end
    return text .. " | " .. (data and data.pricing and not data.pricing.base and "no payout price" or "price unavailable")
  end

  function Watch:displayPackName(data)
    return (data and self.settings.packAliases and self.settings.packAliases[data.id])
      or (data and data.name) or "Choose a pack"
  end

  function Watch:fitGraphLabel(label, text, width, font, tail)
    tail = tail or ""
    width = math.max(0, width - 6) -- inset for outlined glyphs at both edges
    self.graphTextFits = self.graphTextFits or {}
    local key = table.concat({text, tail, width, font}, "\n")
    local cached = self.graphTextFits[label]
    if cached and cached.key == key then return cached.text end
    pcall(function() label.style:SetFontSize(font) end)
    local function measure(value)
      local ok, pixels = pcall(function() return label.style:GetTextWidth(value) end)
      if ok and number(pixels) and (pixels > 0 or value == "") then return pixels end
      return #value * font * 0.75
    end
    local function prefix(bytes)
      -- Do not cut a UTF-8 name in the middle of a character.
      while bytes > 0 and text:byte(bytes + 1) and text:byte(bytes + 1) >= 128
        and text:byte(bytes + 1) < 192 do bytes = bytes - 1 end
      return text:sub(1, bytes)
    end
    local result = text .. tail
    if measure(result) > width then
      if measure("..." .. tail) > width then text, tail = result, "" end
      local low, high, best = 0, #text, ""
      while low <= high do
        local middle = math.floor((low + high) / 2)
        local candidate = prefix(middle) .. "..." .. tail
        if measure(candidate) <= width then best, low = candidate, middle + 1
        else high = middle - 1 end
      end
      result = best
    end
    self.graphTextFits[label] = {key = key, text = result}
    return result
  end

  function Watch:graphStyle(graph)
    local s = self.settings
    local value = graph.combined and s.combinedStyle
      or (type(s.graphStyles) == "table" and s.graphStyles[graph.id])
    if graph.resizing and graph.resizeId == graph.id then value = graph.resizeStyle end
    value = type(value) == "table" and value or {}
    return {width = math.max(320, math.min(1200, number(value.width) or (graph.combined and 560 or 440))),
      plotHeight = math.max(80, math.min(500, number(value.plotHeight) or (graph.combined and 170 or 120))),
      compact = value.compact == true, hideNames = value.hideNames == true,
      font = (value.font == 10 or value.font == 14) and value.font or 12}
  end

  function Watch:saveGraphStyle(graph, style)
    if graph.combined then self.settings.combinedStyle = style
    elseif graph.id then
      self.settings.graphStyles = self.settings.graphStyles or {}
      self.settings.graphStyles[graph.id] = style
    end
    self:saveSettings()
  end

  function Watch:layoutFloatingGraph(graph)
    local style = self:graphStyle(graph)
    local width, plotHeight, compact = style.width, style.plotHeight, style.compact
    local count = math.max(1, math.min(6, #(self.comparisonData or {})))
    local bothValues = self.settings.showRatePrice or self.settings.metric == "both"
    local stacked = bothValues or self.settings.metric == "price" or self.settings.metric == "profit"
    local legendStep = compact and not stacked and 20 or 36
    local rateCount = 0
    if graph.combined and self.settings.metric == "rate" then
      for _, data in ipairs(self.comparisonData or {}) do
        if data.quote and number(data.quote.ratio) then rateCount = rateCount + 1 end
      end
    end
    if rateCount > 0 then plotHeight = math.max(plotHeight, (rateCount - 1) * (style.font + 6) + 18) end
    local plotY = style.hideNames and 28 or compact and (not graph.combined and bothValues and 50 or 28)
      or graph.combined and 55 or 72
    local legendY = plotY + plotHeight + 31
    local height = graph.combined and (legendY + (style.hideNames and 0 or count * legendStep)
      + ((compact or style.hideNames) and 28 or 38))
      or plotY + plotHeight + ((compact or style.hideNames) and 48 or 72)
    local dual = self.settings.metric == "both"
    local rateGutter = rateCount > 0 and 54 or 0
    local signature = table.concat({width, plotHeight, height, tostring(compact), style.font,
      tostring(dual), rateGutter, tostring(style.hideNames)}, ":")
    graph.compact, graph.font, graph.stacked = compact, style.font, stacked
    graph.hideNames = style.hideNames
    graph.chart.axisFont = style.font
    graph.plotY, graph.currentRateGutter = plotY, rateGutter
    if graph.periodButton then
      self:setGraphLabel(graph.periodButton, self:graphPeriodLabel(), 50, 12)
    end
    if graph.layoutSignature == signature then return end
    graph.layoutSignature, graph.width, graph.height = signature, width, height
    graph.window:SetExtent(width, height)
    local function place(widget, x, y, w, h)
      if not widget then return end
      widget:RemoveAllAnchors(); widget:AddAnchor("TOPLEFT", graph.window, x, y)
      widget:SetExtent(w, h or 18)
    end
    place(graph.title, 28, 0, width - 230)
    place(graph.periodButton, width - 198, 0, 50)
    place(graph.textButton, width - 144, 0, 38)
    place(graph.fontButton, width - 104, 0, 30)
    place(graph.backgroundButton, width - 72, 0, 30)
    place(graph.close, width - 34, 0, 24)
    place(graph.resizeGrip, width - 22, height - 20, 22, 20)
    graph.resizeGrip:RemoveAllAnchors()
    graph.resizeGrip:AddAnchor("TOPLEFT", graph.window, "TOPLEFT", width - 22, height - 20)
    place(graph.colorButton, 10, height - 22, 48)
    if graph.combined then
      local proficiencyWidth = math.min(150, math.max(112, math.floor((width - 94) * 0.4)))
      graph.proficiencyWidth = proficiencyWidth
      graph.statusWidth = width - 120 - proficiencyWidth
      place(graph.proficiencyLabel, 64, height - 22, proficiencyWidth)
      place(graph.status, 72 + proficiencyWidth, height - 22, graph.statusWidth)
      self:anchorGraphStatus(graph, 72 + proficiencyWidth)
    else
      graph.statusWidth = width - 112
      place(graph.status, 64, height - 22, graph.statusWidth)
      self:anchorGraphStatus(graph, 64)
    end
    -- Keep 26 units clear before the resize handle, including outlined glyphs.
    pcall(function() graph.status:EnablePick(false); graph.resizeGrip:Raise() end)
    place(graph.subtitle, 12, 25, width - 24)
    if graph.subtitle then graph.subtitle:Show(not compact and not style.hideNames) end
    place(graph.routeLabel, 10, 22, width - 20)
    place(graph.quoteLabel, 10, 44, width - 20)
    place(graph.coverage, 10, height - 47, width - 20)
    for _, key in ipairs({"routeLabel", "quoteLabel", "coverage"}) do
      if graph[key] then graph[key]:Show(not compact and not style.hideNames) end
    end
    if not graph.combined and bothValues and not style.hideNames then
      place(graph.quoteLabel, 10, compact and 22 or 44, width - 20)
      graph.quoteLabel:Show(true)
    end
    for i, tick in ipairs(graph.ticks) do place(tick, 45, plotY + plotHeight + (graph.combined and 4 or 2), 58) end
    for i, labels in ipairs(graph.legends or {}) do
      self:anchorGraphLegend(labels.name, graph.window, legendY + (i - 1) * legendStep)
      self:anchorGraphLegend(labels.detail, graph.window, legendY + (i - 1) * legendStep + 17)
    end
    local chart = graph.chart
    local chartWidth = width - (dual and 132 or 80) - rateGutter
    place(chart.plot, 60, plotY, chartWidth, plotHeight)
    chart.width, chart.height = chartWidth, plotHeight
    for _, layer in ipairs(chart.layers) do
      if layer.line then layer.line:SetExtent(chart.width, chart.height) end
      layer.renderSignature = nil
    end
    if chart.zeroLine then chart.zeroLine:SetExtent(chart.width, chart.height) end
    chart.axisSignature = nil
    for i, key in ipairs({"emptyTitle", "emptyDetail", "emptyHint"}) do
      local label = chart[key]
      if label then
        label:RemoveAllAnchors(); label:AddAnchor("TOPLEFT", chart.plot, 8, plotHeight / 2 - 26 + (i - 1) * 24)
        label:SetExtent(chart.width - 16, 20)
      end
    end
  end

  function Watch:styleFloatingText(graph)
    local font = graph.font or 12
    local labels = {graph.title, graph.status}
    for _, key in ipairs({"subtitle", "routeLabel", "quoteLabel", "coverage", "proficiencyLabel"}) do
      if graph[key] then labels[#labels + 1] = graph[key] end
    end
    for _, tick in ipairs(graph.ticks) do labels[#labels + 1] = tick end
    for _, tick in ipairs(graph.chart.valueAxis or {}) do labels[#labels + 1] = tick.label end
    for _, tick in ipairs(graph.chart.priceChart and graph.chart.priceChart.valueAxis or {}) do labels[#labels + 1] = tick.label end
    for _, entry in ipairs(graph.legends or {}) do labels[#labels + 1] = entry.name; labels[#labels + 1] = entry.detail end
    for _, label in ipairs(graph.currentRates or {}) do labels[#labels + 1] = label end
    for _, label in ipairs(labels) do
      if graph.appliedFonts == nil then graph.appliedFonts = {} end
      if graph.appliedFonts[label] ~= font then
        pcall(function() label.style:SetFontSize(font) end)
        graph.appliedFonts[label] = font
      end
    end
  end

  function Watch:addGraphControls(graph, prefix)
    local c, w = self.ctx, graph.window
    local function button(id, text, action)
      local b = c.textButton(prefix .. id, w, 0, 0, 30, 18, text, action)
      pcall(function() b.style:SetColor(1, 1, 1, 1) end)
      return b
    end
    graph.periodButton = button("Period", "24h", function() self:showPeriodMenu(graph) end)
    graph.colorButton = button("Color", "Color", function() self:showColorMenu(graph) end)
    graph.textButton = button("Text", "Text", function()
      self:showGraphTextMenu(graph)
    end)
    graph.fontButton = button("Font", "Aa", function()
      local style = self:graphStyle(graph); style.font = style.font == 12 and 14 or style.font == 14 and 10 or 12
      self:saveGraphStyle(graph, style); self:render()
    end)
    graph.resizeGrip = button("Resize", "//", function() end)
    graph.resizeGrip:EnableDrag(true)
    if DC_ALWAYS ~= nil then pcall(function() graph.resizeGrip:SetDragCondition(DC_ALWAYS) end) end
    local function resize()
      if not graph.resizing or graph.resizeId ~= graph.id then return end
      local width, height = number(w:GetWidth()), number(w:GetHeight())
      if not width or not height then return end
      local style = self:graphStyle(graph)
      style.width = math.floor(math.max(320, math.min(1200, width)))
      style.plotHeight = math.floor(math.max(80, math.min(500, height - (graph.height - graph.chart.height))))
      graph.resizeStyle = style
      self:layoutFloatingGraph(graph)
      self:render()
    end
    graph.resizeGrip:SetHandler("OnDragStart", function()
      graph.resizeStyle, graph.resizeId = self:graphStyle(graph), graph.id
      graph.resizing = true
      local overhead = graph.height - graph.chart.height
      w:SetMinResizingExtent(320, 80 + overhead); w:SetMaxResizingExtent(1200, 500 + overhead)
      w:StartSizing("BOTTOMRIGHT")
      return true
    end)
    graph.resizeGrip:SetHandler("OnDragStop", function()
      w:StopMovingOrSizing(); resize()
      local style, same = graph.resizeStyle, graph.resizeId == graph.id
      graph.resizing, graph.resizeStyle = false, nil
      if same and style then self:saveGraphStyle(graph, style) end
      graph.layoutSignature = nil
      self:layoutFloatingGraph(graph); self:render()
    end)
    w:SetHandler("OnUpdate", function(_, elapsed)
      if not graph.resizing then return end
      graph.resizeElapsed = (graph.resizeElapsed or 0) + (number(elapsed) or 0)
      if graph.resizeElapsed < 80 then return end -- native updates are milliseconds
      graph.resizeElapsed = 0; resize()
    end)
    self:layoutFloatingGraph(graph)
  end

  function Watch:applyGraphBackground(graph)
    local mode = self.settings.graphBackground or "transparent"
    if graph.backgroundMode == mode then return end
    if mode == "transparent" and not graph.background then
      graph.backgroundMode = mode
      return
    end
    if not graph.background then
      pcall(function() graph.window:EnableDrawables("background") end)
      local bg = graph.window:CreateColorDrawable(0.025, 0.025, 0.03, 0, "background")
      bg:AddAnchor("TOPLEFT", graph.window, 0, 0)
      bg:AddAnchor("BOTTOMRIGHT", graph.window, 0, 0)
      graph.background = bg
    end
    graph.background:SetColor(0.025, 0.025, 0.03, mode == "dark" and 0.9 or mode == "shaded" and 0.5 or 0)
    graph.backgroundMode = mode
  end

  function Watch:cycleGraphBackground()
    local current = self.settings.graphBackground
    self.settings.graphBackground = current == "transparent" and "shaded"
      or current == "shaded" and "dark" or "transparent"
    for _, graph in ipairs(self.miniGraphs or {}) do self:applyGraphBackground(graph) end
    if self.combinedGraph then self:applyGraphBackground(self.combinedGraph) end
    self:saveSettings()
    self:render()
  end

  function Watch:rateScreenSize()
    local scale = number(self.ctx.scale()) or 1
    if scale <= 0 then scale = 1 end
    local ok, sw, sh = pcall(function() return UIParent:GetScreenWidth(), UIParent:GetScreenHeight() end)
    sw, sh = ok and number(sw) or 1920, ok and number(sh) or 1080
    return math.max(1, sw / scale), math.max(1, sh / scale), scale
  end

  function Watch:restoreRatePosition(savedX, savedY, titleLeft, titleWidth, titleTop)
    local sw, sh, scale = self:rateScreenSize()
    -- Saves use screen pixels; anchors and GetOffset use logical UI units.
    local x, y = (number(savedX) or 180 * scale) / scale, (number(savedY) or 120 * scale) / scale
    -- Recover an inaccessible title after a resolution change, while allowing
    -- the transparent plot/legend to extend past any screen edge.
    x = math.max(32 - titleLeft - titleWidth, math.min(x, sw - titleLeft - 32))
    y = math.max(-titleTop, math.min(y, sh - titleTop - 18))
    return x, y, scale
  end

  function Watch:placeCombinedGraph()
    local graph = self.combinedGraph
    if not graph or graph.dragging or graph.resizing then return false end
    local s = self.settings
    local x, y, scale = self:restoreRatePosition(s.combinedX, s.combinedY, 28, (graph.width or WIDTH) - 230, 0)
    local changed = s.combinedX ~= x * scale or s.combinedY ~= y * scale
    s.combinedX, s.combinedY = x * scale, y * scale
    graph.window:RemoveAllAnchors()
    graph.window:AddAnchor("TOPLEFT", "UIParent", x, y)
    graph.positioned = true
    return changed
  end

  function Watch:createCombinedGraph()
    if self.combinedGraph then return self.combinedGraph end
    local c, prefix = self.ctx, "TradePacksRateCombined"
    local graph = {combined = true, height = LEGEND_Y + MAX_SERIES * LEGEND_STEP + 38, legends = {}, ticks = {}}
    local w = c.widget("window", prefix, nil, 180, 120, WIDTH, graph.height)
    graph.window, self.combinedGraph = w, graph
    pcall(function() w:SetTitleText(""); w:SetCloseOnEscape(false); w:EnablePick(false) end)
    self:applyGraphBackground(graph)
    local function label(id, x, y, width, text)
      local l = c.label(prefix .. id, w, x, y, width, 18, text or "")
      pcall(function()
        l.style:SetFontSize(12); l.style:SetColor(1, 1, 1, 1); l.style:SetOutline(true); l:EnablePick(false)
      end)
      return l
    end
    graph.title = label("Title", 30, 0, WIDTH - 104, "Trade rates comparison - drag to move")
    pcall(function() graph.title:EnablePick(true); graph.title:EnableDrag(true) end)
    pcall(function() graph.title:SetDragCondition(DC_ALWAYS) end)
    graph.title:SetHandler("OnDragStart", function()
      graph.dragging = true
      w:StartMoving()
      return true
    end)
    graph.title:SetHandler("OnDragStop", function()
      w:StopMovingOrSizing()
      graph.dragging = false
      local ok, x, y = pcall(function() return w:GetOffset() end)
      if ok and number(x) and number(y) then
        self.settings.combinedX, self.settings.combinedY = x * c.scale(), y * c.scale()
        self:saveSettings()
      end
    end)
    graph.expand = c.textButton(prefix .. "Expand", w, 0, 0, 26, 18, "...",
      function() self:setGraphOnly(false) end)
    graph.backgroundButton = c.textButton(prefix .. "Background", w, WIDTH - 62, 0, 30, 18, "BG",
      function() self:cycleGraphBackground() end)
    pcall(function() graph.backgroundButton.style:SetColor(1, 1, 1, 1) end)
    graph.close = c.textButton(prefix .. "Close", w, WIDTH - 28, 0, 24, 18, "x", function()
      self.settings.open = false
      if self.menu then self.menu:Show(false) end
      if self.periodEditor then self.periodEditor:Show(false) end
      self:saveSettings(); self:visibility()
    end)
    pcall(function() graph.expand.style:SetColor(1, 1, 1, 1); graph.close.style:SetColor(1, 1, 1, 1) end)
    graph.subtitle = label("Subtitle", 12, 25, WIDTH - 24)
    graph.chart = self:createLineChart(prefix .. "Plot", w, 60, 55, PLOT_WIDTH, PLOT_HEIGHT, true)
    for i = 1, 5 do graph.ticks[i] = label("Tick" .. i, 45, 229, 58) end
    for i = 1, MAX_SERIES do
      graph.legends[i] = {
        name = label("Name" .. i, 20, LEGEND_Y + (i - 1) * LEGEND_STEP, WIDTH - 40),
        detail = label("Detail" .. i, 20, LEGEND_Y + (i - 1) * LEGEND_STEP + 17, WIDTH - 40)
      }
    end
    graph.currentRates, graph.currentRateGuides, graph.currentRateGeometry = {}, {}, {}
    for i = 1, MAX_SERIES do
      local current = label("CurrentRate" .. i, 0, 0, 54, "")
      pcall(function()
        current.style:SetFontSize(11); current.style:SetOutline(true); current:EnablePick(false)
      end)
      current:SetExtent(54, 16); current:Show(false)
      graph.currentRates[i] = current
      local guide = c.widget("line", prefix .. "CurrentRateGuide" .. i, graph.chart.plot,
        0, 0, graph.chart.width + 8, graph.chart.height)
      guide:EnablePick(false); guide:SetLineThickness(1); guide:Show(false)
      graph.currentRateGuides[i] = guide
    end
    graph.status = label("Status", 12, graph.height - 22, WIDTH - 24)
    graph.proficiencyLabel = label("Proficiency", 64, graph.height - 22, 150, "Prof: Current")
    pcall(function()
      graph.proficiencyLabel.style:SetAlign(ALIGN_LEFT or LEFT)
      graph.proficiencyLabel:SetInset(0, 0, 0, 0)
      graph.status.style:SetAlign(ALIGN_RIGHT or RIGHT)
      graph.status:SetInset(0, 0, 0, 0)
    end)
    self:addGraphControls(graph, prefix)
    w:Show(false)
    return graph
  end

  function Watch:syncCombinedGraph(forcePosition)
    local visible = self.settings.open and self.settings.graphOnly and self.settings.graphLayout == "combined"
    local graph = self.combinedGraph
    if visible and not graph then graph = self:createCombinedGraph() end
    if not graph then return end
    if visible and (forcePosition or not graph.positioned) and self:placeCombinedGraph() then self:saveSettings() end
    if graph.window:IsVisible() ~= visible then graph.window:Show(visible) end
  end

  function Watch:renderCombinedStatus()
    local graph = self.combinedGraph
    if not graph or not graph.window:IsVisible() then return end
    local s, c, now = self.settings, self.ctx, self.ctx.now()
    for i, labels in ipairs(graph.legends) do
      local data = self.comparisonData and self.comparisonData[i]
      local visible = data ~= nil
      labels.name:Show(visible and not graph.hideNames)
      labels.detail:Show(visible and not graph.hideNames and (not graph.compact or graph.stacked))
      if data then
        local color = graph.chart.layers[i] and graph.chart.layers[i].color or {1, 1, 1}
        pcall(function()
          labels.name.style:SetColor(color[1], color[2], color[3], 1)
          labels.detail.style:SetColor(color[1], color[2], color[3], 1)
        end)
        local cached = s.metric == "profit" and data.costs and data.costs.stalePrices
        local route = data.routeLabel or (tostring(data.from or "?") .. " > " .. tostring(data.to or "?"))
        local custom = s.packAliases and s.packAliases[data.id]
        local routeText = custom or (self:displayPackName(data) .. " > " .. route)
        local value = quoteText(data, s.metric, c.money)
        if s.showRatePrice or s.metric == "both" then value = self:ratePriceText(data) end
        local state = ageText(data.quote and data.quote.at, now, self.staleAfter and self:staleAfter() or 90)
        if not data.count or data.count == 0 then state = "no history / " .. state end
        local width, font = (graph.width or WIDTH) - 20, graph.font or 12
        if s.showRatePrice or s.metric == "both" then
          local rate = data.quote and number(data.quote.ratio)
          local rateText = rate and string.format("%.1f%%", rate) or "rate unavailable"
          self:setGraphLabel(labels.name, tostring(i) .. ". " .. routeText,
            width, font, " | " .. rateText)
          -- Keep the price first: a narrow chart may shorten the reading age,
          -- but must not reserve that space at the expense of the price.
          self:setGraphLabel(labels.detail, "Price: " .. quoteText(data, "price", c.money)
            .. " | " .. state, width, font)
        elseif graph.compact and not graph.stacked then
          local tail = " | " .. value .. " | " .. state .. (cached and " | cached costs" or "")
          self:setGraphLabel(labels.name,
            tostring(i) .. ". " .. routeText, width, font, tail)
        else
          self:setGraphLabel(labels.name, tostring(i) .. ". " .. self:displayPackName(data),
            width, font, cached and " | cached costs" or "")
          if custom then self:setGraphLabel(labels.detail, value .. " | " .. state, width, font)
          else self:setGraphLabel(labels.detail, route, width, font, " | " .. value .. " | " .. state) end
        end
      end
    end
    local mode = s.proficiencyMode or "current"
    local proficiency = mode == "current" and "Current" or mode == "off" and "OFF"
      or (number(mode) and string.format("%.0fk", number(mode) / 1000) or "Current")
    if mode == "current" and (graph.proficiencyWidth or 150) < 140 then proficiency = "Live" end
    self:setGraphLabel(graph.proficiencyLabel, "Prof: " .. proficiency,
      graph.proficiencyWidth or 150, graph.font or 12)
    local status = self:refreshStatus() or ""
    if (graph.statusWidth or 0) < 260 then
      status = status:gsub("Next route update in ", "Next: "):gsub("Next update in ", "Next: ")
    end
    if (graph.statusWidth or 0) < 100 then
      local seconds = status:match("^Next: (%d+s)%.?$")
      if seconds then status = "In " .. seconds end
    end
    self:setGraphLabel(graph.status, status, graph.statusWidth or ((graph.width or WIDTH) - 94), graph.font or 12)
  end

  function Watch:renderCombinedCurrentRates(graph)
    local rows, low, high = {}, graph.lowValue, graph.highValue
    local show = self.settings.metric == "rate" and graph.currentRateGutter > 0
      and number(low) and number(high) and high > low
    if show then
      for i, data in ipairs(self.comparisonData or {}) do
        local rate = data.quote and number(data.quote.ratio)
        if rate then
          -- Match the marker's vertical coordinate inside the plot. Anchoring
          -- to the plot itself also follows compact mode and resizing.
          local top = graph.chart.height
            - graph.chart.height * (rate - low) / (high - low)
          rows[#rows + 1] = {index = i, rate = rate,
            sourceTop = top, top = math.max(9, math.min(graph.chart.height - 9, top)),
            color = graph.chart.layers[i] and graph.chart.layers[i].color or {1, 1, 1}}
        end
      end
    end
    table.sort(rows, function(a, b)
      if a.top == b.top then return a.index < b.index end
      return a.top < b.top
    end)
    local gap = (graph.font or 12) + 6
    for i = 2, #rows do rows[i].top = math.max(rows[i].top, rows[i - 1].top + gap) end
    if #rows > 0 then
      local overflow = rows[#rows].top - (graph.chart.height - 9)
      if overflow > 0 then for _, row in ipairs(rows) do row.top = row.top - overflow end end
    end
    local used = {}
    for _, row in ipairs(rows) do
      local label = graph.currentRates[row.index]
      if label then
        local text = string.format("%.1f%%", row.rate)
        if self.ctx.now() - (self.comparisonData[row.index].quote.at or 0)
          > (self.staleAfter and self:staleAfter() or 90) then text = text .. "*" end
        if label.text ~= text then label:SetText(text) end
        pcall(function() label.style:SetColor(row.color[1], row.color[2], row.color[3], 1) end)
        label:SetExtent(54, 18)
        label:RemoveAllAnchors()
        label:AddAnchor("LEFT", graph.chart.plot, "TOPLEFT", graph.chart.width + 10, row.top)
        label:Show(true); used[row.index] = true
        local guide = graph.currentRateGuides[row.index]
        guide:SetLineColor(row.color[1], row.color[2], row.color[3], 0.8)
        local displaced = math.abs(row.top - row.sourceTop) > 0.5
        if displaced then
          local geometry = table.concat({graph.chart.width, graph.chart.height, row.sourceTop, row.top}, ":")
          if graph.currentRateGeometry[row.index] ~= geometry then
            guide:SetExtent(graph.chart.width + 8, graph.chart.height)
            guide:ClearPoints()
            guide:SetPoints({{beginX = graph.chart.width, beginY = graph.chart.height - row.sourceTop,
              endX = graph.chart.width + 8, endY = graph.chart.height - row.top}})
            graph.currentRateGeometry[row.index] = geometry
          end
        end
        guide:Show(displaced)
      end
    end
    for i, label in ipairs(graph.currentRates or {}) do
      if not used[i] then label:Show(false); graph.currentRateGuides[i]:Show(false) end
    end
  end

  function Watch:renderCombinedGraph()
    self:syncCombinedGraph()
    local graph = self.combinedGraph
    if not graph or not graph.window:IsVisible() then return end
    local s, c, count = self.settings, self.ctx, math.min(MAX_SERIES, #(self.comparisonData or {}))
    self:layoutFloatingGraph(graph)
    local low, high, layout
    for _, data in ipairs(self.comparisonData or {}) do
      layout = layout or data.layout
      for _, point in pairs(data.columns or {}) do
        local value = number(point.value)
        if value then low, high = math.min(low or value, value), math.max(high or value, value) end
      end
      if s.metric == "rate" and data.quote then
        local rate = number(data.quote.ratio)
        if rate then low, high = math.min(low or rate, rate), math.max(high or rate, rate) end
      end
    end
    if not layout then
      local _, unusedBest, unusedCount
      _, unusedBest, unusedCount, layout = self:chartData()
    end
    low, high = self:chartBounds(low, high)
    graph.lowValue, graph.highValue = low, high
    local metric = s.metric == "profit" and "Estimated profit" or s.metric == "price" and "Price estimate" or "Payout rate"
    graph.title:SetText(metric .. " comparison - drag to move")
    graph.subtitle:SetText(periodText(s) .. " | UTC" .. (s.offset >= 0 and "+" or "") .. s.offset
      .. " | shared scale" .. (s.metric == "profit" and " | current costs" or ""))
    if s.metric == "both" then graph.subtitle:SetText("Solid: rate % (left) | Dashed: est. price (right)") end
    self:setGraphLabel(graph.title, s.metric == "both" and "Rate + Price" or metric,
      graph.width - 230, graph.font)
    self:renderComparison(graph.chart, low, high, layout)
    self:renderCombinedCurrentRates(graph)
    self:renderValueAxis(graph.chart, low, high)
    if self.renderPriceOverlay then self:renderPriceOverlay(graph.chart, self.comparisonData, layout) end
    self:renderTicks(graph.ticks, graph.chart, layout)
    local title, detail
    if low == nil then
      if count == 0 then title, detail = "Choose packs to compare", "Open ... to choose packs and routes."
      elseif (self.historyLoading or 0) > 0 then title, detail = "Loading this period...", "Reading saved observations."
      else title, detail = "No values in this period", "See each pack below for its current status." end
    end
    self:renderEmptyState(graph.chart, title, detail, false)
    self:renderCombinedStatus()
    self:styleFloatingText(graph)
  end
end
