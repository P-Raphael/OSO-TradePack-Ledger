-- Run from Addon: lua TradePacks/tests/test_auction_queue.lua
-- Exercise actual event/driver paths, including native millisecond OnUpdate.
local now, suffix, saved, widgets, handlers, searches, result, mode, counts
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, part in pairs(v) do out[k] = copy(part) end
  return out
end
local Widget = {}
Widget.__index = function(_, k) return Widget[k] or function() end end
local function widget(name)
  local v = setmetatable({handlers = {}, visible = true, name = name}, Widget)
  v.style = setmetatable({}, Widget)
  widgets[name] = v
  return v
end
function Widget:CreateChildWidget(_, name) return widget(name) end
function Widget:CreateColorDrawable() return widget("drawable") end
function Widget:CreateImageDrawable() return widget("image") end
function Widget:CreateIconDrawable() return widget("icon") end
function Widget:SetHandler(name, handler) self.handlers[name] = handler end
function Widget:SetText(text) self.text = text end
function Widget:GetText() return self.text end
function Widget:SetExtent(w, h) self.width, self.height = w, h end
function Widget:GetWidth() return self.width end
function Widget:GetHeight() return self.height end
function Widget:GetOffset() return 0, 0 end
function Widget:Show(show) self.visible = show end
function Widget:IsVisible() return self.visible end
local function ui(name) return assert(widgets[name .. suffix], name) end
local function event(name, ...) ui("TradePacksLedgerWindow").handlers.OnEvent(nil, name, ...) end
local function driverEvent(name) ui("TradePacksAuctionDriver").handlers.OnEvent(nil, name) end
local function tick(seconds)
  for _ = 1, seconds * 2 do
    now = now + 0.5
    ui("TradePacksAuctionDriver").handlers.OnUpdate(nil, 500)
  end
end
local function respond(name, unit, stack)
  result = name and {name = name, stackCount = stack or 1, buyout = tostring(unit * (stack or 1))} or nil
  handlers.AUCTION_ITEM_SEARCHED()
end
local function countSearch(name)
  local n = 0
  for _, request in ipairs(searches) do if request.name == name then n = n + 1 end end
  return n
