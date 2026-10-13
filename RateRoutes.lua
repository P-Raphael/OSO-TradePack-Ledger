-- Selected graphs own a route; the From/To controls only browse packs to add.
TradePacksRateRoutes = {}
local function valid(value)
  local n = tonumber(value)
  return n and n > 0 and n < 1000000 and n == math.floor(n) and n or nil
end
local function key(from, to) return tostring(from) .. "_" .. tostring(to) end
local function entry(name, from, to, source)
  from, to = valid(from), valid(to)
  if type(name) ~= "string" or name == "" or #name > 200 or not from or not to or from == to then return end
  return {id = key(from, to) .. ":" .. name, name = name, from = from, to = to,
    fromName = source and source.fromName, toName = source and source.toName}
end

function TradePacksRateRoutes.install(Watch)
  function Watch:initRouteSelection()
    local s, selected, seen = self.settings, {}, {}
    if type(s.selectedRoutes) == "table" then
      for _, value in ipairs(s.selectedRoutes) do
        local item = type(value) == "table" and entry(value.name, value.from, value.to, value)
        if item and not seen[item.id] and #selected < 6 then
          selected[#selected + 1], seen[item.id] = item, true
        end
      end
    else
      for _, name in ipairs(s.selectedPacks or {}) do
        local item = entry(name, s.from, s.to)
        if item and not seen[item.id] and #selected < 6 then
          selected[#selected + 1], seen[item.id] = item, true
        end
      end
    end
    s.selectedRoutes = selected
    s.graphLayout = s.graphLayout == "combined" and "combined" or "separate"
    self.routeQuotes, self.routePacks, self.routePollAt, self.zoneNames, self.routeOutlets = {}, {}, {}, {}, {}
    self.legacyPack = s.pack
    if #selected > 0 then self:syncRouteSelection() end
    for _, item in ipairs(selected) do
      local old = s.graphPositions[item.name]
      if old and not s.graphPositions[item.id] then
        s.graphPositions[item.id] = {x = old.x, y = old.y, used = old.used}
      end
    end
  end

  function Watch:syncRouteSelection()
    local s, names, focus = self.settings, {}, nil
    for _, item in ipairs(s.selectedRoutes or {}) do
      names[#names + 1] = item.name
      if item.id == s.focusId then focus = item end
    end
    if not focus then
      for _, item in ipairs(s.selectedRoutes or {}) do
        if item.name == s.pack then focus = item; break end
      end
    end
    focus = focus or s.selectedRoutes[1]
    s.selectedPacks, s.pack, s.focusId = names, focus and focus.name, focus and focus.id
    self.legacyPack = s.pack
  end

  function Watch:selectedEntries()
    local s = self.settings
    -- Keep the legacy single-pack setting usable by older callers/settings.
    if s.pack ~= self.legacyPack or (#s.selectedRoutes == 0 and s.pack) then
      local item = entry(s.pack, s.from, s.to)
      s.selectedRoutes = item and {item} or {}
      self:syncRouteSelection()
    end
    return s.selectedRoutes
  end

  function Watch:selectedPackNames()
    self:selectedEntries()
    return self.settings.selectedPacks
  end

  function Watch:routeEntry(value, from, to)
    if type(value) == "table" then return entry(value.name, value.from, value.to, value) end
    local s = self.settings
    if from or to then return entry(value, from or s.from, to or s.to) end
    local selected = self:selectedEntries()
    for _, item in ipairs(selected) do if item.id == (value or s.focusId) then return item end end
    value = value or s.pack
    for _, item in ipairs(selected) do
      if item.name == value and item.from == s.from and item.to == s.to then return item end
    end
    for _, item in ipairs(selected) do if item.name == value then return item end end
    return entry(value, s.from, s.to)
  end

  function Watch:rememberZones(zones)
    for _, zone in ipairs(zones or {}) do self.zoneNames[zone.id] = zone.name end
    for _, item in ipairs(self:selectedEntries()) do
      item.fromName = self.zoneNames[item.from] or item.fromName
      item.toName = self.zoneNames[item.to] or item.toName
    end
  end

  function Watch:routeLabel(item)
    item = self:routeEntry(item)
    if not item then return "Choose a route" end
    return (self.zoneNames[item.from] or item.fromName or ("Zone " .. item.from)) .. " -> "
      .. (self.zoneNames[item.to] or item.toName or ("Zone " .. item.to))
  end

  function Watch:isSelectedPack(name, from, to)
    for _, item in ipairs(self:selectedEntries()) do
      if (item.id == name or item.name == name) and (not from or item.from == from)
        and (not to or item.to == to) then return true end
    end
    return false
  end

  function Watch:setFocusPack(value)
    local item = self:routeEntry(value)
    if not item or not self:isSelectedPack(item.id) then return end
    self.settings.pack, self.settings.focusId, self.legacyPack = item.name, item.id, item.name
    self.selectedPoint = nil
    self:saveSettings(); self:render()
  end

  function Watch:togglePack(value, from, to)
    local item
    if type(value) == "table" then item = self:routeEntry(value)
    elseif not from and not to then
      for _, selected in ipairs(self:selectedEntries()) do if selected.id == value then item = selected; break end end
    end
    item = item or self:routeEntry(value, from or self.settings.from, to or self.settings.to)
    if not item then return end
    local selected, found = self:selectedEntries(), nil
    for i, current in ipairs(selected) do if current.id == item.id then found = i; break end end
    if found then
      if #selected == 1 then self.menuHint = "Keep at least one pack selected."; self:renderMenu(); return end
      table.remove(selected, found)
      if self.settings.focusId == item.id then self.settings.focusId, self.settings.pack = nil, nil end
    else
      if #selected >= 6 then self.menuHint = "Choose up to 6 packs; untick one to add another."; self:renderMenu(); return end
      item.fromName, item.toName = self.zoneNames[item.from], self.zoneNames[item.to]
      selected[#selected + 1] = item
    end
    self:syncRouteSelection()
    self.selectedPoint, self.menuHint = nil, nil
    if self.menuMulti then self.menuOptions = self:packMenuOptions() end
    self:saveSettings(); self:loadSelectedHistory(); self:render(); self:renderMenu()
  end

  function Watch:packMenuOptions()
    local options, seen = {}, {}
    for _, item in ipairs(self:selectedEntries()) do options[#options + 1], seen[item.id] = item, true end
    for _, pack in ipairs(self.packs or {}) do
      local item = entry(pack.name, self.settings.from, self.settings.to)
      if item and not seen[item.id] then options[#options + 1], seen[item.id] = item, true end
    end
    return options
  end

  function Watch:latestQuote(value)
    local item = self:routeEntry(value)
    if not item then return end
    if item.from == self.settings.from and item.to == self.settings.to then return self.latest[item.name] end
    local quotes = self.routeQuotes[key(item.from, item.to)]
    return quotes and quotes[item.name]
  end

  function Watch:trackedRoutes()
    local routes, seen = {}, {}
    for _, item in ipairs(self:selectedEntries()) do
      local identity = key(item.from, item.to)
      if not seen[identity] then
        routes[#routes + 1], seen[identity] = {from = item.from, to = item.to, key = identity}, true
      end
    end
    if #routes == 0 and valid(self.settings.from) and valid(self.settings.to)
      and self.settings.from ~= self.settings.to then
      routes[1] = {from = self.settings.from, to = self.settings.to, key = key(self.settings.from, self.settings.to)}
    end
    return routes
  end

  function Watch:nextRoute()
    local s = self.settings
    if self.browsePending and valid(s.from) and valid(s.to) and s.from ~= s.to then
      return {from = s.from, to = s.to, key = key(s.from, s.to)}
    end
    local chosen, oldest
    for _, route in ipairs(self:trackedRoutes()) do
      local at = self.routePollAt[route.key] or -1
      if not chosen or at < oldest then chosen, oldest = route, at end
    end
    return chosen
  end

  function Watch:staleAfter()
    return math.max(90, #self:trackedRoutes() * (self.routeInterval or 30) + 30)
  end
end
