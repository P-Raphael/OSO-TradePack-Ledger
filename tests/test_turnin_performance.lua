-- Run from the Addon directory: lua TradePacks/tests/test_turnin_performance.lua
-- Native calls are counted rather than timed: this mock cannot measure game FPS.
local clock = 1700000000
local saved, widgets, logs, counts = {}, {}, {}, {}
local suffix
local failRecordWrites, failHistoryWrites = false, false
local failRecordKey

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, part in pairs(value) do result[copy(key)] = copy(part) end
  return result
end

local function count(operation, key)
  counts[operation] = (counts[operation] or 0) + 1
  if type(key) == "string" then
    local category = key:match("^TradePacksRecords") and "records"
      or key:match("^TradePacksRuns") and "runs"
      or key:match("^TradePacksHistory") and "history" or "other"
    local name = operation .. "_" .. category
    counts[name] = (counts[name] or 0) + 1
  end
end

ADDON = {
  ImportAPI = function() end,
  ImportObject = function() end,
  GetCurrentTimeStamp = function() return clock end,
  LoadData = function(_, key) count("reads", key); return copy(saved[key]) end,
  SaveData = function(_, key, value)
    count("writes", key)
    saved[key] = copy(value)
    if (failRecordWrites and key:match("^TradePacksRecords[AB]_%d+$")) or key == failRecordKey then
      saved[key][#saved[key]] = nil
    end
    if failHistoryWrites and key:match("^TradePacksHistory[AB]$") then
      saved[key].packCount = nil
    end
  end,
  ClearData = function(_, key) saved[key] = nil end,
  ChatLog = function(_, text) logs[#logs + 1] = text end,
  RegisterContentWidget = function() end
}

local Widget = {}
Widget.__index = function(_, key) return Widget[key] or function() end end
local function newWidget(name, kind)
  local value = setmetatable({name = name, kind = kind, handlers = {}, visible = true}, Widget)
  value.style = setmetatable({}, Widget)
  widgets[name] = value
  return value
end
function Widget:CreateChildWidget(kind, name) return newWidget(name, kind) end
function Widget:CreateColorDrawable() return newWidget("drawable") end
function Widget:CreateImageDrawable() return newWidget("image") end
function Widget:CreateIconDrawable() return newWidget("icon") end
function Widget:SetHandler(event, handler) self.handlers[event] = handler end
function Widget:SetStyle() self.autoSized = true; self.width, self.height = 55, 22 end
function Widget:SetText(value)
  count("texts")
  self.text = value
  if rawget(self, "autoSized") then self.width = #value * 9 + 20 end
end
function Widget:GetText() return self.text end
function Widget:Show(value) self.visible = value end
function Widget:IsVisible() return self.visible end
function Widget:GetOffset() return 0, 0 end
function Widget:GetHeight() return self.height end
function Widget:GetWidth() return self.width end
function Widget:SetExtent(width, height) self.width, self.height = width, height end
function Widget:AddAnchor(_, _, x, y)
  if type(x) == "number" and type(y) == "number" then self.x, self.y = x, y end
end
UIParent = {CreateWidget = function(_, kind, name) return newWidget(name, kind) end}

local function widget(name) return assert(widgets[name .. suffix], "missing widget: " .. name) end
local function loadAddon(allowSaveFailure)
  widgets, logs = {}, {}
  suffix = tostring(clock)
  dofile("TradePacks/MinuteHistory.lua")
  dofile("TradePacks/RateRoutes.lua")
  dofile("TradePacks/RateChart.lua")
  dofile("TradePacks/RateCombined.lua")
  dofile("TradePacks/RateWatch.lua")
  dofile("TradePacks/TradePacks.lua")
  for _, message in ipairs(logs) do
    assert(not message:find("createUi failed", 1, true), message)
    if not allowSaveFailure then assert(not message:find("failed", 1, true), message) end
  end
end

local function history()
  local meta = assert(saved.TradePacksHistoryMeta, "missing history metadata")
  return assert(saved["TradePacksHistory" .. meta.bank], "missing history summary")
end

local function turnIn(name, payout)
  clock = clock + 10
  local ledger = widget("TradePacksLedgerWindow")
  ledger.handlers.OnEvent(ledger, "SELL_SPECIALTY_CONTENT_INFO", {
    name = name or "Auroran Cargo", payoutCopper = payout or 1000000
  })
  ledger.handlers.OnEvent(ledger, "SELL_SPECIALTY", "Sold an item.[" .. (name or "Auroran Cargo") .. "]")
end

local function seed(recordCount)
  saved, widgets, logs, counts = {}, {}, {}, {}
  clock = 1700000000
  local records = {}
  for id = 1, recordCount do
    records[id] = {
      id = id, cargoName = "Auroran Cargo", soldAt = clock - (recordCount - id + 1) * 3600,
      costCopper = 260000, costStatus = "preset", costSource = "preset",
      payoutCopper = 1000000, delaySeconds = 8 * 3600
    }
  end
  saved.TradePacksState = {
    version = 2, nextId = recordCount + 1, records = records, prices = {},
    settings = {costPresets = {["Auroran Cargo"] = 260000}, opener = {x = 24, y = 260},
      repairedContaminatedPayouts = true}
  }
  loadAddon()
end

local function assertReload(recordCount, profit)
  loadAddon()
  assert(#TradePacksLedger.State.records == recordCount, "sale was lost on immediate reload")
  assert(TradePacksLedger.State.nextId == recordCount + 1, "next record ID was not durable")
  assert(history().packCount == recordCount, "history pack count changed on reload")
  assert(history().totalProfitCopper == (profit or recordCount * 740000),
    "history profit changed on reload")
end

local function runCase(recordCount, visible)
  seed(recordCount)
  local ledger = widget("TradePacksLedgerWindow")
  ledger:Show(visible)
  ledger.handlers.OnUpdate(ledger, 0)
  for index = 1, 4 do turnIn() end -- Warm both persistence banks.
  counts = {}
  collectgarbage("collect")
  local started = os.clock()
  turnIn()
  local elapsed = (os.clock() - started) * 1000
  local measured = copy(counts)
  assert(#TradePacksLedger.State.records == recordCount + 5, "sale was not added")
  local latest
  for _, record in ipairs(TradePacksLedger.State.records) do
    if record.id == recordCount + 5 then latest = record end
  end
  assert(latest and latest.payoutCopper == 1000000,
    "preview was not captured by real sale handler")
  -- Reload immediately, without pumping OnUpdate: a successful turn-in must already
  -- be durable, and history recovery must not count that sale twice.
  assertReload(recordCount + 5)
  print(string.format("%4d records, ledger %-6s: %7.2f ms Lua; %d reads (%d records/%d runs), " ..
    "%d writes (%d records/%d runs), %d SetText; immediate reload OK",
    recordCount, visible and "open" or "closed", elapsed,
    measured.reads or 0, measured.reads_records or 0, measured.reads_runs or 0,
    measured.writes or 0, measured.writes_records or 0, measured.writes_runs or 0,
    measured.texts or 0))
  -- Capture the first sale after reload separately from the warmed steady state.
  ledger = widget("TradePacksLedgerWindow")
  ledger:Show(visible)
  ledger.handlers.OnUpdate(ledger, 0)
  counts = {}
  turnIn()
  local cold = copy(counts)
  assertReload(recordCount + 6)
  print(string.format("     first sale after reload: %d reads, %d writes, %d SetText",
    cold.reads or 0, cold.writes or 0, cold.texts or 0))
  return measured, cold
end

for _, visible in ipairs({false, true}) do
  local small, smallCold = runCase(100, visible)
  local large, largeCold = runCase(1000, visible)
  assert(large.reads <= small.reads + 2 and large.reads <= 25,
    "warmed turn-in reads scale with unchanged saved records/runs")
  assert(large.writes <= small.writes + 2 and large.writes <= 25,
    "warmed turn-in writes scale with unchanged saved records/runs")
  assert(largeCold.reads <= smallCold.reads + 2 and largeCold.reads <= 25,
    "first turn-in after reload reads scale with unchanged saved records/runs")
  assert(largeCold.writes <= smallCold.writes + 2 and largeCold.writes <= 25,
    "first turn-in after reload writes scale with unchanged saved records/runs")
  if not visible then
    assert((large.texts or 0) == 0, "turn-in repainted a closed ledger/history window")
  end
end

-- Reproduce the pre-upgrade newest-first disk order without changing history.
local function legacyDescendingBanks(recordCount)
  seed(recordCount)
  local records = {}
  for _, record in ipairs(TradePacksLedger.State.records) do records[#records + 1] = copy(record) end
  table.sort(records, function(a, b) return a.id > b.id end)
  for _, bank in ipairs({"A", "B"}) do
    for index = 1, math.ceil(recordCount / 5) do
      local part = {}
      for row = (index - 1) * 5 + 1, math.min(index * 5, recordCount) do
        part[#part + 1] = copy(records[row])
      end
      saved["TradePacksRecords" .. bank .. "_" .. index] = part
    end
  end
  saved.TradePacksState.recordOrder = nil
end

local function assertOrderedBank(bank, recordCount)
  local previous, loaded = 0, 0
  for index = 1, math.ceil(recordCount / 5) do
    local part = assert(saved["TradePacksRecords" .. bank .. "_" .. index])
    for _, record in ipairs(part) do
      assert(record.id > previous, "migration did not produce ascending disk chunks")
      previous, loaded = record.id, loaded + 1
    end
  end
  assert(loaded == recordCount, "migration lost saved records")
end

legacyDescendingBanks(1000)
local legacy = copy(saved)
loadAddon()
assert(saved.TradePacksState.recordOrder == "id", "migration marker was not committed")
assertOrderedBank("A", 1000)
assertOrderedBank("B", 1000)
counts = {}
turnIn()
print(string.format("1000-record legacy upgrade, first sale: %d reads, %d writes",
  counts.reads, counts.writes))
assert(counts.reads <= 25 and counts.writes <= 25,
  "first post-upgrade sale still rewrites or rereads the ledger")
assertReload(1001)

-- Failure while converting the second bank must preserve the first complete bank,
-- with no completion marker; the next load safely finishes the conversion.
saved = copy(legacy)
local originalBank = saved.TradePacksState.recordBank
failRecordKey = "TradePacksRecords" .. originalBank .. "_1"
loadAddon(true)
failRecordKey = nil
assert(saved.TradePacksState.recordBank ~= originalBank,
  "failed second migration bank replaced the first verified commit")
assert(saved.TradePacksState.recordOrder == nil, "incomplete migration was marked complete")
assertOrderedBank(saved.TradePacksState.recordBank, 1000)
assertReload(1000)
assert(saved.TradePacksState.recordOrder == "id", "migration was not retried after reload")
assertOrderedBank("A", 1000)
assertOrderedBank("B", 1000)

-- Hidden sales defer rendering; opening OPS must display the latest payout at once.
seed(30)
counts = {}
turnIn(nil, 1100000)
assert((counts.texts or 0) == 0, "closed ledger was redrawn")
local opener = widget("TradePacksFloatingButton")
opener.handlers.OnClick(opener)
assert(widget("TradePacksLedgerWindow"):IsVisible(), "OPS did not open the ledger")
assert(widget("TradePacksName1").text == "Auroran Cargo"
  and widget("TradePacksTotal1").text == "110g", "OPS opened with a stale ledger row")
assertReload(31, 31 * 740000 + 100000)

-- Startup rebuilds process-local caches. Its first sale must still commit.
seed(30)
turnIn()
assertReload(31)
turnIn()
assertReload(32)

-- Rejected chunk writes must neither switch the active bank nor count a sale.
local priorBank = saved.TradePacksState.recordBank
local priorHistoryCount = history().packCount
failRecordWrites = true
turnIn()
failRecordWrites = false
assert(#TradePacksLedger.State.records == 32, "failed sale remained in memory")
assert(TradePacksLedger.State.nextId == 33, "failed sale consumed an ID")
assert(saved.TradePacksState.recordBank == priorBank, "failed record save switched banks")
assert(history().packCount == priorHistoryCount, "failed record save changed history")
clock = clock - 10 -- Retry identical data: failed writes must never be trusted by a cache.
turnIn()
assertReload(33)

-- Cached snapshots must not alias mutable record tables or ignore old-row edits.
local oldest
for _, record in ipairs(TradePacksLedger.State.records) do
  if record.id == 1 then oldest = record end
end
assert(oldest)
oldest.costCopper = 270000
oldest.costStatus, oldest.costSource = "manual", "manual"
oldest.materials = {{name = "Persisted test material", count = 2, resourceId = 9999,
  unitPriceCopper = 15000, totalPriceCopper = 30000, pricedAt = clock}}
local alerts = widget("TradePacksDueAlerts")
alerts.handlers.OnClick(alerts) -- Saves the updated existing row through the UI.
alerts.handlers.OnClick(alerts) -- Give both banks the same nested material snapshot.
oldest.materials[1].unitPriceCopper = 16000
oldest.materials[1].totalPriceCopper = 32000
alerts.handlers.OnClick(alerts)
assertReload(33, 33 * 740000 - 10000)
for _, record in ipairs(TradePacksLedger.State.records) do
  if record.id == 1 then
    assert(record.costCopper == 270000, "old-row change was not durable")
    assert(record.materials[1].unitPriceCopper == 16000
      and record.materials[1].totalPriceCopper == 32000,
      "mutable nested material snapshot was not saved")
  end
end

-- A sale remains durable when its history summary fails; startup recovers it once.
priorBank = saved.TradePacksHistoryMeta.bank
failHistoryWrites = true
turnIn()
failHistoryWrites = false
assert(#TradePacksLedger.State.records == 34, "history failure discarded a durable sale")
assert(saved.TradePacksHistoryMeta.bank == priorBank, "failed history summary switched banks")
assertReload(34, 34 * 740000 - 10000)
assertReload(34, 34 * 740000 - 10000)

-- History retries also run with both windows closed, without requiring a reload.
priorBank = saved.TradePacksHistoryMeta.bank
failHistoryWrites = true
turnIn()
failHistoryWrites = false
assert(saved.TradePacksHistoryMeta.bank == priorBank, "failed history summary switched banks")
counts = {}
opener = widget("TradePacksFloatingButton")
for second = 1, 31 do
  clock = clock + 1
  opener.handlers.OnUpdate(opener, 1)
end
assert(history().packCount == 35 and history().totalProfitCopper == 35 * 740000 - 10000,
  "closed-window timer did not retry history save")
assert((counts.texts or 0) == 0, "hidden history retry repainted a window")
assertReload(35, 35 * 740000 - 10000)

-- An older complete history bank can recover its missing sale from ledger IDs.
turnIn()
saved["TradePacksHistory" .. saved.TradePacksHistoryMeta.bank] = nil
assertReload(36, 36 * 740000 - 10000)
assertReload(36, 36 * 740000 - 10000)

-- An incomplete active record bank must remain protected against overwrites.
local damagedKey = "TradePacksRecords" .. saved.TradePacksState.recordBank .. "_1"
saved[damagedKey] = nil
local protectedMeta = copy(saved.TradePacksState)
loadAddon()
counts = {}
turnIn()
assert((counts.writes or 0) == 0, "incomplete ledger was overwritten")
assert(saved.TradePacksState.nextId == protectedMeta.nextId,
  "incomplete ledger metadata was changed")

-- Payout discovery must update history while closed, even without AUTO cost
-- rules. This used to rely on history synchronization during hidden rendering.
seed(2)
local unpriced = TradePacksLedger.State.records[1]
unpriced.payoutCopper = nil
unpriced.payoutItemType, unpriced.payoutName, unpriced.payoutCount = 32103, "Onyx", 2
local alerts = widget("TradePacksDueAlerts")
alerts.handlers.OnClick(alerts)
local auctionHandlers, searchedName, auctionResult = {}, nil, nil
UIEVENT_TYPE = {AUCTION_ITEM_SEARCHED = "AUCTION_ITEM_SEARCHED"}
UIParent.SetEventHandler = function(_, event, handler) auctionHandlers[event] = handler end
X2Auction = {
  SearchAuctionArticle = function(_, _, _, _, _, _, _, name) searchedName = name end,
  GetSearchedItemCount = function() return auctionResult and 1 or 0 end,
  GetSearchedItemInfo = function() return auctionResult end
}
loadAddon()
assert(history().unknownProfitCount == 1)
opener = widget("TradePacksFloatingButton")
opener.handlers.OnClick(opener)
assert(searchedName == "Onyx Archeum Essence", "missing payout was not queued")
widget("TradePacksLedgerWindow"):Show(false)
widget("TradePacksHistoryWindow"):Show(false)
auctionResult = {name = searchedName, directPrice = 40000, stackCount = 1}
auctionHandlers.AUCTION_ITEM_SEARCHED()
assert(history().unknownProfitCount == 0 and history().totalProfitCopper == 560000,
  "payout lookup did not synchronize history with both windows closed")
assertReload(2, 560000)
print("TradePacks turn-in persistence/performance checks passed")