end
local function seed(records)
  now, saved, widgets, handlers, searches, result, mode, counts = 1700000000, {}, {}, {}, {}, nil, nil, {}
  suffix = tostring(now)
  ADDON = {
    ImportAPI = function() end, ImportObject = function() end,
    RegisterContentWidget = function() end,
    GetCurrentTimeStamp = function() return now end,
    LoadData = function(_, key) counts.reads = (counts.reads or 0) + 1; return copy(saved[key]) end,
    SaveData = function(_, key, data) counts.writes = (counts.writes or 0) + 1; saved[key] = copy(data) end,
    ChatLog = function(_, text) assert(not text:find("failed", 1, true), text) end
  }
  UIParent = {
    CreateWidget = function(_, _, name) return widget(name) end,
    SetEventHandler = function(_, name, handler) handlers[name] = handler end
  }
  UIEVENT_TYPE = {AUCTION_ITEM_SEARCHED = "AUCTION_ITEM_SEARCHED", AUCTION_LOWEST_PRICE = "AUCTION_LOWEST_PRICE"}
  X2Auction = {
    SearchAuctionArticle = function(_, _, _, _, _, _, _, name)
      assert(not counts.loading, "searched AH during loading")
      if #searches > 0 then assert(now - searches[#searches].at >= 2, "search cooldown ignored") end
      searches[#searches + 1] = {name = name, at = now}
      result = nil
      if mode == "synchronous" then respond(name, 123) end
      if mode == "rejected" then return false end
    end,
    GetLowestPrice = function() counts.lowest = (counts.lowest or 0) + 1 end,
    GetSearchedItemCount = function()
      assert(not counts.loading, "read AH during loading")
      counts.polls = (counts.polls or 0) + 1
      return result and 1 or 0
    end,
    GetSearchedItemInfo = function() return result end,
    GetSearchedItemPrice = function() return "1", result and result.buyout end
  }
  saved.TradePacksState = {
    version = 2, nextId = #records + 1, records = records, prices = {},
    settings = {costPresets = {}, opener = {x = 24, y = 260}, repairedContaminatedPayouts = true,
      removedDebugMockRecord = true}
  }
  TradePacksRateWatch = nil
  dofile("TradePacks/TradePacks.lua")
  ui("TradePacksLedgerWindow"):Show(false)
  ui("TradePacksFloatingButton"):Show(false)
end
local function materialRecord(id, name)
  return {id = id, cargoName = "Pack " .. id, soldAt = 1699990000 + id,
    payoutCopper = 1000000, materials = {{name = name, count = 2}}}
end
local function record(id)
  for _, r in ipairs(TradePacksLedger.State.records) do if r.id == id then return r end end
end
local function refresh()
  ui("TradePacksLedgerWindow"):Show(true)
  TradePacksLedger.RefreshPrices()
  ui("TradePacksLedgerWindow"):Show(false)
end

-- More than 25 unique quotes must drain with both the ledger and OPS hidden.
local records = {}
for id = 1, 28 do records[#records + 1] = materialRecord(id, "Ingredient " .. id) end
seed(records)
-- Startup may occur after ENTERED_WORLD; no extra event or opening OPS is needed.
tick(2)
assert(#searches == 1)
refresh() -- A second refresh must not forget the active request or its siblings.
assert(#searches == 1)
for i = 1, 28 do
  assert(#searches == i, "queue lost a quote or duplicated an active request")
  respond(searches[i].name, 100 + i, 3)
  tick(2)
end
for id = 1, 28 do
  assert(record(id).costStatus == "snapshot" and record(id).costCopper > 0,
    "unpriced ledger entry was not automatically completed")
end
assert(#searches == 28, "completed ingredients were redundantly searched")
local writes, polls = counts.writes, counts.polls
tick(10)
assert(counts.writes == writes and counts.polls == polls, "idle scheduler performs native work")

-- A late response survives Refresh and an eight-second timeout gets a bounded
-- retry behind other ingredients; no result does not permanently lose the row.
seed({materialRecord(1, "First"), materialRecord(2, "Second")})
refresh()
local first = searches[1].name
tick(3)
refresh()
assert(#searches == 1, "refresh replaced the active request")
tick(5)
assert(#searches == 2 and searches[2].name ~= first, "timeout blocked the next ingredient")
respond(searches[2].name, 200)
tick(3)
assert(searches[3].name == first, "timed-out quote was never retried")
respond(first, 300)
tick(10)
assert(#searches == 3)
assert(record(1).costStatus == "snapshot" and record(2).costStatus == "snapshot")

seed({materialRecord(1, "Absent")})
refresh()
respond(nil)
tick(3)
assert(#searches == 2)
respond(nil)
tick(10)
assert(#searches == 3)
respond(nil)
tick(60)
assert(#searches == 3 and record(1).costStatus == "pricing", "empty listings retried without a bound")

-- Native false returns and callbacks that arrive inside SearchAuctionArticle.
seed({materialRecord(1, "Transient")})
mode = "rejected"
refresh()
tick(3)
mode = "synchronous"
tick(10)
assert(record(1).costCopper == 246 and #searches == 3,
  "a failed send or synchronous callback left the active slot stuck")

-- Name-only payout quotes must repair unresolved rows, with old snapshots frozen.
seed({
  {id = 1, cargoName = "Payout pack", soldAt = 1699990000, costCopper = 100,
    costStatus = "manual", payoutName = "Dragon Essence Stabilizer", payoutCount = 4},
  {id = 2, cargoName = "Priced pack", soldAt = 1699990001, costCopper = 200,
    costStatus = "snapshot", materialCostCopper = 200,
    materials = {{name = "Frozen", count = 2, unitPriceCopper = 100}},
    payoutName = "Dragon Essence Stabilizer", payoutCount = 4, payoutUnitPriceCopper = 42}
})
refresh()
assert(searches[1].name == "Dragon Essence Stabilizer")
respond(searches[1].name, 500, 2)
assert(record(1).payoutUnitPriceCopper == 500 and record(1).payoutPricedAt == now)
assert(record(2).payoutUnitPriceCopper == 42 and record(2).costCopper == 200,
  "completing missing prices rewrote a historical snapshot")
local meta = saved.TradePacksState
assert(saved["TradePacksRecords" .. meta.recordBank .. "_1"][1].payoutUnitPriceCopper == 500,
  "completed quote was not persisted to the ledger")

-- Loading screens pause all auction calls, preserve the pending item and restart
-- it after the world is ready. No new retry is consumed by the interrupted send.
seed({materialRecord(1, "Loading ingredient")})
refresh()
driverEvent("ENTERED_LOADING")
counts.loading = true
tick(30)
respond("Loading ingredient", 500)
assert(record(1).costStatus == "pricing" and #searches == 1)
counts.loading = false
driverEvent("LEFT_LOADING")
tick(2)
assert(#searches == 2)
respond("Loading ingredient", 500)
assert(record(1).costCopper == 1000)

-- Continuous turn-ins do not keep extending the initial quote deadline.
seed({})
local ledger = ui("TradePacksLedgerWindow")
for i = 1, 4 do
  event("SELL_SPECIALTY_CONTENT_INFO", {name = "Run pack " .. i, payoutCopper = 50000})
  local sale = TradePacksLedger.AddRecord("Run pack " .. i)
  sale.materials = {{name = "Run ingredient", count = 1}}
  tick(0.5)
end
assert(#searches >= 1 and searches[1].at <= 1700000001,
  "successive turn-ins delayed the first quote")
respond("Run ingredient", 500)
for id = 1, 4 do assert(record(id).costCopper == 500) end

-- The small scheduler receives milliseconds, even on very fast frames.
seed({materialRecord(1, "Fast frames")})
refresh()
local before = counts.polls or 0
for _ = 1, 49 do ui("TradePacksAuctionDriver").handlers.OnUpdate(nil, 1) end
assert((counts.polls or 0) == before, "1 ms frames were treated as one second")
tick(0.5)
assert((counts.polls or 0) - before <= 1, "scheduler polls more than twice per second")

print("Auction queue checks passed: hidden ledger, 28 quotes, overlap, bounded retries, loading, snapshots, millisecond timer")
