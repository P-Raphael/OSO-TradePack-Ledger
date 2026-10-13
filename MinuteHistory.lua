-- Recent observations use three reusable UTC-hour slots per pack and route.
-- Hourly history stays independent; these points are never reconstructed from it.
TradePacksMinuteHistory = {}
local History = {}
History.__index = History
local SLOT_COUNT = 3

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value >= 0 and value == math.floor(value)
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, part in pairs(value) do out[key] = copy(part) end
  return out
end

local function validSeries(series)
  return type(series) == "table" and type(series.key) == "string" and #series.key > 0
    and type(series.name) == "string" and #series.name > 0 and #series.name <= 512
    and integer(series.from) and integer(series.to)
end

local function identity(data, series)
  return type(data) == "table" and data.version == 1 and data.name == series.name
    and data.from == series.from and data.to == series.to
end

local function validData(data, series, slot)
  if not identity(data, series) or not integer(data.hour) or data.hour % SLOT_COUNT ~= slot
    or type(data.minutes) ~= "table" then return false end
  local count = 0
  for minute, ratio in pairs(data.minutes) do
    if not integer(minute) or minute > 59 or not finite(ratio) or ratio <= 0 then return false end
    count = count + 1
  end
  return count <= 60
end

local function validMeta(meta, series, slot)
  return identity(meta, series) and integer(meta.hour) and meta.hour % SLOT_COUNT == slot
    and (meta.bank == "A" or meta.bank == "B")
end

function TradePacksMinuteHistory.new(ctx)
  return setmetatable({ctx = ctx, entries = {}}, History)
end

function History:loadSlot(series, slot)
  if not validSeries(series) then error("invalid minute history identity") end
  local key = series.key .. "Minute" .. slot
  local entry = self.entries[key]
  if entry then
    if not identity(entry.data, series) then error("minute history identity mismatch; preserving saved data") end
    return entry
  end
  local meta = ADDON:LoadData(key .. "Meta")
  local data, bank
  if meta == nil then
    -- Orphaned banks may contain a write whose commit failed. Never overwrite them
    -- as though this were a new slot, including a possible pack-name hash collision.
    if ADDON:LoadData(key .. "A") ~= nil or ADDON:LoadData(key .. "B") ~= nil then
      error("minute history has no valid pointer; preserving saved copies")
    end
    data = {version = 1, name = series.name, from = series.from, to = series.to, minutes = {}}
  else
    if not validMeta(meta, series, slot) then
      error("minute history pointer or identity is invalid; preserving saved copies")
    end
    bank = meta.bank
    data = ADDON:LoadData(key .. bank)
    if not validData(data, series, slot) or data.hour ~= meta.hour then
      bank = bank == "A" and "B" or "A"
      data = ADDON:LoadData(key .. bank)
    end
    if not validData(data, series, slot) or data.hour ~= meta.hour then
      error("minute history is incomplete; preserving saved copies")
    end
  end
  entry = {key = key, slot = slot, data = data, bank = bank, meta = meta}
  self.entries[key] = entry
  return entry
end

function History:saveSlot(key)
  -- Jobs capture the ring key, not a superseded hour. A delayed retry can only
  -- write the latest entry that occupies that slot.
  local entry = self.entries[key]
  if not entry or not entry.dirty then return end
  local hour = math.floor(self.ctx.now() / 3600)
  if entry.data.hour < hour - SLOT_COUNT + 1 or entry.data.hour > hour then return end
  local bank = entry.bank == "A" and "B" or "A"
  local data = copy(entry.data)
  ADDON:SaveData(key .. bank, data)
  if not self.ctx.sameData(data, ADDON:LoadData(key .. bank)) then
    error("minute history slot did not read back completely")
  end
  local meta = {version = 1, name = data.name, from = data.from, to = data.to,
    hour = data.hour, bank = bank}
  ADDON:SaveData(key .. "Meta", meta)
  if not self.ctx.sameData(meta, ADDON:LoadData(key .. "Meta")) then
    error("minute history commit did not read back completely")
  end
  entry.bank, entry.meta, entry.dirty = bank, meta, nil
end

function History:sample(series, at, ratio)
  local now = self.ctx.now()
  if not finite(at) or not finite(now) or at < 0 or at > now or not finite(ratio) or ratio <= 0 then
    return false
  end
  local hour, currentHour = math.floor(at / 3600), math.floor(now / 3600)
  if hour < currentHour - SLOT_COUNT + 1 then return false end
  local slot, minute = hour % SLOT_COUNT, math.floor(at % 3600 / 60)
  local entry = self:loadSlot(series, slot)
  if entry.data.hour and entry.data.hour > hour then return false end
  if entry.data.hour ~= hour then
    -- Keep the previous active bank until the new hour's complete data is verified.
    entry.data = {version = 1, name = series.name, from = series.from, to = series.to,
      hour = hour, minutes = {}}
  end
  if entry.data.minutes[minute] ~= nil then return false end
  entry.data.minutes[minute], entry.dirty = ratio, true
  self.ctx.enqueue("minute:" .. entry.key, function() self:saveSlot(entry.key) end, true)
  return true
end

function History:loadRecent(series)
  local hour = math.floor(self.ctx.now() / 3600)
  for offset = SLOT_COUNT - 1, 0, -1 do
    if hour - offset >= 0 then self:loadSlot(series, (hour - offset) % SLOT_COUNT) end
  end
end

function History:rows(series, now)
  -- Rendering never calls native persistence. loadRecent belongs in a background job.
  if not validSeries(series) then return {} end
  now = now or self.ctx.now()
  if not finite(now) or now < 0 then return {} end
  local hour, rows = math.floor(now / 3600), {}
  for slot = 0, SLOT_COUNT - 1 do
    local entry = self.entries[series.key .. "Minute" .. slot]
    local data = entry and entry.data
    if identity(data, series) and data.hour and data.hour >= hour - SLOT_COUNT + 1 and data.hour <= hour then
      for minute, ratio in pairs(data.minutes) do
        local at = data.hour * 3600 + minute * 60
        if at <= now then rows[#rows + 1] = {at = at, ratio = ratio} end
      end
    end
  end
  table.sort(rows, function(a, b) return a.at < b.at end)
  return rows
end
