local ADDON_NAME = "TradePacks"
local ADDON_VERSION = "1.7.6"
local SAVE_KEY = "TradePacksState"
local HISTORY_SAVE_KEY = "TradePacksHistoryState"
local OPENER_SAVE_KEY = "TradePacksOpenerPosition"
local LEDGER_SAVE_KEY = "TradePacksLedgerPosition"
local HISTORY_WINDOW_SAVE_KEY = "TradePacksHistoryWindowPosition"
local RECORDS_CHUNK_PREFIX = "TradePacksRecords_"
local PRICES_SAVE_KEY = "TradePacksPrices"
local COST_RULES_SAVE_KEY = "TradePacksCostRules"
-- SaveData truncates serialized values at 16,383 bytes. Priced records can
-- exceed 1.5 KB each, so 20-record chunks lose entries when reloaded.
local RECORDS_CHUNK_SIZE = 5
local RUNS_CHUNK_SIZE = 10
local UIC_TRADEPACKS = 1301
local ROW_COUNT = 12
local AUCTION_GRADE_ALL = 0
local AUCTION_GRADE_NORMAL = 1
local DEFAULT_DELAY_SECONDS = 8 * 60 * 60
local DETAIL_LINE_COUNT = 8
local ONYX_ITEM_TYPE = 979983
local ONYX_DISPLAY_NAME = "Onyx"
local ONYX_AUCTION_SEARCH_NAME = "Onyx Archeum Essence"
local ONYX_MIN_REASONABLE_UNIT_PRICE = 1 * 10000
local ONYX_MAX_REASONABLE_UNIT_PRICE = 100 * 10000
-- Every id ever seen on an Onyx payout must keep resolving as Onyx. 32103 is the
-- real auction item type (captured as refundItemType since v1.1.1). The large
-- ids are per-item instance ids that older sale events put in the type/name
-- fields; they vary per drop, which is why they appeared to "change per patch".
local ONYX_ITEM_TYPES = {
  [ONYX_ITEM_TYPE] = true,
  [32103] = true,
  [1107253] = true,
  [1001195] = true
}
local LEDGER_WIDTH = 660
local LEDGER_MAX_WIDTH = 990
local LEDGER_HEIGHT = 744 + (ROW_COUNT - 8) * 30
local HISTORY_WIDTH = 360
local HISTORY_HEIGHT = 690
local MAX_DAILY_HISTORY_ROWS = 6
local RESET_CONFIRM_WIDTH = 316
local RESET_CONFIRM_HEIGHT = 154
local WINDOW_SKIN_PATH = "ui/common/default.dds"
local WINDOW_NINEPART_PATH = "ui/common_new/default.dds"
-- Detect the dark-mode UI replacement (isUserDarkMode is provided by utils.lua,
-- loaded first in toc.g). In dark mode the brown "main text" colour is swapped
-- for white so labels and buttons stay readable on the dark background.
local DARK_MODE = (type(isUserDarkMode) == "function") and isUserDarkMode() or false
local TEXT_BROWN = DARK_MODE and { 1, 1, 1, 1 } or { 125 / 255, 76 / 255, 7 / 255, 1 }
local TEXT_RED = { 178 / 255, 42 / 255, 28 / 255, 1 }
local TEXT_GREEN = { 45 / 255, 128 / 255, 52 / 255, 1 }

local API = {
  X2Auction = 51,
  X2Item = 23
}

local OBJECT = {
  Window = 0,
  Label = 1,
  Button = 2,
  EditboxMultiline = 4,
  Drawable = 6,
  ColorDrawable = 7,
  NinePartDrawable = 8,
  ThreePartDrawable = 9,
  ImageDrawable = 10,
  IconDrawable = 11,
  TextStyle = 13,
  Textbox = 39,
  EmptyWidget = 46
}

for _, id in pairs(API) do
  pcall(function()
    ADDON:ImportAPI(id)
  end)
end

for _, id in pairs(OBJECT) do
  pcall(function()
    ADDON:ImportObject(id)
  end)
end

local runtime = {
  filter = "all",
  dateFilter = "all",
  packFilter = nil,
  payoutFilter = nil,
  unpricedOnly = false,
  ledgerWidth = LEDGER_WIDTH,
  visibleRowCount = ROW_COUNT,
  runPage = 1,
  dueCheckElapsed = 0,
  dueAlertsArmed = false,
  sortKey = "soldAt",
  sortDir = "desc",
  page = 1,
  priceLookups = {},
  pendingSaleTerms = nil,
  latestSellPreview = nil,
  latestSellByName = {},
  latestBuyByName = {},
  selectedRecordId = nil,
  windowVisible = false,
  uiUpdateElapsed = 0,
  dailyCheckElapsed = 0,
  auctionRefreshPending = false,
  auctionRefreshDelay = 0,
  loadingElapsed = 0,
  loadingDots = 0,
  auctionLoading = false,
  auctionStatus = nil,
  auctionQueue = {},
  activeAuctionKey = nil,
  namePriceLookups = {},
  lastAuctionSearchKey = nil
}

runtime.sameData = function(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) == "number" then
    if a == b then return true end
    -- The client serializes addon numbers through single-precision floats.
    -- Exact equality rejects valid round-trips (notably timestamps, large
    -- profit totals, and scaled widget positions), so allow one float step.
    local magnitude = math.max(math.abs(a), math.abs(b))
    if magnitude == 0 then return false end
    local floatStep = 2 ^ (math.floor(math.log(magnitude) / math.log(2)) - 23)
    return math.abs(a - b) <= math.max(0.000001, floatStep + 0.000001)
  end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not runtime.sameData(v, b[k]) then return false end
  end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Only this helper writes these chunk keys. Keep the independently loaded,
-- verified copy for this session so unchanged chunks need no native I/O.
-- Clear a changed key before writing: a failed/partial write must never leave
-- a trusted cache entry. Bank pointers still commit only after verification.
runtime.verifiedChunks = {}
runtime.saveVerifiedChunk = function(key, value, failure)
  local cached = runtime.verifiedChunks[key]
  if cached and runtime.sameData(value, cached) then return end
  local saved = not cached and ADDON:LoadData(key) or nil
  if not runtime.sameData(value, saved) then
    runtime.verifiedChunks[key] = nil
    ADDON:SaveData(key, value)
    saved = ADDON:LoadData(key)
  end
  if not runtime.sameData(value, saved) then error(failure) end
  runtime.verifiedChunks[key] = saved
end

local ui = {
  rows = {}
}

local function safeCall(fn, ...)
  if type(fn) ~= "function" then
    return false, nil
  end
  return pcall(fn, ...)
end

local function nowSeconds()
  local ok, value = pcall(function()
    return ADDON:GetCurrentTimeStamp()
  end)

  if ok and type(value) == "number" then
    if value > 9999999999 then
      value = math.floor(value / 1000)
    end
    return math.floor(value)
  end

  if os and os.time then
    return os.time()
  end

  return 0
end

runtime.saveErrorAt = {}
runtime.reportSaveError = function(kind, err)
  local now = nowSeconds()
  if runtime.saveErrorAt[kind] and now - runtime.saveErrorAt[kind] < 60 then return end
  runtime.saveErrorAt[kind] = now
  pcall(function() ADDON:ChatLog("TradePacks: " .. kind .. " save failed: " .. tostring(err)) end)
end

local function getUIScaleFactor()
  if UIParent and type(UIParent.GetUIScale) == "function" then
    local ok, scale = pcall(function()
      return UIParent:GetUIScale()
    end)
    if ok and type(scale) == "number" and scale > 0 then
      return scale
    end
  end
  return 1
end

runtime.widgetSuffix = tostring(nowSeconds())

local function widgetName(base)
  return base .. runtime.widgetSuffix
end

local function shallowCopy(src)
  local dst = {}
  if type(src) ~= "table" then
    return dst
  end
  for key, value in pairs(src) do
    dst[key] = value
  end
  return dst
end

local function defaultState()
  return {
    version = 2,
    nextId = 1,
    records = {},
    settings = {
      costPresets = {
        ["Auroran Cargo"] = 260000
      },
      opener = {
        x = 24,
        y = 260
      }
    },
      prices = {}
  }
end

local function defaultHistoryState()
  return {
    version = 1,
    packCount = 0,
    totalProfitCopper = 0,
    unknownProfitCount = 0,
    packCounts = {},
    profitByPack = {},
    favoritePack = "-",
    favoriteCount = 0,
    migratedFromRecords = false,
    dailyProfitCopper = 0,
    dailyUnknownCount = 0,
    dailyStartTime = 0,
    dailyHistory = {},
    runs = {},
    lastRecordId = 0,
    dirtyContribs = {}
  }
end

local state = ADDON:LoadData(SAVE_KEY)
if type(state) ~= "table" then
  state = defaultState()
end

runtime.historyMeta = ADDON:LoadData("TradePacksHistoryMeta")
runtime.historyBank = type(runtime.historyMeta) == "table" and runtime.historyMeta.bank or nil
runtime.historyMapFields = {"packCounts", "profitByPack", "dailyHistory", "dirtyContribs"}
runtime.historyMapChunkSize = 10
runtime.loadHistoryBank = function(bank)
  local summary = ADDON:LoadData("TradePacksHistory" .. bank)
  if type(summary) ~= "table" then return nil end
  if summary.chunkedFields == nil then return summary end
  if type(summary.chunkedFields) ~= "table" then return nil end
  for _, field in ipairs(runtime.historyMapFields) do
    local manifest = summary.chunkedFields[field]
    local count = type(manifest) == "table" and tonumber(manifest.count)
    local chunks = type(manifest) == "table" and tonumber(manifest.chunks)
    if not count or not chunks or count < 0 or count ~= math.floor(count)
        or chunks ~= math.ceil(count / runtime.historyMapChunkSize) then return nil end
    local map, loaded = {}, 0
    for i = 1, chunks do
      local part = ADDON:LoadData("TradePacksHistory" .. bank .. field .. "_" .. i)
      local expected = math.min(runtime.historyMapChunkSize, count - loaded)
      if type(part) ~= "table" or #part ~= expected then return nil end
      for _, entry in ipairs(part) do
        if type(entry) ~= "table" or entry.key == nil or entry.value == nil
            or map[entry.key] ~= nil then return nil end
        map[entry.key] = entry.value
        loaded = loaded + 1
      end
    end
    if loaded ~= count then return nil end
    summary[field] = map
  end
  return summary
end
local historyState = runtime.historyBank and runtime.loadHistoryBank(runtime.historyBank)
if runtime.historyBank and type(historyState) ~= "table" then
  local previousBank = runtime.historyBank == "A" and "B" or "A"
  historyState = runtime.loadHistoryBank(previousBank)
  if type(historyState) == "table" then runtime.historyBank = previousBank end
  pcall(function() ADDON:ChatLog("TradePacks: active history save is missing; loaded the previous copy when available.") end)
end
if type(historyState) ~= "table" then historyState = ADDON:LoadData(HISTORY_SAVE_KEY) end
if type(historyState) ~= "table" then historyState = defaultHistoryState() end

state.version = 2

runtime.recordChunkCount = tonumber(state.recordChunkCount) or 0
runtime.recordsLoadIncomplete = runtime.recordChunkCount > 2000
if runtime.recordChunkCount > 2000 then runtime.recordChunkCount = 2000 end
if runtime.recordChunkCount > 0 then
  local loaded = {}
  local prefix = state.recordBank and ("TradePacksRecords" .. state.recordBank .. "_") or RECORDS_CHUNK_PREFIX
  for chunkIndex = 1, runtime.recordChunkCount do
    local chunk = ADDON:LoadData(prefix .. chunkIndex)
    if type(chunk) == "table" then
      for _, record in ipairs(chunk) do
        loaded[#loaded + 1] = record
      end
    else
      runtime.recordsLoadIncomplete = true
    end
  end
  if tonumber(state.recordCount) and #loaded ~= tonumber(state.recordCount) then
    runtime.recordsLoadIncomplete = true
  end
  state.records = loaded
end
if type(state.records) ~= "table" then
  state.records = {}
end

state.prices = ADDON:LoadData(PRICES_SAVE_KEY) or state.prices
runtime.laborPriceCache = ADDON:LoadData("TradePacksLaborPrices")
if type(runtime.laborPriceCache) ~= "table" then runtime.laborPriceCache = {} end
local costRulesMeta = ADDON:LoadData(COST_RULES_SAVE_KEY .. "Meta")
runtime.costRulesBank = type(costRulesMeta) == "table" and costRulesMeta.bank or nil
runtime.costRules = runtime.costRulesBank and ADDON:LoadData(COST_RULES_SAVE_KEY .. runtime.costRulesBank)
if type(runtime.costRules) ~= "table" and runtime.costRulesBank then
  local previousBank = runtime.costRulesBank == "A" and "B" or "A"
  runtime.costRules = ADDON:LoadData(COST_RULES_SAVE_KEY .. previousBank)
  if type(runtime.costRules) == "table" then runtime.costRulesBank = previousBank end
end
if type(runtime.costRules) ~= "table" then
  runtime.costRules = ADDON:LoadData(COST_RULES_SAVE_KEY)
end
if type(runtime.costRules) ~= "table" then runtime.costRules = {} end
for _, kind in ipairs({"transport", "labor", "materials"}) do
  if type(runtime.costRules[kind]) ~= "table" then runtime.costRules[kind] = {} end
end
if type(state.settings) ~= "table" then
  state.settings = {}
end
if type(state.settings.costPresets) ~= "table" then
  state.settings.costPresets = {}
end
state.settings.dueAlerts = state.settings.dueAlerts == true and true or nil
if not state.settings.costPresets["Auroran Cargo"] then
  state.settings.costPresets["Auroran Cargo"] = 260000
end
if type(state.settings.opener) ~= "table" then
  state.settings.opener = {
    x = 24,
    y = 260
  }
end
if type(state.prices) ~= "table" then
  state.prices = {}
end
if type(state.nextId) ~= "number" then
  state.nextId = 1
  for _, record in ipairs(state.records) do
    if type(record.id) == "number" and record.id >= state.nextId then
      state.nextId = record.id + 1
    end
  end
end

historyState.version = 1
historyState.packCount = tonumber(historyState.packCount) or 0
historyState.totalProfitCopper = tonumber(historyState.totalProfitCopper) or 0
historyState.unknownProfitCount = tonumber(historyState.unknownProfitCount) or 0
if type(historyState.packCounts) ~= "table" then
  historyState.packCounts = {}
end
historyState.favoritePack = tostring(historyState.favoritePack or ""):gsub("^%s+", ""):gsub("%s+$", "")
if historyState.favoritePack == "" then
  historyState.favoritePack = "-"
end
historyState.favoriteCount = tonumber(historyState.favoriteCount) or 0
historyState.dailyProfitCopper = tonumber(historyState.dailyProfitCopper) or 0
historyState.dailyUnknownCount = tonumber(historyState.dailyUnknownCount) or 0
historyState.dailyStartTime = tonumber(historyState.dailyStartTime) or 0
historyState.migratedFromRecords = historyState.migratedFromRecords == true
if type(historyState.dailyHistory) ~= "table" then
  historyState.dailyHistory = {}
end
historyState.dailyMigrated = historyState.dailyMigrated == true
if type(historyState.runs) ~= "table" then
  historyState.runs = {}
end
-- Run summaries have their own chunked save. The copy in historyState is a
-- short recovery fallback for older saves and for a damaged active run bank.
runtime.runMeta = ADDON:LoadData("TradePacksRunsMeta")
runtime.loadRunBank = function(bank)
  local manifest = ADDON:LoadData("TradePacksRunsManifest" .. bank)
  if type(manifest) ~= "table" then return nil end
  local count, chunks = tonumber(manifest.count), tonumber(manifest.chunks)
  if not count or not chunks or count < 0 or chunks ~= math.ceil(count / RUNS_CHUNK_SIZE) then return nil end
  local runs = {}
  for i = 1, chunks do
    local part = ADDON:LoadData("TradePacksRuns" .. bank .. "_" .. i)
    if type(part) ~= "table" then return nil end
    local expected = math.min(RUNS_CHUNK_SIZE, count - (i - 1) * RUNS_CHUNK_SIZE)
    if #part ~= expected then return nil end
    for _, run in ipairs(part) do
      if type(run) ~= "table" or run.id == nil then return nil end
      runs[#runs + 1] = run
    end
  end
  if #runs ~= count then return nil end
  return runs
end
local savedRunBank = historyState.runBank
if savedRunBank ~= "A" and savedRunBank ~= "B" then
  savedRunBank = type(runtime.runMeta) == "table" and runtime.runMeta.bank or nil
end
if savedRunBank == "A" or savedRunBank == "B" then
  runtime.runsBank = savedRunBank
  local runs = runtime.loadRunBank(runtime.runsBank)
  if not runs then
    local previousBank = runtime.runsBank == "A" and "B" or "A"
    local previousRuns = runtime.loadRunBank(previousBank)
    local previousHistoryBank = runtime.historyBank == "A" and "B" or "A"
    local previousSummary = runtime.loadHistoryBank(previousHistoryBank)
    if previousRuns and type(previousSummary) == "table"
      and previousSummary.runBank == previousBank
      and type(previousSummary.dailyHistory) == "table" then
      historyState = previousSummary
      runtime.historyBank = previousHistoryBank
      runtime.runsBank = previousBank
      runs = previousRuns
      pcall(function() ADDON:ChatLog("TradePacks: loaded the previous complete history and run copy.") end)
    end
  end
  if runs then
    historyState.runs = runs
  else
    runtime.runHistoryLoadIncomplete = true
    pcall(function() ADDON:ChatLog("TradePacks: run history is incomplete; run saves are disabled to protect it.") end)
  end
end
if type(historyState.dirtyContribs) ~= "table" then
  historyState.dirtyContribs = {}
end
if type(historyState.profitByPack) ~= "table" then
  historyState.profitByPack = {}
end

for _, record in ipairs(state.records) do
  if record.cargoName == "Auroran Cargo" then
    local existingName = type(record.payoutName) == "string" and record.payoutName:lower() or ""
    local nameIsOnyx = existingName == ""
      or existingName:find("onyx", 1, true) ~= nil
      or tonumber(existingName) ~= nil
    local itemType = tonumber(record.payoutItemType)
    local typeIsOnyx = itemType == nil
      or ONYX_ITEM_TYPES[itemType] == true
    if nameIsOnyx and typeIsOnyx then
      record.payoutItemType = record.payoutItemType or ONYX_ITEM_TYPE
      record.payoutName = record.payoutName or ONYX_DISPLAY_NAME
      -- Repair Onyx records locked at an out-of-range price while the Onyx
      -- sanity check was bypassed (regression in a prior session). PAID records
      -- are never touched: their profit is final.
      local locked = tonumber(record.payoutUnitPriceCopper)
      if not record.paid and locked
        and (locked < ONYX_MIN_REASONABLE_UNIT_PRICE or locked > ONYX_MAX_REASONABLE_UNIT_PRICE) then
        record.payoutUnitPriceCopper = nil
        record.payoutPricedAt = nil
      end
    elseif not typeIsOnyx and existingName:find("onyx", 1, true) ~= nil then
      -- Repair records that an earlier migration mislabelled "Onyx" even though
      -- the sale event captured a different payout item (e.g. Dragon Essence
      -- Stabilizer). The real name is restored from the item type after the
      -- game API helpers are defined (see backfill near the end of this file).
      record.payoutName = nil
    end
    record.costCopper = record.costCopper or state.settings.costPresets["Auroran Cargo"]
    record.costStatus = record.costStatus or "preset"
    record.costSource = record.costSource or "preset"
  elseif record.costCopper and not record.costStatus then
    record.costStatus = "snapshot"
  elseif not record.costCopper and not record.costStatus then
    record.costStatus = "unknown"
  end
end

do
  local cleaned = {}
  for _, record in ipairs(state.records) do
    local name = type(record.cargoName) == "string" and record.cargoName:match("^%s*(.-)%s*$") or ""
    if name ~= "" and name ~= "?" and name ~= "Unknown Cargo" then
      cleaned[#cleaned + 1] = record
    end
  end
  state.records = cleaned
end

if not state.settings.removedDebugMockRecord then
  -- One-time removal of the fake record a leftover debug block (removed in
  -- v1.1.2) injected on every load, identified by the exact field combination
  -- the debug code wrote. Must only ever run once: 32106 is the REAL Dragon
  -- Essence Stabilizer item type, so once genuine records get their names
  -- backfilled they would match this filter too.
  state.settings.removedDebugMockRecord = true
  local cleaned = {}
  for _, record in ipairs(state.records) do
    local isInjectedMock = record.cargoName == "Auroran Cargo"
      and record.payoutName == "Dragon Essence Stabilizer"
      and tonumber(record.payoutItemType) == 32106
      and record.payoutCount == 1
      and record.cargoItemType == nil
      and not record.paid
    if not isInjectedMock then
      cleaned[#cleaned + 1] = record
    end
  end
  state.records = cleaned
end

local function saveState(recordOrder)
  if runtime.recordsLoadIncomplete then
    pcall(function() ADDON:ChatLog("TradePacks: saved records are incomplete; refusing to overwrite them. Back up the profile data.") end)
    return false
  end
  local ok, err = pcall(function()
    local leanRecords = {}
    for _, record in ipairs(state.records) do
      local lean = {}
      for k, v in pairs(record) do
        lean[k] = v
      end
      -- Materials are normally re-derived from the static recipe on load, so we
      -- drop them to keep saves lean. But once a record carries snapshotted
      -- per-material prices, those live ONLY here -- the recipe has no prices --
      -- so persist a compact copy for priced records to keep the Details
      -- breakdown intact across reloads.
      lean.materials = nil
      if type(record.materials) == "table" then
        local hasPrice = false
        for _, material in ipairs(record.materials) do
          if type(material) == "table"
            and (tonumber(material.unitPriceCopper) or tonumber(material.totalPriceCopper)) then
            hasPrice = true
            break
          end
        end
        if hasPrice then
          local copied = {}
          for _, material in ipairs(record.materials) do
            if type(material) == "table" then
              copied[#copied + 1] = {
                name = material.name,
                count = tonumber(material.count),
                resourceId = material.resourceId or material.id,
                unitPriceCopper = tonumber(material.unitPriceCopper),
                totalPriceCopper = tonumber(material.totalPriceCopper),
                pricedAt = tonumber(material.pricedAt)
              }
            end
          end
          lean.materials = copied
        end
      end
      lean.iconPath = nil
      lean.iconCoord = nil
      -- Delivery is fixed at eight hours; discard obsolete per-record delay
      -- and manual receipt metadata as old records are next saved.
      lean.delaySeconds = nil
      lean.received = nil
      lean.receivedAt = nil
      leanRecords[#leanRecords + 1] = lean
    end

    -- Display order is newest first, but disk chunks must be append-stable.
    -- Otherwise inserting one new sale shifts and rewrites every old chunk.
    table.sort(leanRecords, function(a, b)
      return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    local chunkCount = math.ceil(#leanRecords / RECORDS_CHUNK_SIZE)
    local nextBank = state.recordBank == "A" and "B" or "A"
    local prefix = "TradePacksRecords" .. nextBank .. "_"
    for chunkIndex = 1, chunkCount do
      local chunk = {}
      local startIdx = (chunkIndex - 1) * RECORDS_CHUNK_SIZE + 1
      local endIdx = math.min(chunkIndex * RECORDS_CHUNK_SIZE, #leanRecords)
      for i = startIdx, endIdx do
        chunk[#chunk + 1] = leanRecords[i]
      end
      local key = prefix .. chunkIndex
      runtime.saveVerifiedChunk(key, chunk,
        "record chunk " .. chunkIndex .. " did not read back completely")
    end

    if not runtime.sameData(state.prices or {}, ADDON:LoadData(PRICES_SAVE_KEY)) then
      ADDON:SaveData(PRICES_SAVE_KEY, state.prices or {})
    end

    local meta = {
      version = state.version,
      nextId = state.nextId,
      settings = state.settings,
      recordBank = nextBank,
      recordOrder = recordOrder or state.recordOrder,
      recordChunkCount = chunkCount,
      recordCount = #leanRecords
    }
    ADDON:SaveData(SAVE_KEY, meta)
    local committed = ADDON:LoadData(SAVE_KEY)
    -- Verify the record pointer and the new alert setting. Other settings can
    -- contain scaled widget coordinates that the client rounds on storage.
    if type(committed) ~= "table" or committed.recordBank ~= nextBank
      or committed.recordOrder ~= meta.recordOrder
      or tonumber(committed.recordCount) ~= #leanRecords
      or tonumber(committed.recordChunkCount) ~= chunkCount
      or tonumber(committed.nextId) ~= tonumber(state.nextId)
      or type(committed.settings) ~= "table"
      or (committed.settings.dueAlerts == true) ~= (state.settings.dueAlerts == true) then
      error("record metadata did not read back completely")
    end
    state.recordBank = nextBank
    state.recordOrder = meta.recordOrder
  end)
  if not ok then
    runtime.reportSaveError("record", err)
  end
  return ok
end

-- Legacy saves may already contain truncated chunks. Preserve those original
-- keys, then commit the complete records that remain to the new verified bank.
if runtime.recordsLoadIncomplete and not state.recordBank then
  local expected = tonumber(state.recordCount) or 0
  state.settings.legacyRecovery = {expected = expected, recovered = #state.records,
    at = nowSeconds()}
  runtime.recordsLoadIncomplete = false
  if saveState() then
    pcall(function() ADDON:ChatLog("TradePacks: recovered " .. #state.records .. " of "
      .. expected .. " legacy records; original chunks were kept for repair.") end)
  else
    runtime.recordsLoadIncomplete = true
  end
end
if runtime.recordsLoadIncomplete then
  pcall(function() ADDON:ChatLog("TradePacks: record save is incomplete; ledger writes are disabled until data is repaired.") end)
end

runtime.saveRuns = function()
  if runtime.runHistoryLoadIncomplete then return false end
  local ok, err = pcall(function()
    local bank = runtime.runsBank == "A" and "B" or "A"
    local runs = historyState.runs or {}
    local chunks = math.ceil(#runs / RUNS_CHUNK_SIZE)
    for i = 1, chunks do
      local part = {}
      for j = (i - 1) * RUNS_CHUNK_SIZE + 1, math.min(i * RUNS_CHUNK_SIZE, #runs) do
        part[#part + 1] = runs[j]
      end
      local key = "TradePacksRuns" .. bank .. "_" .. i
      runtime.saveVerifiedChunk(key, part,
        "run chunk " .. i .. " did not read back completely")
    end
    local manifest = {count = #runs, chunks = chunks}
    local manifestKey = "TradePacksRunsManifest" .. bank
    ADDON:SaveData(manifestKey, manifest)
    if not runtime.sameData(manifest, ADDON:LoadData(manifestKey)) then
      error("run manifest did not read back")
    end
    return bank
  end)
  if not ok then
    runtime.reportSaveError("run", err)
  end
  return ok and err or nil
end

runtime.saveHistoryState = function()
  -- The history key is also subject to the client's per-value size limit.
  -- Daily rows beyond 60 days are no longer displayed; keep all-time totals.
  local today = math.floor((nowSeconds() - 2 * 3600) / 86400)
  for day in pairs(historyState.dailyHistory or {}) do
    if tonumber(day) and tonumber(day) < today - 59 then
      historyState.dailyHistory[day] = nil
    end
  end
  local ok, err = pcall(function()
    local runBank = runtime.saveRuns()
    if not runBank then error("run history could not be saved") end
    local bank = runtime.historyBank == "A" and "B" or "A"
    local key = "TradePacksHistory" .. bank
    local summary = shallowCopy(historyState)
    summary.runBank = runBank
    summary.chunkedFields = {}
    for _, field in ipairs(runtime.historyMapFields) do
      local entries = {}
      for mapKey, value in pairs(historyState[field] or {}) do
        entries[#entries + 1] = {key = mapKey, value = value}
      end
      table.sort(entries, function(a, b) return tostring(a.key) < tostring(b.key) end)
      local chunks = math.ceil(#entries / runtime.historyMapChunkSize)
      for i = 1, chunks do
        local part = {}
        for j = (i - 1) * runtime.historyMapChunkSize + 1,
            math.min(i * runtime.historyMapChunkSize, #entries) do
          part[#part + 1] = entries[j]
        end
        local partKey = key .. field .. "_" .. i
        runtime.saveVerifiedChunk(partKey, part,
          "history " .. field .. " chunk " .. i .. " did not read back completely")
      end
      summary.chunkedFields[field] = {count = #entries, chunks = chunks}
      summary[field] = nil
    end
    summary.runs = {}
    ADDON:SaveData(key, summary)
    local saved = ADDON:LoadData(key)
    if type(saved) ~= "table"
      or not runtime.sameData(tonumber(saved.packCount), tonumber(historyState.packCount))
      or not runtime.sameData(tonumber(saved.totalProfitCopper), tonumber(historyState.totalProfitCopper))
      or type(saved.chunkedFields) ~= "table" or type(saved.runs) ~= "table" then
      error("history did not read back completely")
    end
    if not runtime.sameData(summary, saved) then
      error("history fields changed during save")
    end
    ADDON:SaveData("TradePacksRunsMeta", {bank = runBank})
    local runMeta = ADDON:LoadData("TradePacksRunsMeta")
    if type(runMeta) ~= "table" or runMeta.bank ~= runBank then
      error("run pointer did not read back")
    end
    ADDON:SaveData("TradePacksHistoryMeta", {bank = bank})
    local meta = ADDON:LoadData("TradePacksHistoryMeta")
    if type(meta) ~= "table" or meta.bank ~= bank then
      error("history commit did not read back")
    end
    runtime.historyBank = bank
    runtime.runsBank = runBank
    historyState.runBank = runBank
  end)
  runtime.historyDirty = not ok
  runtime.nextHistoryRetryAt = not ok and (nowSeconds() + 30) or nil
  if not ok then
    if not tostring(err):find("run history could not be saved", 1, true) then
      runtime.reportSaveError("history", err)
    end
  end
  return ok
end

local function loadOpenerPosition()
  local saved = ADDON:LoadData(OPENER_SAVE_KEY)
  if type(saved) == "table" then
    local x = tonumber(saved.x)
    local y = tonumber(saved.y)
    if x and y then
      return x, y
    end
  end

  local opener = state.settings.opener
  return tonumber(opener and opener.x) or 24, tonumber(opener and opener.y) or 260
end

local function saveOpenerPosition(x, y)
  x = tonumber(x)
  y = tonumber(y)
  if not x or not y then
    return
  end

  state.settings.opener.x = x
  state.settings.opener.y = y
  pcall(function()
    ADDON:ClearData(OPENER_SAVE_KEY)
  end)
  pcall(function()
    ADDON:SaveData(OPENER_SAVE_KEY, {
      x = x,
      y = y
    })
  end)
  saveState()
end

local function loadLedgerPosition()
  local saved = ADDON:LoadData(LEDGER_SAVE_KEY)
  if type(saved) == "table" then
    local x = tonumber(saved.x)
    local y = tonumber(saved.y)
    if x and y then
      return x, y
    end
  end
  return nil, nil
end

local function saveLedgerPosition(x, y)
  x = tonumber(x)
  y = tonumber(y)
  if not x or not y then
    return
  end

  pcall(function()
    ADDON:ClearData(LEDGER_SAVE_KEY)
  end)
  pcall(function()
    ADDON:SaveData(LEDGER_SAVE_KEY, {
      x = x,
      y = y
    })
  end)
end

local function loadHistoryWindowPosition()
  local saved = ADDON:LoadData(HISTORY_WINDOW_SAVE_KEY)
  if type(saved) == "table" then
    local x = tonumber(saved.x)
    local y = tonumber(saved.y)
    if x and y then
      return x, y
    end
  end
  return nil, nil
end

local function saveHistoryWindowPosition(x, y)
  x = tonumber(x)
  y = tonumber(y)
  if not x or not y then
    return
  end
  pcall(function()
    ADDON:ClearData(HISTORY_WINDOW_SAVE_KEY)
  end)
  pcall(function()
    ADDON:SaveData(HISTORY_WINDOW_SAVE_KEY, { x = x, y = y })
  end)
end

local function normalizeKey(value)
  if value == nil then
    return nil
  end
  return tostring(value)
end

local function normalizeNameKey(name)
  if name == nil then
    return nil
  end
  name = tostring(name):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  name = name:gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if name == "" then
    return nil
  end
  return "name:" .. name
end

local function trim(text)
  if text == nil then
    return ""
  end
  return tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
end

local function compactText(text)
  text = trim(text)
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return text
end

local function isUnpricedAuctionName(name)
  name = compactText(name):lower()
  return name == "gilda star" or name == "gilda stars"
end

local function isIgnoredCostMaterial(material)
  return type(material) == "table" and isUnpricedAuctionName(material.name)
end

local function parseMoney(text)
  if type(text) == "number" then
    return math.floor(text)
  end
  if type(text) ~= "string" then
    return nil
  end

  local raw = compactText(text):lower():gsub(",", ""):gsub("%s+", "")
  if raw == "" then
    return nil
  end

  if raw:match("^%-?%d+$") then
    return tonumber(raw)
  end

  local gold = tonumber(raw:match("(%d+)g")) or tonumber(raw:match("(%d+)gold")) or 0
  local silver = tonumber(raw:match("(%d+)s")) or tonumber(raw:match("(%d+)silver")) or 0
  local copper = tonumber(raw:match("(%d+)c")) or tonumber(raw:match("(%d+)copper")) or 0
  local value = gold * 10000 + silver * 100 + copper

  if value == 0 then
    return nil
  end
  return value
end

local function formatMoney(copper)
  copper = tonumber(copper)
  if not copper then
    return "?"
  end

  local sign = ""
  if copper < 0 then
    sign = "-"
    copper = -copper
  end

  copper = math.floor(copper + 0.5)
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local copperOnly = copper % 100

  if gold > 0 then
    if copperOnly > 0 then
      return string.format("%s%dg %ds %dc", sign, gold, silver, copperOnly)
    end
    if silver > 0 then
      return string.format("%s%dg %ds", sign, gold, silver)
    end
    return string.format("%s%dg", sign, gold)
  end

  if silver > 0 then
    if copperOnly > 0 then
      return string.format("%s%ds %dc", sign, silver, copperOnly)
    end
    return string.format("%s%ds", sign, silver)
  end

  return string.format("%s%dc", sign, copperOnly)
end

local function formatDuration(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds <= 0 then
    return "ready"
  end

  seconds = math.floor(seconds)
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)

  if hours > 0 then
    return string.format("%dh %02dm", hours, minutes)
  end
  return string.format("%dm", minutes)
end

local function getPrice(itemType, forceOnyxLimit)
  local key = normalizeKey(itemType)
  if not key then
    return nil
  end
  local entry = state.prices[key]
  if type(entry) == "table" then
    local copper = tonumber(entry.copper)
    if copper and copper > 0 then
      local updatedAt = tonumber(entry.updatedAt)
      if not updatedAt or nowSeconds() - updatedAt > (6 * 60 * 60) then
        return nil
      end
      if forceOnyxLimit or ONYX_ITEM_TYPES[tonumber(itemType)] == true then
        if copper < ONYX_MIN_REASONABLE_UNIT_PRICE or copper > ONYX_MAX_REASONABLE_UNIT_PRICE then
          return nil
        end
      end
      return copper
    end
  end
  return nil
end

local function getNamedPrice(name)
  local key = normalizeNameKey(name)
  if not key then
    return nil
  end
  return getPrice(key, false)
end

runtime.transportItems = {
  fuel = "Eco-Friendly Fuel",
  grease = "Axle Grease"
}

-- Compare fixed-amount labor restorers by auction cost per recovered point.
-- Unlisted items contribute no quote; variable-yield rechargers are omitted.
runtime.laborItems = {
  {name = "Worker's Compensation", labor = 1000},
  {name = "Worker's Compensation: 500", labor = 500},
  {name = "Worker's Compensation: 50", labor = 50},
  {name = "Superior Worker's Compensation: 500 LP", labor = 500},
  {name = "Prime Worker's Compensation: 1,000 LP", labor = 1000},
  {name = "Labor Reward: 500", labor = 500},
  {name = "Labor Reward: 1000", labor = 1000}
}

runtime.isLaborPriceKey = function(key)
  for _, item in ipairs(runtime.laborItems) do
    if normalizeNameKey(item.name) == key then return true end
  end
  return false
end

-- The general price map can exceed SaveData's per-value limit. Keep the few
-- labor quotes separately so a restart cannot silently discard their rates.
for _, item in ipairs(runtime.laborItems) do
  local key = normalizeNameKey(item.name)
  local saved = runtime.laborPriceCache[key]
  local current = state.prices[key]
  if type(saved) == "table" and (tonumber(saved.copper) or 0) > 0
      and (type(current) ~= "table"
        or (tonumber(saved.updatedAt) or 0) > (tonumber(current.updatedAt) or 0)) then
    state.prices[key] = saved
  end
end

runtime.saveLaborPrice = function(key)
  if not runtime.isLaborPriceKey(key) then return true end
  local previous = runtime.laborPriceCache[key]
  runtime.laborPriceCache[key] = state.prices[key]
  local ok, err = pcall(function()
    ADDON:SaveData("TradePacksLaborPrices", runtime.laborPriceCache)
    if not runtime.sameData(runtime.laborPriceCache, ADDON:LoadData("TradePacksLaborPrices")) then
      error("labor auction prices did not read back completely")
    end
  end)
  if not ok then
    runtime.laborPriceCache[key] = previous
    runtime.reportSaveError("labor prices", err)
  end
  return ok
end

for _, item in ipairs(runtime.laborItems) do
  local key = normalizeNameKey(item.name)
  local current = state.prices[key]
  local saved = runtime.laborPriceCache[key]
  if type(current) == "table" and (tonumber(current.copper) or 0) > 0
      and (type(saved) ~= "table"
        or (tonumber(current.updatedAt) or 0) > (tonumber(saved.updatedAt) or 0)) then
    runtime.saveLaborPrice(key)
  end
end

runtime.costRuleAuctionPrice = function(name)
  local current = getNamedPrice(name)
  if current then return current end
  local entry = state.prices[normalizeNameKey(name)]
  local last = type(entry) == "table" and tonumber(entry.copper) or nil
  return last and last > 0 and last or nil
end

runtime.cheapestLaborItem = function()
  local cheapest
  for _, item in ipairs(runtime.laborItems) do
    local freshPrice = getNamedPrice(item.name)
    local price = freshPrice or runtime.costRuleAuctionPrice(item.name)
    if price and price > 0 and (not cheapest
        or (freshPrice and not cheapest.fresh)
        or ((freshPrice ~= nil) == cheapest.fresh
          and price * cheapest.labor < cheapest.price * item.labor)) then
      cheapest = {name = item.name, labor = item.labor, price = price,
        fresh = freshPrice ~= nil}
    end
  end
  return cheapest
end

runtime.ruleCost = function(kind, packName)
  local rules = runtime.costRules[kind]
  local rule = rules and rules[packName]
  if type(rule) ~= "table" then return nil end
  if kind == "materials" then
    local total = 0
    for _, item in ipairs(rule.items or {}) do
      local price = (item.auto and runtime.costRuleAuctionPrice(item.name)) or tonumber(item.price)
      total = total + (tonumber(item.qty) or 0) * (price or 0)
    end
    return math.floor(total)
  end
  if kind == "labor" then
    local points = tonumber(rule.points) or 0
    if points <= 0 then return 0 end
    local item = runtime.cheapestLaborItem()
    return item and math.floor(points * item.price / item.labor + 0.5) or nil
  end
  local total = 0
  for key, itemName in pairs(runtime.transportItems) do
    local quantity = tonumber(rule[key .. "Qty"]) or 0
    local price = (rule[key .. "Auto"] and runtime.costRuleAuctionPrice(itemName))
      or tonumber(rule[key .. "Price"])
    total = total + quantity * (price or 0)
  end
  return math.floor(total)
end

runtime.applyCostRules = function(record)
  if type(record) ~= "table" then return end
  local transport = runtime.ruleCost("transport", record.cargoName)
  local labor = runtime.ruleCost("labor", record.cargoName)
  local materials = runtime.ruleCost("materials", record.cargoName)
  if transport ~= nil then record.transportCostCopper = transport end
  if type(runtime.costRules.labor[record.cargoName]) == "table" then
    record.laborCostCopper = labor
  end
  if materials ~= nil then
    record.costCopper = materials
    record.materialCostCopper = nil
    record.costStatus, record.costSource = "preset", "rule"
    record.materials = {}
    local rule = runtime.costRules.materials[record.cargoName]
    for _, item in ipairs(rule.items or {}) do
      local price = (item.auto and runtime.costRuleAuctionPrice(item.name)) or tonumber(item.price)
      record.materials[#record.materials + 1] = {
        name = item.name, count = item.qty, resourceId = item.resourceId,
        unitPriceCopper = price, totalPriceCopper = price and price * item.qty or nil,
        pricedAt = item.auto and nowSeconds() or nil
      }
    end
    for _, item in ipairs(rule.boundItems or {}) do
      record.materials[#record.materials + 1] = {
        name = item.name, count = item.qty, resourceId = item.resourceId
      }
    end
  end
end

local function getItemName(info)
  if type(info) ~= "table" then
    return nil
  end
  if type(info.item) == "table" and type(info.item.name) == "string" then
    return compactText(info.item.name)
  end
  if type(info.itemInfo) == "table" and type(info.itemInfo.name) == "string" then
    return compactText(info.itemInfo.name)
  end
  if type(info.name) == "string" then
    return compactText(info.name)
  end
  return nil
end

local function getItemType(info)
  if type(info) ~= "table" then
    return nil
  end
  if type(info.item) == "table" and info.item.itemType then
    return info.item.itemType
  end
  if type(info.itemInfo) == "table" and info.itemInfo.itemType then
    return info.itemInfo.itemType
  end
  return info.itemType or info.type
end

-- Payout item types whose names the client API fails to resolve in-game.
local KNOWN_ITEM_NAMES = {
  [32106] = "Dragon Essence Stabilizer"
}

local function getItemNameByType(itemType)
  itemType = tonumber(itemType)
  if not itemType or itemType <= 0 then
    return nil
  end
  if KNOWN_ITEM_NAMES[itemType] then
    return KNOWN_ITEM_NAMES[itemType]
  end
  if not X2Item or type(X2Item.GetItemInfoByType) ~= "function" then
    return nil
  end

  local ok, info = pcall(function()
    return X2Item:GetItemInfoByType(itemType)
  end)
  if ok and type(info) == "table" and type(info.name) == "string" then
    return compactText(info.name)
  end
  return nil
end

local resourceNameByIdCache

local function resourceNameById(resourceId)
  resourceId = tonumber(resourceId)
  if not resourceId then
    return nil
  end

  if not resourceNameByIdCache then
    resourceNameByIdCache = {}
    if type(Resources) == "table" then
      for name, ids in pairs(Resources) do
        if type(ids) == "table" and ids[1] then
          resourceNameByIdCache[tonumber(ids[1])] = name
        end
      end
    end
  end

  return resourceNameByIdCache[resourceId]
end

local function getPackMaterials(packName)
  packName = compactText(packName)
  if packName == "" then
    return nil
  end

  local requiredResources = nil
  if packName:find("Fertilizer Specialty", 1, true) and type(Fertilizer_Specialty) == "table" then
    requiredResources = Fertilizer_Specialty
  elseif type(Nuia_Specialty) == "table" and Nuia_Specialty[packName] then
    requiredResources = Nuia_Specialty[packName]
  elseif type(Haranya_Specialty) == "table" and Haranya_Specialty[packName] then
    requiredResources = Haranya_Specialty[packName]
  elseif type(Auroria_Specialty) == "table" and Auroria_Specialty[packName] then
    requiredResources = Auroria_Specialty[packName]
  end

  if type(requiredResources) ~= "table" or type(requiredResources[1]) ~= "table" or type(requiredResources[2]) ~= "table" then
    return nil
  end

  local materials = {}
  local counts = requiredResources[1]
  local resourceIds = requiredResources[2]
  for index = 1, #counts do
    local name = resourceNameById(resourceIds[index])
    local count = tonumber(counts[index])
    if name and count and count > 0 then
      table.insert(materials, {
        name = name,
        count = count,
        resourceId = resourceIds[index]
      })
    end
  end

  if #materials == 0 then
    return nil
  end
  return materials
end

-- Rates previews use today's configured costs, never a historical sale's locked
-- snapshot. This reader does not start auction searches, change records, or save.
runtime.rateCostEstimate = function(packName)
  local result = {missingComponents = {}}
  local function amount(value)
    value = tonumber(value)
    return value and value == value and value >= 0 and value < math.huge and value or nil
  end
  local function missing(component, reason)
    result.missingComponents[#result.missingComponents + 1] = component .. ": " .. reason
  end
  local function auctionPrice(name)
    local price = amount(runtime.costRuleAuctionPrice(name))
    if price and price > 0 then
      result.usesCachedPrices = true
      if not getNamedPrice(name) then result.stalePrices = true end
      return price
    end
  end
  local function itemCost(name, quantity, manualPrice, auto)
    local qty = amount(quantity)
    if not qty then return nil, "invalid amount for " .. tostring(name) end
    if qty == 0 then return 0 end
    local price = amount(manualPrice)
    if auto then
      local quote = auctionPrice(name)
      -- An unset AUTO price is commonly stored as zero by the editor. Treat it
      -- as missing, while still honoring an explicit zero in manual mode.
      price = quote or (price and price > 0 and price or nil)
    end
    if price == nil then return nil, "price missing for " .. tostring(name) end
    return qty * price
  end
  if type(packName) ~= "string" or compactText(packName) == "" then
    missing("Pack", "select a pack")
    result.missing = table.concat(result.missingComponents, "; ")
    return result
  end
  packName = compactText(packName)

  local materialRule = runtime.costRules.materials[packName]
  if type(materialRule) == "table" then
    if type(materialRule.items) ~= "table" then
      missing("Materials", "invalid saved rule")
    else
      local total, complete = 0, true
      for _, item in ipairs(materialRule.items) do
        local value, reason
        if type(item) ~= "table" then reason = "invalid saved item"
        elseif isIgnoredCostMaterial(item) then value = 0
        else value, reason = itemCost(item.name, item.qty, item.price, item.auto == true) end
        if value == nil then complete = false; missing("Materials", reason)
        else total = total + value end
      end
      if complete then result.materialsCopper = math.floor(total) end
    end
  elseif state.settings.costPresets[packName] ~= nil then
    result.materialsCopper = amount(state.settings.costPresets[packName])
    if result.materialsCopper == nil then missing("Materials", "invalid preset") end
  else
    -- Read every recipe entry directly: getPackMaterials deliberately omits
    -- unknown resource names for the ledger, but a preview must not underprice
    -- a recipe when its resource catalog is incomplete.
    local recipe
    if packName:find("Fertilizer Specialty", 1, true) and type(Fertilizer_Specialty) == "table" then
      recipe = Fertilizer_Specialty
    elseif type(Nuia_Specialty) == "table" and Nuia_Specialty[packName] then
      recipe = Nuia_Specialty[packName]
    elseif type(Haranya_Specialty) == "table" and Haranya_Specialty[packName] then
      recipe = Haranya_Specialty[packName]
    elseif type(Auroria_Specialty) == "table" and Auroria_Specialty[packName] then
      recipe = Auroria_Specialty[packName]
    end
    if type(recipe) ~= "table" or type(recipe[1]) ~= "table"
        or type(recipe[2]) ~= "table" or #recipe[1] == 0 then
      missing("Materials", "not configured")
    else
      local total, complete = 0, true
      for index, qty in ipairs(recipe[1]) do
        local name = resourceNameById(recipe[2][index])
        local value, reason
        if not name then reason = "unknown recipe resource " .. tostring(recipe[2][index])
        elseif isIgnoredCostMaterial({name = name}) then value = 0
        else value, reason = itemCost(name, qty, nil, true) end
        if value == nil then complete = false; missing("Materials", reason)
        else total = total + value end
      end
      if complete then result.materialsCopper = math.floor(total) end
    end
  end

  local transportRule = runtime.costRules.transport[packName]
  if type(transportRule) ~= "table" then
    missing("Transport", "not configured")
  else
    local total, complete = 0, true
    for _, key in ipairs({"fuel", "grease"}) do
      local value, reason = itemCost(runtime.transportItems[key], transportRule[key .. "Qty"],
        transportRule[key .. "Price"], transportRule[key .. "Auto"] == true)
      if value == nil then complete = false; missing("Transport", reason)
      else total = total + value end
    end
    if complete then result.transportCopper = math.floor(total) end
  end

  local laborRule = runtime.costRules.labor[packName]
  if type(laborRule) ~= "table" then
    missing("Labor", "not configured")
  else
    local points = amount(laborRule.points)
    if points == nil then missing("Labor", "invalid amount")
    elseif points == 0 then result.laborCopper = 0
    else
      local item = runtime.cheapestLaborItem()
      if not item or not amount(item.price) then missing("Labor", "waiting for auction price")
      else
        result.laborCopper = math.floor(points * item.price / item.labor + 0.5)
        result.laborSource = item.name
        result.usesCachedPrices = true
        if not item.fresh then result.stalePrices = true end
      end
    end
  end
  if #result.missingComponents > 0 then
    result.missing = table.concat(result.missingComponents, "; ")
  else
    result.totalCopper = result.materialsCopper + result.transportCopper + result.laborCopper
  end
  return result
end

local function copyMaterialList(materials)
  local copied = {}
  if type(materials) ~= "table" then
    return copied
  end

  for _, material in ipairs(materials) do
    if type(material) == "table" then
      table.insert(copied, {
        name = material.name,
        count = tonumber(material.count),
        resourceId = material.resourceId or material.id,
        unitPriceCopper = tonumber(material.unitPriceCopper),
        totalPriceCopper = tonumber(material.totalPriceCopper),
        pricedAt = tonumber(material.pricedAt)
      })
    end
  end
  return copied
end

local function ensureRecordMaterials(record)
  if type(record) ~= "table" then
    return nil
  end
  if type(record.materials) == "table" and #record.materials > 0 then
    return record.materials
  end

  local materials = getPackMaterials(record.cargoName)
  if materials then
    record.materials = copyMaterialList(materials)
    return record.materials
  end
  return nil
end

local function trySnapshotMaterialCost(record)
  if type(record) ~= "table" then
    return false, false
  end
  if record.costStatus == "manual" or record.costSource == "manual"
    or record.costStatus == "preset" or record.costSource == "preset" then
    return true, false
  end
  if record.costStatus == "snapshot" and tonumber(record.materialCostCopper) and tonumber(record.costCopper) then
    return true, false
  end

  local materials = ensureRecordMaterials(record)
  if not materials then
    if not record.costCopper and record.costStatus ~= "unknown" then
      record.costStatus = "unknown"
      record.costSource = "folio"
      return false, true
    end
    return false, false
  end

  local total = 0
  local allKnown = true
  local changed = false
  local oldestPricedAt = nil
  local unknownPriceAge = false

  for _, material in ipairs(materials) do
    local count = tonumber(material.count) or 0
    if isIgnoredCostMaterial(material) then
      if material.unitPriceCopper ~= nil or material.totalPriceCopper ~= nil then
        material.unitPriceCopper = nil
        material.totalPriceCopper = nil
        changed = true
      end
    else
      local unitPrice = tonumber(material.unitPriceCopper) or getNamedPrice(material.name)
      if unitPrice and unitPrice > 0 and count > 0 then
        local totalPrice = unitPrice * count
        if material.unitPriceCopper ~= unitPrice then
          material.unitPriceCopper = unitPrice
          changed = true
        end
        if material.totalPriceCopper ~= totalPrice then
          material.totalPriceCopper = totalPrice
          changed = true
        end
        local sourceAt = tonumber(material.pricedAt)
        if not sourceAt then
          local entry = state.prices[normalizeNameKey(material.name)]
          if type(entry) == "table" and tonumber(entry.copper) == unitPrice then
            sourceAt = tonumber(entry.updatedAt)
          end
          if sourceAt then material.pricedAt = sourceAt; changed = true end
        end
        if sourceAt then
          oldestPricedAt = oldestPricedAt and math.min(oldestPricedAt, sourceAt) or sourceAt
        else
          unknownPriceAge = true
        end
        total = total + totalPrice
      else
        allKnown = false
      end
    end
  end

  if allKnown then
    local sourceAt = unknownPriceAge and nil or oldestPricedAt
    if record.materialCostCopper ~= total or record.costCopper ~= total
      or record.costStatus ~= "snapshot" or record.materialPricedAt ~= sourceAt then
      record.materialCostCopper = total
      record.costCopper = total
      record.costStatus = "snapshot"
      record.costSource = "folio"
      record.materialPricedAt = sourceAt
      changed = true
    end
    return true, changed
  end

  if record.costStatus ~= "pricing" or record.costSource ~= "folio" then
    record.costStatus = "pricing"
    record.costSource = "folio"
    changed = true
  end
  return false, changed
end

local function initializeRecordCost(record)
  if type(record) ~= "table" then
    return
  end

  if record.costStatus == "manual" then return end
  local preset = state.settings.costPresets[record.cargoName]
  if preset then
    record.costCopper = preset
    record.costStatus = "preset"
    record.costSource = "preset"
    return
  end

  if ensureRecordMaterials(record) then
    trySnapshotMaterialCost(record)
  elseif not record.costCopper then
    record.costStatus = "unknown"
    record.costSource = "folio"
  end
end

local function tryCompleteMaterialCosts()
  local changed = false
  for _, record in ipairs(state.records) do
    if not record.archived and record.costStatus ~= "snapshot"
      and record.costStatus ~= "preset" and record.costStatus ~= "manual" then
      local _, recordChanged = trySnapshotMaterialCost(record)
      changed = changed or recordChanged
    end
  end
  if changed then
    saveState()
  end
  return changed
end

local function getIconInfo(info)
  if type(info) ~= "table" then
    return nil, nil
  end

  local function readIcon(source)
    if type(source) ~= "table" then
      return nil, nil
    end
    if type(source.icon) == "string" and source.icon ~= "" then
      return source.icon, source.iconCoord or source.iconCoords
    end
    if type(source.iconPath) == "string" and source.iconPath ~= "" then
      return source.iconPath, source.iconCoord or source.iconCoords
    end
    return nil, nil
  end

  local iconPath, iconCoord = readIcon(info.supply)
  if iconPath then
    return iconPath, iconCoord
  end

  iconPath, iconCoord = readIcon(info.item)
  if iconPath then
    return iconPath, iconCoord
  end

  iconPath, iconCoord = readIcon(info.itemInfo)
  if iconPath then
    return iconPath, iconCoord
  end

  return readIcon(info)
end

local function parseRefundText(refund)
  if type(refund) ~= "string" then
    return nil, nil
  end

  refund = compactText(refund)
  local name, count = refund:match("^(.-)%s+[xX]%s*(%d+)$")
  if name then
    return compactText(name), tonumber(count)
  end

  count, name = refund:match("^(%d+)%s+[xX]%s*(.-)$")
  if name then
    return compactText(name), tonumber(count)
  end

  return refund, nil
end

local function snapshotSpecialtyInfo(info)
  if type(info) ~= "table" then
    return nil
  end

  local refund = info.refund or info.noEventRefund
  local payoutName, payoutCount = parseRefundText(refund)
  local payoutCopper = parseMoney(info.payoutCopper or info.refundCopper or info.money or info.refund)
  local basePayoutCopper = parseMoney(info.basePayoutCopper or info.noEventRefund)
  local payoutItemType = tonumber(info.refundItemType)
  if payoutItemType and payoutItemType <= 0 then
    payoutItemType = nil
  end
  if payoutItemType then
    payoutCopper = nil
    payoutName = payoutName or getItemNameByType(payoutItemType)
  elseif payoutCopper then
    payoutName = nil
    payoutCount = nil
  end

  local iconPath, iconCoord = getIconInfo(info)

  return {
    cargoName = getItemName(info),
    cargoItemType = getItemType(info),
    payoutName = payoutName,
    payoutItemType = payoutItemType,
    payoutCount = payoutItemType and (tonumber(info.refundItemCount) or tonumber(payoutCount) or tonumber(info.count)) or nil,
    payoutCopper = payoutCopper,
    basePayoutCopper = basePayoutCopper,
    ratio = tonumber(info.ratio),
    sellerRatio = tonumber(info.sellerRatio),
    freshnessRatio = tonumber(info.freshnessRatio),
    iconPath = iconPath,
    iconCoord = iconCoord
  }
end

local function cacheSellContent(payload)
  if type(payload) ~= "table" then
    return false
  end

  local list = payload
  if payload.item or payload.itemInfo or payload.name or payload.refund or payload.noEventRefund then
    list = { payload }
  end

  local cached = false
  for _, info in pairs(list) do
    local snapshot = snapshotSpecialtyInfo(info)
    if snapshot then
      runtime.latestSellPreview = snapshot
      if snapshot.cargoName then
        runtime.latestSellByName[snapshot.cargoName] = snapshot
      end
      cached = true
    end
  end
  return cached
end

local function cacheBuyContent(payload)
  if type(payload) ~= "table" then
    return
  end

  local list = payload
  if payload.item or payload.itemInfo then
    list = { payload }
  end

  for _, info in pairs(list) do
    local name = getItemName(info)
    if name then
      local iconPath, iconCoord = getIconInfo(info)
      runtime.latestBuyByName[name] = {
        cargoName = name,
        cargoItemType = getItemType(info),
        iconPath = iconPath,
        iconCoord = iconCoord
      }
    end
  end
end

local function mergeRecordData(record, source)
  if type(source) ~= "table" then
    return
  end

  record.cargoName = record.cargoName or source.cargoName
  record.cargoItemType = record.cargoItemType or source.cargoItemType
  record.payoutName = record.payoutName or source.payoutName
  record.payoutItemType = record.payoutItemType or source.payoutItemType
  record.payoutCount = record.payoutCount or source.payoutCount
  record.payoutCopper = record.payoutCopper or source.payoutCopper
  record.basePayoutCopper = record.basePayoutCopper or source.basePayoutCopper
  record.ratio = record.ratio or source.ratio
  record.sellerRatio = record.sellerRatio or source.sellerRatio
  record.freshnessRatio = record.freshnessRatio or source.freshnessRatio
  record.iconPath = record.iconPath or source.iconPath
  record.iconCoord = record.iconCoord or source.iconCoord
  if type(record.materials) ~= "table" and type(source.materials) == "table" then
    record.materials = copyMaterialList(source.materials)
  end
  record.materialCostCopper = record.materialCostCopper or source.materialCostCopper
  record.costStatus = record.costStatus or source.costStatus
  record.costSource = record.costSource or source.costSource
end

local function sortRecords()
  table.sort(state.records, function(a, b)
    local aSoldAt = tonumber(a.soldAt) or 0
    local bSoldAt = tonumber(b.soldAt) or 0
    if aSoldAt ~= bSoldAt then
      return aSoldAt > bSoldAt
    end
    return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
  end)
end

local function findRecord(recordId)
  for index, record in ipairs(state.records) do
    if record.id == recordId then
      return record, index
    end
  end
  return nil, nil
end

-- The game mails payment eight hours after turn-in. A legacy paid marker is
-- retained only for the payout snapshot; it does not change the deadline.
local function getRecordStatus(record)
  local soldAt = tonumber(record.soldAt) or 0
  if nowSeconds() >= soldAt + DEFAULT_DELAY_SECONDS then return "Delivered" end
  return "Waiting"
end

local refreshUi
local updateFilterButtons
local startAuctionRefresh
local recordPayoutValue
local resolvePayoutItemType
local payoutSearchName
local resolveRecordIcon
local handleAuctionItemSearched
local handleLowestPrice
local readSearchedAuctionResults
local recordProfit
local trySnapshotPayoutValue
local tryCompletePayoutValues

local function markDueRecords()
  local changed = false
  local now = nowSeconds()
  local dueNames = {}
  local dueRecords = {}
  local earlyRecords = {}
  for _, record in ipairs(state.records) do
    if not record.archived then
      local soldAt = tonumber(record.soldAt) or 0
      if now < soldAt + DEFAULT_DELAY_SECONDS and record.paid then
        -- Older versions could mark a pack paid before eight hours using a
        -- captured delay. Let it transition at the actual fixed deadline.
        record.paid = false
        earlyRecords[#earlyRecords + 1] = record
        changed = true
      elseif now >= soldAt + DEFAULT_DELAY_SECONDS and not record.paid then
        record.paid = true
        -- Freeze the payout at delivery so later price changes never shift profit.
        if trySnapshotPayoutValue then
          trySnapshotPayoutValue(record)
        end
        dueNames[#dueNames + 1] = record.cargoName or "pack"
        dueRecords[#dueRecords + 1] = record
        changed = true
      end
    end
  end

  if changed then
    if saveState() then
      if #dueNames > 0 and runtime.dueAlertsArmed and state.settings.dueAlerts then
        local text = #dueNames == 1 and (dueNames[1] .. " payment was delivered")
          or (tostring(#dueNames) .. " trade pack payments were delivered")
        pcall(function() ADDON:ChatLog("TradePacks: " .. text .. ".") end)
      end
    else
      for _, record in ipairs(dueRecords) do record.paid = false end
      for _, record in ipairs(earlyRecords) do record.paid = true end
    end
  end
  runtime.dueAlertsArmed = true
end

runtime.payoutFilterKey = function(record)
  if tonumber(record.payoutCopper) then return "money" end
  local itemType = tonumber(record.payoutItemType)
  local name = tostring(record.payoutName or ""):lower()
  if ONYX_ITEM_TYPES[itemType] or name:find("onyx", 1, true) then return "onyx" end
  if itemType and itemType > 0 then return "item:" .. tostring(itemType) end
  if name ~= "" and not tonumber(name) then return "name:" .. name end
  return "unknown"
end

local function recordPassesFilter(record)
  if runtime.filter == "archived" then
    if not record.archived then return false end
  elseif record.archived then
    return false
  end
  if runtime.filter == "pending" and getRecordStatus(record) ~= "Waiting" then
    return false
  end
  if runtime.filter == "ready" and getRecordStatus(record) ~= "Delivered" then
    return false
  end
  if runtime.packFilter and record.cargoName ~= runtime.packFilter then
    return false
  end
  if runtime.payoutFilter and runtime.payoutFilterKey(record) ~= runtime.payoutFilter then
    return false
  end
  if runtime.dateFilter ~= "all" then
    local day = tonumber(record.dayKeyUtc2) or math.floor(((tonumber(record.soldAt) or 0) - 2 * 3600) / 86400)
    local today = math.floor((nowSeconds() - 2 * 3600) / 86400)
    if runtime.dateFilter == "today" and day ~= today then return false end
    if runtime.dateFilter == "yesterday" and day ~= today - 1 then return false end
    if runtime.dateFilter == "week" and (not day or day < today - 6) then return false end
  end
  if runtime.unpricedOnly and recordProfit and recordProfit(record) ~= nil then
    return false
  end
  return true
end

local function filteredRecords()
  local list = {}
  for _, record in ipairs(state.records) do
    if recordPassesFilter(record) then
      table.insert(list, record)
    end
  end
  return list
end

local function ledgerIsVisible()
  if ui.window and type(ui.window.IsVisible) == "function" then
    local ok, visible = pcall(function()
      return ui.window:IsVisible()
    end)
    if ok then
      return visible == true
    end
  end
  return runtime.windowVisible == true
end

local function normalizedElapsed(elapsed)
  elapsed = tonumber(elapsed) or 0
  if elapsed < 0 then
    return 0
  end
  if elapsed > 10 then
    return elapsed / 1000
  end
  return elapsed
end

local function setAuctionLoading(visible)
  runtime.auctionLoading = visible == true
  if runtime.auctionLoading then
    runtime.loadingElapsed = 0
    runtime.loadingDots = 0
  end

  if ui.loadingLabel then
    if runtime.auctionLoading then
      ui.loadingLabel:SetText("Prices Are Loading")
    end
    pcall(function()
      ui.loadingLabel:Show(runtime.auctionLoading)
    end)
  end
end

local auctionHandlersRegistered = false
local function registerAuctionHandlers()
  if auctionHandlersRegistered then
    return
  end
  if not UIParent or type(UIParent.SetEventHandler) ~= "function" or not UIEVENT_TYPE then
    return
  end
  auctionHandlersRegistered = true

  if UIEVENT_TYPE.AUCTION_ITEM_SEARCHED then
    local previousAuctionSearchHandler = _G and _G.OnAuctionItemSearched
    pcall(function()
      UIParent:SetEventHandler(UIEVENT_TYPE.AUCTION_ITEM_SEARCHED, function(...)
        if type(previousAuctionSearchHandler) == "function" then
          pcall(previousAuctionSearchHandler, ...)
        end
        if type(handleAuctionItemSearched) == "function" then
          handleAuctionItemSearched(...)
        end
      end)
    end)
  end

  if UIEVENT_TYPE.AUCTION_LOWEST_PRICE then
    pcall(function()
      UIParent:SetEventHandler(UIEVENT_TYPE.AUCTION_LOWEST_PRICE, function(...)
        if type(handleLowestPrice) == "function" then
          handleLowestPrice(...)
        end
      end)
    end)
  end
end

local function updateLoadingLabel(elapsed)
  if not runtime.auctionLoading or not ui.loadingLabel then
    return
  end

  runtime.loadingElapsed = (runtime.loadingElapsed or 0) + normalizedElapsed(elapsed)
  if runtime.loadingElapsed < 0.5 then
    return
  end

  runtime.loadingElapsed = 0
  runtime.loadingDots = ((runtime.loadingDots or 0) % 3) + 1
  local text = "Prices Are Loading"
  for _ = 1, runtime.loadingDots do
    text = text .. "."
  end
  ui.loadingLabel:SetText(text)
end

local function historyPackName(record)
  local name = compactText(record and record.cargoName)
  if name == "" or name == "?" then
    return "Unknown Cargo"
  end
  return name
end

runtime.resetHistoryTotals = function()
  historyState.packCount = 0
  historyState.totalProfitCopper = 0
  historyState.unknownProfitCount = 0
  historyState.packCounts = {}
  historyState.profitByPack = {}
  historyState.favoritePack = "-"
  historyState.favoriteCount = 0
  historyState.dailyProfitCopper = 0
  historyState.dailyUnknownCount = 0
  historyState.dailyStartTime = 0
  historyState.dailyHistory = {}
  historyState.dailyMigrated = true
  historyState.runs = {}
  historyState.dirtyContribs = {}
  historyState.lastRecordId = (tonumber(state.nextId) or 1) - 1
end

-- 00:00 UTC-2 = 02:00 UTC
local UTC_MINUS_2_OFFSET = 2 * 3600

local function currentDayKeyUtc2()
  return math.floor((nowSeconds() - UTC_MINUS_2_OFFSET) / 86400)
end

local function recordDayKeyUtc2(record)
  local k = tonumber(record.dayKeyUtc2)
  if k then return k end
  -- fallback for records created before dayKeyUtc2 was added
  return math.floor(((tonumber(record.soldAt) or 0) - UTC_MINUS_2_OFFSET) / 86400)
end

local function dayKeyLabel(dayKey)
  local diff = currentDayKeyUtc2() - dayKey
  if diff == 0 then return "Today" end
  if diff == 1 then return "Yesterday" end
  return tostring(diff) .. " days ago"
end

runtime.recomputeDailyProfit = function()
  if runtime.recordsLoadIncomplete and not historyState.dailyMigrated then return end
  local todayKey = currentDayKeyUtc2()
  historyState.dailyStartTime = todayKey
  if not historyState.dailyMigrated then
    -- Older daily totals only covered records still in the ledger. Migrate once;
    -- already cleared records cannot be recovered from that format.
    historyState.dailyHistory = {}
    for _, record in ipairs(state.records) do
      local dk = recordDayKeyUtc2(record)
      local day = historyState.dailyHistory[dk] or {profitCopper = 0, unknownCount = 0, packCount = 0}
      day.packCount = day.packCount + 1
      local profit = recordProfit and recordProfit(record)
      if profit then day.profitCopper = day.profitCopper + profit
      else day.unknownCount = day.unknownCount + 1 end
      historyState.dailyHistory[dk] = day
    end
    historyState.dailyMigrated = true
    runtime.saveHistoryState()
  end
  local today = historyState.dailyHistory[todayKey] or {}
  historyState.dailyProfitCopper = tonumber(today.profitCopper) or 0
  historyState.dailyUnknownCount = tonumber(today.unknownCount) or 0
end

runtime.checkDailyReset = function()
  if historyState.dailyStartTime < currentDayKeyUtc2() then
    runtime.recomputeDailyProfit()
    runtime.saveHistoryState()
  end
end

local function addRecordToHistory(record, prepareOnly)
  if type(record) ~= "table" then
    return
  end

  local runs = historyState.runs
  local last = runs[#runs]
  local soldAt = tonumber(record.soldAt) or nowSeconds()
  local newRun = false
  if not last or soldAt - (tonumber(last.lastAt) or 0) > 30 * 60 or soldAt < (tonumber(last.lastAt) or 0) then
    last = {id = tostring(soldAt) .. ":" .. tostring(record.id), startedAt = soldAt,
      lastAt = soldAt, count = 0, profitCopper = 0, unknownCount = 0}
    newRun = true
  end
  record.runId = last.id
  local profit = recordProfit and recordProfit(record)
  record.historyProfitContrib = profit or "unknown"
  -- Prepare all record fields before the single durable ledger commit. History
  -- totals change only after it succeeds; lastRecordId recovers an interrupted
  -- history save from that already-persisted sale on the next load.
  if prepareOnly then return end
  if newRun then runs[#runs + 1] = last end
  historyState.lastRecordId = math.max(tonumber(historyState.lastRecordId) or 0, tonumber(record.id) or 0)
  last.lastAt = soldAt
  last.count = last.count + 1
  local packName = historyPackName(record)
  local dk = recordDayKeyUtc2(record)
  local day = historyState.dailyHistory[dk] or {profitCopper = 0, unknownCount = 0, packCount = 0}
  day.packCount = day.packCount + 1
  historyState.dailyHistory[dk] = day
  local packCount = (tonumber(historyState.packCounts[packName]) or 0) + 1
  historyState.packCounts[packName] = packCount
  historyState.packCount = (tonumber(historyState.packCount) or 0) + 1

  if packCount > (tonumber(historyState.favoriteCount) or 0) then
    historyState.favoritePack = packName
    historyState.favoriteCount = packCount
  end

  if profit then
    day.profitCopper = day.profitCopper + profit
    last.profitCopper = last.profitCopper + profit
    historyState.totalProfitCopper = (tonumber(historyState.totalProfitCopper) or 0) + profit
    record.historyProfitContrib = profit
    local bucket = historyState.profitByPack[packName] or { profitCopper = 0, count = 0 }
    bucket.profitCopper = (tonumber(bucket.profitCopper) or 0) + profit
    bucket.count = (tonumber(bucket.count) or 0) + 1
    historyState.profitByPack[packName] = bucket
  else
    day.unknownCount = day.unknownCount + 1
    last.unknownCount = last.unknownCount + 1
    historyState.unknownProfitCount = (tonumber(historyState.unknownProfitCount) or 0) + 1
    record.historyProfitContrib = "unknown"
  end
end

local function syncRecordHistoryProfit(record)
  if type(record) ~= "table" then
    return false
  end
  local contributionKey = tostring(record.id)
  if (tonumber(record.id) or 0) <= (tonumber(historyState.statsResetThroughId) or 0) then return false end
  local prev = historyState.dirtyContribs[contributionKey] or record.historyProfitContrib
  if prev == nil then
    return false
  end
  local curr = recordProfit and recordProfit(record)
  -- Keep the per-pack profit bucket in lock-step with totalProfitCopper. Local to
  -- this function, so it adds no top-level local (200-local ceiling).
  local packName = historyPackName(record)
  local day = historyState.dailyHistory[recordDayKeyUtc2(record)]
  local run = runtime.runIndex and runtime.runIndex[record.runId]
  local function adjustDay(deltaCopper, deltaUnknown)
    if day then
      day.profitCopper = (tonumber(day.profitCopper) or 0) + deltaCopper
      day.unknownCount = math.max(0, (tonumber(day.unknownCount) or 0) + deltaUnknown)
    end
    if run then
      run.profitCopper = (tonumber(run.profitCopper) or 0) + deltaCopper
      run.unknownCount = math.max(0, (tonumber(run.unknownCount) or 0) + deltaUnknown)
    end
  end
  local function adjustPack(deltaCopper, deltaCount)
    local bucket = historyState.profitByPack[packName] or { profitCopper = 0, count = 0 }
    bucket.profitCopper = (tonumber(bucket.profitCopper) or 0) + deltaCopper
    bucket.count = math.max(0, (tonumber(bucket.count) or 0) + deltaCount)
    historyState.profitByPack[packName] = bucket
  end
  if prev == "unknown" then
    if type(curr) == "number" then
      historyState.unknownProfitCount = math.max(0, (tonumber(historyState.unknownProfitCount) or 0) - 1)
      historyState.totalProfitCopper = (tonumber(historyState.totalProfitCopper) or 0) + curr
      adjustPack(curr, 1)
      adjustDay(curr, -1)
      record.historyProfitContrib = curr
      historyState.dirtyContribs[contributionKey] = curr
      return true
    end
    return false
  end
  if type(prev) == "number" then
    if type(curr) == "number" then
      if curr ~= prev then
        historyState.totalProfitCopper = (tonumber(historyState.totalProfitCopper) or 0) + (curr - prev)
        adjustPack(curr - prev, 0)
        adjustDay(curr - prev, 0)
        record.historyProfitContrib = curr
        historyState.dirtyContribs[contributionKey] = curr
        return true
      end
      return false
    end
    historyState.totalProfitCopper = (tonumber(historyState.totalProfitCopper) or 0) - prev
    historyState.unknownProfitCount = (tonumber(historyState.unknownProfitCount) or 0) + 1
    adjustPack(-prev, -1)
    adjustDay(-prev, 1)
    record.historyProfitContrib = "unknown"
    historyState.dirtyContribs[contributionKey] = "unknown"
    return true
  end
  return false
end

local function syncAllRecordsHistoryProfit()
  local changed = false
  runtime.runIndex = {}
  for _, run in ipairs(historyState.runs) do runtime.runIndex[run.id] = run end
  for _, record in ipairs(state.records) do
    if syncRecordHistoryProfit(record) then
      changed = true
    end
  end
  if changed or (runtime.historyDirty and nowSeconds() >= (runtime.nextHistoryRetryAt or 0)) then
    if runtime.saveHistoryState() then saveState() end
  end
  return changed
end

-- A failed history write must retry even when neither ledger window is open.
runtime.retryHistorySave = function()
  if runtime.historyDirty and nowSeconds() >= (runtime.nextHistoryRetryAt or 0) then
    if runtime.saveHistoryState() then saveState() end
  end
end

runtime.saveCostRules = function()
  local ok, err = pcall(function()
    local nextBank = runtime.costRulesBank == "A" and "B" or "A"
    ADDON:SaveData(COST_RULES_SAVE_KEY .. nextBank, runtime.costRules)
    if not runtime.sameData(runtime.costRules, ADDON:LoadData(COST_RULES_SAVE_KEY .. nextBank)) then
      error("cost rules did not read back completely")
    end
    ADDON:SaveData(COST_RULES_SAVE_KEY .. "Meta", {bank = nextBank})
    local committed = ADDON:LoadData(COST_RULES_SAVE_KEY .. "Meta")
    if type(committed) ~= "table" or committed.bank ~= nextBank then
      error("cost rules pointer did not read back")
    end
    runtime.costRulesBank = nextBank
  end)
  if not ok then runtime.reportSaveError("cost rules", err) end
  return ok
end

runtime.commitCostRule = function(kind, packName, rule)
  if not packName or not runtime.costRules[kind] then return false end
  local oldRule = runtime.costRules[kind][packName]
  local oldCosts = {}
  runtime.costRules[kind][packName] = rule
  for _, record in ipairs(state.records) do
    if record.cargoName == packName then
      oldCosts[#oldCosts + 1] = {record, record.transportCostCopper, record.laborCostCopper,
        record.costCopper, record.materialCostCopper, record.costStatus,
        record.costSource, record.materials}
      runtime.applyCostRules(record)
    end
  end
  if not runtime.saveCostRules() or not saveState() then
    runtime.costRules[kind][packName] = oldRule
    for _, entry in ipairs(oldCosts) do
      entry[1].transportCostCopper, entry[1].laborCostCopper = entry[2], entry[3]
      entry[1].costCopper, entry[1].materialCostCopper = entry[4], entry[5]
      entry[1].costStatus, entry[1].costSource, entry[1].materials = entry[6], entry[7], entry[8]
    end
    runtime.saveCostRules()
    return false
  end
  syncAllRecordsHistoryProfit()
  if refreshUi then refreshUi() end
  return true
end

runtime.refreshAutoTransportCosts = function()
  local changed = false
  for _, record in ipairs(state.records) do
    local rule = runtime.costRules.transport[record.cargoName]
    if type(rule) == "table" and (rule.fuelAuto or rule.greaseAuto) then
      local cost = runtime.ruleCost("transport", record.cargoName)
      if cost ~= record.transportCostCopper then
        record.transportCostCopper = cost
        changed = true
      end
    end
  end
  return changed
end

runtime.refreshAutoLaborCosts = function(priceKey)
  local relevant = false
  for _, item in ipairs(runtime.laborItems) do
    if normalizeNameKey(item.name) == priceKey then relevant = true; break end
  end
  if not relevant then return false end
  local changed = false
  for _, record in ipairs(state.records) do
    if type(runtime.costRules.labor[record.cargoName]) == "table" then
      local cost = runtime.ruleCost("labor", record.cargoName)
      if cost ~= record.laborCostCopper then
        record.laborCostCopper = cost
        changed = true
      end
    end
  end
  return changed
end

runtime.refreshAutoMaterialCosts = function(priceKey)
  local changed = false
  for _, record in ipairs(state.records) do
    local rule = runtime.costRules.materials[record.cargoName]
    if type(rule) == "table" then
      local matches = false
      for _, item in ipairs(rule.items or {}) do
        if item.auto and normalizeNameKey(item.name) == priceKey then matches = true; break end
      end
      if matches then
        local oldCost, oldTransport, oldLabor = record.costCopper,
          record.transportCostCopper, record.laborCostCopper
        runtime.applyCostRules(record)
        if oldCost ~= record.costCopper or oldTransport ~= record.transportCostCopper
          or oldLabor ~= record.laborCostCopper then changed = true end
      end
    end
  end
  return changed
end

local function migrateHistoryFromRecords()
  if runtime.recordsLoadIncomplete or historyState.migratedFromRecords then
    return
  end

  runtime.resetHistoryTotals()
  local ordered = {}
  for _, record in ipairs(state.records) do ordered[#ordered + 1] = record end
  table.sort(ordered, function(a, b)
    local at, bt = tonumber(a.soldAt) or 0, tonumber(b.soldAt) or 0
    if at == bt then return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end
    return at < bt
  end)
  for _, record in ipairs(ordered) do
    addRecordToHistory(record)
  end
  historyState.migratedFromRecords = true
  if runtime.saveHistoryState() then saveState() end
end

local function createSaleRecord(cargoName, sourceText)
  cargoName = compactText(cargoName)
  if cargoName == "" or cargoName == "?" or cargoName == "Unknown Cargo" then
    return nil
  end

  if runtime.recordsLoadIncomplete then
    pcall(function() ADDON:ChatLog("TradePacks: cannot add sale while saved records are incomplete.") end)
    return nil
  end
  local now = nowSeconds()

  local record = {
    id = state.nextId,
    cargoName = cargoName,
    costCopper = nil,
    soldAt = now,
    dayKeyUtc2 = math.floor((now - UTC_MINUS_2_OFFSET) / 86400),
    interestPercent = nil,
    paid = false
  }
  state.nextId = state.nextId + 1

  if cargoName and runtime.latestSellByName[cargoName] then
    mergeRecordData(record, runtime.latestSellByName[cargoName])
  end
  if runtime.latestSellPreview and runtime.latestSellPreview.cargoName == cargoName then
    mergeRecordData(record, runtime.latestSellPreview)
  end
  if cargoName and runtime.latestBuyByName[cargoName] then
    mergeRecordData(record, runtime.latestBuyByName[cargoName])
  end

  if cargoName then
    record.cargoName = cargoName
  end

  if runtime.pendingSaleTerms and now - (runtime.pendingSaleTerms.capturedAt or 0) <= 30 then
    record.interestPercent = runtime.pendingSaleTerms.interestPercent
  end

  runtime.pendingSaleTerms = nil
  initializeRecordCost(record)
  runtime.applyCostRules(record)
  if trySnapshotPayoutValue then
    trySnapshotPayoutValue(record)
  end

  addRecordToHistory(record, true)
  table.insert(state.records, record)
  if not saveState() then
    for i, saved in ipairs(state.records) do
      if saved == record then table.remove(state.records, i); break end
    end
    state.nextId = record.id
    return nil
  end
  addRecordToHistory(record)
  runtime.saveHistoryState()

  if refreshUi then
    refreshUi()
  end
  if startAuctionRefresh then
    if (record.costStatus == "snapshot" or record.costStatus == "preset" or record.costStatus == "manual")
      and recordPayoutValue and recordPayoutValue(record) then
      -- phase 1 succeeded: cost and payout price already cached, no auction refresh needed.
      -- (use the Refresh button to re-pull fresh auction prices on demand)
    else
      -- Batch rapid turn-ins without moving the deadline on every sale. A long
      -- run used to postpone its first quote until ten seconds after its end.
      if not runtime.auctionRefreshPending then
        runtime.auctionRefreshPending = true
        runtime.auctionRefreshDelay = 1
      else
        runtime.auctionRefreshDelay = math.min(runtime.auctionRefreshDelay, 1)
      end
    end
  end
  return record
end

local function parseSaleText(text)
  if type(text) ~= "string" then
    return false
  end

  text = compactText(text)
  if text == "" then
    return false
  end

  local createdRecord = false
  local _, interest = text:match("[Pp]ayment will be mailed in (%d+) hours? with (%d+)%% interest")
  if interest then
    runtime.pendingSaleTerms = {
      interestPercent = tonumber(interest),
      capturedAt = nowSeconds()
    }
  end

  local cargoName = text:match("[Ss]old an item%.%[(.-)%]")
  if not cargoName then
    cargoName = text:match("[Ss]old an item%:%s*%[(.-)%]")
  end
  if not cargoName then
    cargoName = text:match("[Ss]old an item%.%s*(.+)$")
  end

  if cargoName then
    createdRecord = createSaleRecord(cargoName, text) ~= nil
  end

  return createdRecord
end

local function lookupIsOnyx(lookup)
  if type(lookup) ~= "table" then
    return false
  end
  if ONYX_ITEM_TYPES[tonumber(lookup.itemType)] == true then
    return true
  end

  local searchName = tostring(lookup.searchName or ""):lower()
  return searchName:find("onyx", 1, true) ~= nil
end

local function isOnyxAuctionLookup(itemType)
  if ONYX_ITEM_TYPES[tonumber(itemType)] == true then
    return true
  end

  local key = normalizeKey(itemType)
  if key and (lookupIsOnyx(runtime.priceLookups[key]) or lookupIsOnyx(runtime.namePriceLookups[key])) then
    return true
  end

  return false
end

local processNextAuctionSearch

local function queueHasKey(key)
  for _, queuedKey in ipairs(runtime.auctionQueue) do
    if queuedKey == key then
      return true
    end
  end
  return false
end

local function hasPendingAuctionLookups()
  return runtime.activeAuctionKey ~= nil
      or #runtime.auctionQueue > 0
      or next(runtime.priceLookups) ~= nil
      or next(runtime.namePriceLookups) ~= nil
end

local function finishAuctionLookup(key)
  runtime.priceLookups[key] = nil
  runtime.namePriceLookups[key] = nil
  if runtime.lastAuctionSearchKey == key then
    runtime.lastAuctionSearchKey = nil
  end
  if runtime.activeAuctionKey == key then
    runtime.activeAuctionKey = nil
  end
end

runtime.deferAuctionLookup = function(key, status)
  local lookup = runtime.namePriceLookups[key]
  if lookup and (lookup.attempts or 0) < 3 then
    if runtime.activeAuctionKey == key then runtime.activeAuctionKey = nil end
    if runtime.lastAuctionSearchKey == key then runtime.lastAuctionSearchKey = nil end
    lookup.readyAt = nowSeconds() + ((lookup.attempts or 0) > 1 and 10 or 3)
    if not queueHasKey(key) then runtime.auctionQueue[#runtime.auctionQueue + 1] = key end
  else
    finishAuctionLookup(key)
    status = status and status:gsub("; retrying$", "")
  end
  runtime.auctionStatus = status
end

local function storeAuctionPrice(itemType, grade, price)
  local copper = parseMoney(price)
  if not copper or copper <= 0 then
    return false
  end

  local key = normalizeKey(itemType)
  if not key then
    return false
  end

  if isOnyxAuctionLookup(itemType)
      and (copper < ONYX_MIN_REASONABLE_UNIT_PRICE or copper > ONYX_MAX_REASONABLE_UNIT_PRICE) then
    state.prices[key] = nil
    finishAuctionLookup(key)
    runtime.auctionStatus = "Ignored bad price"
    if processNextAuctionSearch and processNextAuctionSearch() then
      setAuctionLoading(true)
    else
      setAuctionLoading(false)
    end
    saveState()
    if refreshUi then
      refreshUi()
    end
    return false
  end

  state.prices[key] = {
    copper = copper,
    grade = tonumber(grade) or AUCTION_GRADE_ALL,
      updatedAt = nowSeconds()
  }
  runtime.saveLaborPrice(key)
  finishAuctionLookup(key)
  runtime.auctionStatus = nil
  local completedMaterials = tryCompleteMaterialCosts()
  local completedPayouts = false
  if tryCompletePayoutValues then
    completedPayouts = tryCompletePayoutValues()
  end
  local transportChanged = (key == normalizeNameKey(runtime.transportItems.fuel)
    or key == normalizeNameKey(runtime.transportItems.grease))
    and runtime.refreshAutoTransportCosts() or false
  local laborChanged = runtime.refreshAutoLaborCosts(key)
  local materialsChanged = runtime.refreshAutoMaterialCosts(key)
  if ui.costEditors and ui.costEditors.labor and ui.costEditors.labor.refreshLaborQuote then
    ui.costEditors.labor.refreshLaborQuote()
  end
  if processNextAuctionSearch and processNextAuctionSearch() then
    setAuctionLoading(true)
  elseif hasPendingAuctionLookups() then
    setAuctionLoading(true)
  else
    setAuctionLoading(false)
  end
  saveState()
  if completedMaterials or completedPayouts or transportChanged or laborChanged or materialsChanged then
    syncAllRecordsHistoryProfit()
  end
  if refreshUi then
    refreshUi()
  end
  return true
end

processNextAuctionSearch = function()
  if runtime.auctionSuspended then return hasPendingAuctionLookups() end
  if runtime.activeAuctionKey then
    return true
  end
  if not X2Auction or type(X2Auction.SearchAuctionArticle) ~= "function" then
    return false
  end

  -- The client silently drops an auction search fired right after the previous
  -- one, so the second queued search would never get a response. Keep a gap;
  -- updateAuctionLookups pumps the queue again once it has passed.
  if runtime.lastSearchSentAt and nowSeconds() - runtime.lastSearchSentAt < 2 then
    return #runtime.auctionQueue > 0
  end

  -- Retry failures at the back of the queue, so an unavailable item cannot
  -- hold up every other ingredient. Inspect each queued key at most once.
  for _ = 1, #runtime.auctionQueue do
    local key = table.remove(runtime.auctionQueue, 1)
    local lookup = runtime.namePriceLookups[key]
    if lookup and type(lookup.searchName) == "string" and lookup.searchName ~= "" then
      if lookup.readyAt and nowSeconds() < lookup.readyAt then
        runtime.auctionQueue[#runtime.auctionQueue + 1] = key
      else
        registerAuctionHandlers()
        -- Publish ownership before calling native code; cached responses can fire
        -- their callback inside SearchAuctionArticle itself.
        runtime.lastSearchSentAt = nowSeconds()
        lookup.startedAt, lookup.elapsed, lookup.lastTry = nowSeconds(), 0, 0
        lookup.attempts = (lookup.attempts or 0) + 1
        lookup.readyAt = nil
        if runtime.priceLookups[key] then
          runtime.priceLookups[key].elapsed = 0
          runtime.priceLookups[key].lastTry = 0
        end
        runtime.activeAuctionKey, runtime.lastAuctionSearchKey = key, key
        local ok, result = pcall(function()
          return X2Auction:SearchAuctionArticle(1, 0, 55, AUCTION_GRADE_NORMAL, 0, false, lookup.searchName, "0", "99999999999")
        end)
        if (not ok or result == false) and runtime.activeAuctionKey == key then
          runtime.deferAuctionLookup(key, "Search delayed; retrying")
        end
        setAuctionLoading(hasPendingAuctionLookups())
        return hasPendingAuctionLookups()
      end
    end
  end

  return hasPendingAuctionLookups()
end

local function askAuctionSearch(itemType, searchName, priceKey)
  if type(searchName) ~= "string" or searchName == "" then
    return false
  end
  if isUnpricedAuctionName(searchName) then
    return false
  end
  if not X2Auction or type(X2Auction.SearchAuctionArticle) ~= "function" then
    return
  end

  local key = normalizeKey(priceKey or itemType) or normalizeNameKey(searchName)
  if not key then
    return false
  end

  if runtime.namePriceLookups[key] then
    return true
  end

  registerAuctionHandlers()

  runtime.namePriceLookups[key] = {
    priceKey = key,
    itemType = itemType,
    searchName = searchName,
    grade = AUCTION_GRADE_NORMAL
  }
  if runtime.activeAuctionKey ~= key and not queueHasKey(key) then
    table.insert(runtime.auctionQueue, key)
  end

  processNextAuctionSearch()
  return true
end

local function askLowestPrice(itemType)
  if not itemType or not X2Auction or type(X2Auction.GetLowestPrice) ~= "function" then
    return false, false
  end

  local sent = false
  for _, grade in ipairs({ AUCTION_GRADE_NORMAL, AUCTION_GRADE_ALL }) do
    local ok = pcall(function()
      return X2Auction:GetLowestPrice(itemType, grade)
    end)
    if ok then
      sent = true
    end
  end

  return sent, false
end

local function queryAuctionPrice(itemType, searchName, allowSearchFallback, priceKey)
  if not X2Auction then
    runtime.auctionStatus = "API unavailable"
    setAuctionLoading(false)
    return false
  end

  local lookupKey = normalizeKey(priceKey or itemType) or normalizeNameKey(searchName)
  if not lookupKey then
    return false
  end

  local sent = false
  if itemType and not runtime.auctionSuspended then
    local lowestSent, lowestStored = askLowestPrice(itemType)
    if lowestStored or not runtime.priceLookups[lookupKey] then
      return true
    end
    sent = sent or lowestSent
  end

  if allowSearchFallback and askAuctionSearch(itemType, searchName, lookupKey) then
    sent = true
  end

  if sent then
    if hasPendingAuctionLookups() then
      runtime.auctionStatus = "Searching " .. tostring(searchName or itemType)
      setAuctionLoading(true)
    else
      runtime.auctionStatus = nil
      setAuctionLoading(false)
    end
  else
    runtime.auctionStatus = "Search failed"
    setAuctionLoading(false)
  end
  return sent
end

startAuctionRefresh = function(force, refreshAll, missingOnly)
  runtime.windowVisible = ledgerIsVisible()
  if not runtime.windowVisible and not force then
    return
  end

  -- Merge new work into the current queue. Opening OPS, saving a rule or selling
  -- another pack must not discard an in-flight response or its queued siblings.
  local completedMaterials = tryCompleteMaterialCosts()
  local completedPayouts = false
  if tryCompletePayoutValues then
    completedPayouts = tryCompletePayoutValues()
  end
  if completedMaterials or completedPayouts then syncAllRecordsHistoryProfit() end

  local records = state.records
  local requested = {}
  local now = nowSeconds()
  local requestCount = 0

  local function requestPrice(key, itemType, searchName, lookupType)
    if not key or requested[key] or runtime.priceLookups[key]
        or runtime.namePriceLookups[key] or isUnpricedAuctionName(searchName) then
      return
    end
    requested[key] = true
    if missingOnly and getPrice(key, lookupIsOnyx({itemType = itemType, searchName = searchName})) then return end
    runtime.priceLookups[key] = {
      priceKey = key,
      itemType = itemType,
      grade = AUCTION_GRADE_ALL,
      searchName = searchName,
      lookupType = lookupType,
      elapsed = 0,
      lastTry = 0,
      startedAt = now
    }
    if queryAuctionPrice(itemType, searchName, true, key) then
      requestCount = requestCount + 1
    else
      finishAuctionLookup(key)
    end
  end

  local function requestRulePrices()
    for _, rule in pairs(runtime.costRules.transport) do
      for key, itemName in pairs(runtime.transportItems) do
        if rule[key .. "Auto"] and (tonumber(rule[key .. "Qty"]) or 0) > 0 then
          requestPrice(normalizeNameKey(itemName), nil, itemName, "transport")
        end
      end
    end
    local hasLaborRule = false
    for _, rule in pairs(runtime.costRules.labor) do
      if (tonumber(rule.points) or 0) > 0 then hasLaborRule = true; break end
    end
    if hasLaborRule then
      for _, item in ipairs(runtime.laborItems) do
        requestPrice(normalizeNameKey(item.name), nil, item.name, "labor")
      end
    end
    for _, rule in pairs(runtime.costRules.materials) do
      for _, item in ipairs(rule.items or {}) do
        if item.auto and (tonumber(item.qty) or 0) > 0 then
          requestPrice(normalizeNameKey(item.name), nil, item.name, "material")
        end
      end
    end
  end

  for _, record in ipairs(records) do
    if not record.archived then
      if refreshAll or (record.costStatus ~= "snapshot" and record.costStatus ~= "preset" and record.costStatus ~= "manual") then
        local materials = ensureRecordMaterials(record)
        if materials then
          for _, material in ipairs(materials) do
            if material.name and (refreshAll or (not tonumber(material.unitPriceCopper) and not getNamedPrice(material.name))) then
              requestPrice(normalizeNameKey(material.name), nil, material.name, "material")
            end
          end
        end
      end

      if refreshAll or not (recordPayoutValue and recordPayoutValue(record)) then
        local itemType = (resolvePayoutItemType and resolvePayoutItemType(record)) or record.payoutItemType
        -- payoutSearchName already strips numeric/empty names; only fall back to the
        -- raw payoutName when it is a real (non-numeric) name. Feeding an item-type
        -- id into the auction search yields no results.
        local searchName = payoutSearchName and payoutSearchName(record)
        if not searchName then
          local fallback = compactText(record.payoutName)
          if fallback ~= "" and not tonumber(fallback) then
            searchName = fallback
          end
        end
        local key = normalizeKey(itemType) or normalizeNameKey(searchName)
        requestPrice(key, itemType, searchName, "payout")
      end
    end
  end

  -- Missing ledger costs/payouts take priority over refreshing configured items
  -- whose current quote already exists. There is no arbitrary 25-item cutoff.
  requestRulePrices()

  if requestCount == 0 and not hasPendingAuctionLookups() then
    runtime.auctionStatus = nil
    setAuctionLoading(false)
  end

  if refreshUi then
    refreshUi()
  end
end

local function updateAuctionLookups(elapsed)
  if runtime.auctionSuspended or not hasPendingAuctionLookups() then return end

  for key, lookup in pairs(runtime.priceLookups) do
    -- While this lookup's search is queued behind another, pause its response
    -- timeout: it used to keep ticking from the moment of the refresh, so every
    -- search after the first died with "No response" before getting its turn.
    local waitingForQueuedSearch = runtime.namePriceLookups[key] and runtime.activeAuctionKey ~= key
    if waitingForQueuedSearch then
      -- This lookup has not been sent yet; the queue pump below will start it.
    else
      lookup.elapsed = (lookup.elapsed or 0) + elapsed
      local searchLookup = runtime.namePriceLookups[key]
      local searchDone = searchLookup and runtime.activeAuctionKey == key and readSearchedAuctionResults(key, searchLookup, false)
      if searchDone then
        -- The result handler stored the price and cleared this lookup.
      elseif lookup.elapsed >= 8 then
        runtime.deferAuctionLookup(key, "No response; retrying")
        if processNextAuctionSearch and processNextAuctionSearch() then
          setAuctionLoading(true)
        else
          setAuctionLoading(false)
        end
      elseif not searchLookup and lookup.itemType and lookup.elapsed - (lookup.lastTry or 0) >= 2 then
        lookup.lastTry = lookup.elapsed
        queryAuctionPrice(lookup.itemType, lookup.searchName, false, key)
      end
    end
  end

  -- Pump the search queue: with the send-gap throttle, a queued search may not
  -- have been started by the previous search's completion handler.
  if not runtime.activeAuctionKey and #runtime.auctionQueue > 0 then
    if processNextAuctionSearch() then
      setAuctionLoading(true)
    end
  end
end

local function createWidget(kind, name, parent, x, y, width, height)
  local widget
  local uniqueName = widgetName(name)
  if parent and type(parent.CreateChildWidget) == "function" then
    widget = parent:CreateChildWidget(kind, uniqueName, 0, true)
  else
    widget = UIParent:CreateWidget(kind, uniqueName, "UIParent")
  end

  if not widget then
    error("failed to create widget: " .. tostring(name) .. " (" .. tostring(kind) .. ")")
  end

  widget:SetExtent(width, height)
  widget:AddAnchor("TOPLEFT", parent or "UIParent", x, y)
  widget:Show(true)
  return widget
end

local function showWidget(widget, visible)
  local widgetType = type(widget)
  if (widgetType == "table" or widgetType == "userdata") and widget.Show then
    pcall(function()
      widget:Show(visible)
    end)
  end
end

local function styleText(widget, color, align)
  if not widget then
    return
  end

  if type(color) == "table" then
    if widget.style and type(widget.style.SetColor) == "function" then
      pcall(function()
        widget.style:SetColor(color[1], color[2], color[3], color[4] or 1)
      end)
    end
    if type(widget.SetTextColor) == "function" then
      pcall(function()
        widget:SetTextColor(color[1], color[2], color[3], color[4] or 1)
      end)
    end
  elseif type(color) == "string" and widget.style and type(widget.style.SetColorByKey) == "function" then
    pcall(function()
      widget.style:SetColorByKey(color)
    end)
  end

  if align ~= nil and widget.style and type(widget.style.SetAlign) == "function" then
    pcall(function()
      widget.style:SetAlign(align)
    end)
  end
  if widget.style and type(widget.style.SetShadow) == "function" then
    pcall(function()
      widget.style:SetShadow(false)
    end)
  end
end

local function makeLabel(name, parent, x, y, width, height, text)
  local label = createWidget("label", name, parent, x, y, width, height)
  label:SetText(text or "")
  styleText(label, TEXT_BROWN)
  return label
end

runtime.buttonExtents = {}
runtime.setButtonText = function(button, value)
  button:SetText(value)
  local extent = runtime.buttonExtents[button]
  if extent then button:SetExtent(extent[1], extent[2]) end
end

local function makeButton(name, parent, x, y, width, height, text, handler, nativeSize)
  local button = createWidget("button", name, parent, x, y, width, height)
  pcall(function()
    button:SetStyle("text_default")
  end)
  if nativeSize then
    -- The floating OPS launcher used the skin's natural size before v1.5.1.
    button:SetText(text or "")
  else
    -- Some client skins resize text_default buttons to fit the label. Restore
    -- the requested extent after styling/text for the ledger controls.
    runtime.buttonExtents[button] = {width, height}
    runtime.setButtonText(button, text or "")
  end
  styleText(button, TEXT_BROWN)
  if handler then
    button:SetHandler("OnClick", handler)
  end
  return button
end

local function makeTextButton(name, parent, x, y, width, height, text, handler)
  local label = makeLabel(name, parent, x, y, width, height, text)
  pcall(function()
    label:EnablePick(true)
  end)
  pcall(function()
    label:Clickable(true)
  end)
  if handler then
    label:SetHandler("OnClick", handler)
  end
  return label
end

local function makeEditbox(name, parent, x, y, width, height, text)
  -- The client's single-line "editbox" can return no value from GetText().
  -- Other working addons use editboxmultiline for numeric input as well.
  local uniqueName = widgetName(name)
  local editbox
  if parent and type(parent.CreateChildWidget) == "function" then
    pcall(function()
      editbox = parent:CreateChildWidget("editboxmultiline", uniqueName, 0, true)
    end)
  end
  if not editbox and UIParent and type(UIParent.CreateWidget) == "function" then
    pcall(function()
      editbox = UIParent:CreateWidget("editboxmultiline", uniqueName, parent or "UIParent", "")
    end)
  end
  if not editbox then
    return nil
  end
  pcall(function() editbox:SetExtent(width, height) end)
  pcall(function() editbox:AddAnchor("TOPLEFT", parent or "UIParent", x, y) end)
  pcall(function() editbox:Show(true) end)
  pcall(function() editbox:EnablePick(true) end)
  -- A bare editbox is invisible on the parchment UI; give it a dark field
  -- background so it can be seen and clicked to focus.
  pcall(function() editbox:EnableDrawables("background") end)
  pcall(function()
    local bg = editbox:CreateColorDrawable(0.10, 0.09, 0.07, 0.85, "background")
    bg:AddAnchor("TOPLEFT", editbox, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", editbox, 0, 0)
  end)
  pcall(function() editbox:SetInset(4, 1, 4, 1) end)
  pcall(function() editbox:SetMaxTextLength(24) end)
  pcall(function() editbox.style:SetColor(1, 1, 1, 1) end)
  pcall(function() editbox:SetCursorColorByColorKey("white") end)
  pcall(function() editbox:SetText(text or "") end)
  return editbox
end

local function sizeDrawable(drawable, owner, width, height)
  if not drawable then
    return
  end

  pcall(function()
    drawable:AddAnchor("TOPLEFT", owner, 0, 0)
  end)
  pcall(function()
    drawable:AddAnchor("TOPLEFT", owner, "TOPLEFT", 0, 0)
  end)
  pcall(function()
    drawable:SetExtent(width, height)
  end)
  pcall(function()
    drawable:SetCoords(0, 0, width, height)
  end)
end

local function showDrawable(drawable)
  if not drawable then
    return
  end
  pcall(function()
    drawable:SetVisible(true)
  end)
  pcall(function()
    drawable:Show(true)
  end)
end

local function makeSeparator(name, parent, x, y, width)
  local separator = createWidget("emptywidget", name, parent, x, y, width, 1)
  pcall(function()
    separator:EnableDrawables("background")
  end)

  if type(separator.CreateColorDrawable) == "function" then
    local ok, drawable = pcall(function()
      return separator:CreateColorDrawable(TEXT_BROWN[1], TEXT_BROWN[2], TEXT_BROWN[3], 0.45, "background")
    end)
    if ok and drawable then
      pcall(function()
        drawable:AddAnchor("TOPLEFT", separator, 0, 0)
        drawable:AddAnchor("BOTTOMRIGHT", separator, 0, 0)
        drawable:SetColor(TEXT_BROWN[1], TEXT_BROWN[2], TEXT_BROWN[3], 0.45)
      end)
      showDrawable(drawable)
    end
  end

  return separator
end

local function makeSelectionHighlight(name, parent, x, y, width, height)
  local highlight = createWidget("emptywidget", name, parent, x, y, width, height)
  pcall(function()
    highlight:SetDrawPriority(-70)
  end)
  pcall(function()
    highlight:EnablePick(false)
  end)
  pcall(function()
    highlight:Clickable(false)
  end)
  pcall(function()
    highlight:EnableDrawables("background")
  end)

  -- brown row highlight on the light UI, transparent blue on the dark UI
  local hr, hg, hb, ha = 0.62, 0.38, 0.12, 0.18
  if DARK_MODE then
    hr, hg, hb, ha = 0.30, 0.58, 0.95, 0.28
  end

  if type(highlight.CreateColorDrawable) == "function" then
    local ok, drawable = pcall(function()
      return highlight:CreateColorDrawable(hr, hg, hb, ha, "background")
    end)
    if ok and drawable then
      pcall(function()
        drawable:AddAnchor("TOPLEFT", highlight, 0, 0)
        drawable:AddAnchor("BOTTOMRIGHT", highlight, 0, 0)
        drawable:SetColor(hr, hg, hb, ha)
      end)
      showDrawable(drawable)
    end
  end

  highlight:Show(false)
  return highlight
end

local function drawableCoords(key)
  local ok, data = pcall(function()
    return UIParent:GetTextureData(WINDOW_SKIN_PATH, key)
  end)
  if ok and type(data) == "table" and type(data.coords) == "table" then
    return data.coords
  end
  return nil
end

local function createKeyDrawable(owner, path, key, layer)
  if owner and type(owner.CreateDrawable) == "function" then
    local ok, drawable = pcall(function()
      return owner:CreateDrawable(path, key, layer)
    end)
    if ok and drawable then
      return drawable
    end
  end
  return nil
end

local function createImageDrawable(owner, path, layer)
  if owner and type(owner.CreateImageDrawable) == "function" then
    local ok, drawable = pcall(function()
      return owner:CreateImageDrawable(path, layer)
    end)
    if ok and drawable then
      return drawable
    end
  end
  return nil
end

local function addNativeWindowSkin(window, width, height)
  if not window then
    return false
  end

  pcall(function()
    window:EnableDrawables("background")
  end)

  -- Dark mode: use the dark-adaptive Main BG + Deco skin instead of the tan
  -- native specialty skin (which stays light and looks wrong on a dark UI).
  if DARK_MODE then
    local mainBg = createKeyDrawable(window, WINDOW_SKIN_PATH, "main_bg", "background")
    local deco = createKeyDrawable(window, WINDOW_SKIN_PATH, "main_bg_deco", "background")
    if mainBg then
      pcall(function()
        mainBg:AddAnchor("TOPLEFT", window, -5, -5)
        mainBg:AddAnchor("BOTTOMRIGHT", window, 5, 5)
      end)
      showDrawable(mainBg)
    end
    if deco then
      pcall(function()
        deco:AddAnchor("TOPLEFT", window, 0, -5)
        deco:AddAnchor("TOPRIGHT", window, 0, -5)
      end)
      showDrawable(deco)
    end
    if mainBg or deco then
      return true
    end
  end

  local drewNativeSkin = false
  local colorTexture = createKeyDrawable(window, WINDOW_SKIN_PATH, "window_color_texture_bg", "background")
  if colorTexture then
    pcall(function()
      colorTexture:AddAnchor("TOPLEFT", window, 0, 0)
      colorTexture:AddAnchor("BOTTOMRIGHT", window, 0, 0)
    end)
    showDrawable(colorTexture)
    drewNativeSkin = true
  end

  local coordSize = width < 680 and "small" or "big"
  local upperCoords = drawableCoords("bg_top_" .. coordSize)
  local lowerLeftCoords = drawableCoords("bg_bottom_" .. coordSize .. "_left")
  local lowerRightCoords = drawableCoords("bg_bottom_" .. coordSize .. "_right")
  local anchorInset = width >= 900 and 14 or 12

  if upperCoords and lowerLeftCoords and lowerRightCoords then
    local upper = createImageDrawable(window, WINDOW_SKIN_PATH, "background")
    if upper then
      pcall(function()
        upper:SetCoords(upperCoords[1], upperCoords[2], upperCoords[3], upperCoords[4])
        upper:SetHeight(upperCoords[4])
        upper:AddAnchor("TOPLEFT", window, -anchorInset, -11)
        upper:AddAnchor("TOPRIGHT", window, anchorInset, -11)
      end)
      showDrawable(upper)
      drewNativeSkin = true
    end

    local lowerLeft = createImageDrawable(window, WINDOW_SKIN_PATH, "background")
    if lowerLeft then
      pcall(function()
        lowerLeft:SetCoords(lowerLeftCoords[1], lowerLeftCoords[2], lowerLeftCoords[3], lowerLeftCoords[4])
        lowerLeft:SetExtent((width / 2) + anchorInset, lowerLeftCoords[4])
        lowerLeft:AddAnchor("BOTTOMLEFT", window, -anchorInset, 11)
      end)
      showDrawable(lowerLeft)
      drewNativeSkin = true
    end

    local lowerRight = createImageDrawable(window, WINDOW_SKIN_PATH, "background")
    if lowerRight then
      pcall(function()
        lowerRight:SetCoords(lowerRightCoords[1], lowerRightCoords[2], lowerRightCoords[3], lowerRightCoords[4])
        lowerRight:SetExtent((width / 2) + anchorInset, lowerRightCoords[4])
        lowerRight:AddAnchor("BOTTOMRIGHT", window, anchorInset, 11)
      end)
      showDrawable(lowerRight)
      drewNativeSkin = true
    end
  end

  if not drewNativeSkin then
    local simpleWindow = createKeyDrawable(window, WINDOW_NINEPART_PATH, "window", "background")
    if simpleWindow then
      pcall(function()
        simpleWindow:AddAnchor("TOPLEFT", window, 0, 0)
        simpleWindow:AddAnchor("BOTTOMRIGHT", window, 0, 0)
      end)
      showDrawable(simpleWindow)
      return true
    end
  end

  return drewNativeSkin
end

local function addBackdrop(widget, height)
  if not widget or type(widget.CreateColorDrawable) ~= "function" then
    return nil
  end

  pcall(function()
    widget:EnableDrawables("background")
  end)
  pcall(function()
    widget:SetLayerColor(0.03, 0.025, 0.018, 0.82, "background")
  end)

  local ok, drawable = pcall(function()
    return widget:CreateColorDrawable(0.015, 0.014, 0.012, 0.9, "background")
  end)
  if not ok or not drawable then
    return nil
  end

  pcall(function()
    drawable:SetColor(0.015, 0.014, 0.012, 0.9)
  end)
  sizeDrawable(drawable, widget, LEDGER_WIDTH, height or LEDGER_HEIGHT)
  pcall(function()
    drawable:Show(true)
  end)
  return drawable
end

local function addParchmentTint(parent, height)
  local tint = createWidget("emptywidget", "TradePacksParchmentTint", parent, 0, 0, LEDGER_WIDTH, height or LEDGER_HEIGHT)
  pcall(function()
    tint:SetDrawPriority(-90)
  end)
  pcall(function()
    tint:EnablePick(false)
  end)
  pcall(function()
    tint:Clickable(false)
  end)
  pcall(function()
    tint:EnableDrawables("background")
  end)

  -- Skip the tan parchment overlay in dark mode (it would wash out the dark BG).
  if DARK_MODE then
    return tint
  end

  if type(tint.CreateColorDrawable) == "function" then
    local ok, drawable = pcall(function()
      return tint:CreateColorDrawable(0.91, 0.80, 0.57, 0.42, "background")
    end)
    if ok and drawable then
      pcall(function()
        drawable:AddAnchor("TOPLEFT", tint, 0, 0)
        drawable:AddAnchor("BOTTOMRIGHT", tint, 0, 0)
        drawable:SetColor(0.91, 0.80, 0.57, 0.42)
      end)
      showDrawable(drawable)
    end
  end

  return tint
end

local function addSizedParchmentTint(parent, name, width, height)
  local tint = createWidget("emptywidget", name, parent, 0, 0, width, height)
  pcall(function()
    tint:SetDrawPriority(-90)
  end)
  pcall(function()
    tint:EnablePick(false)
  end)
  pcall(function()
    tint:EnableDrawables("background")
  end)

  -- Skip the tan parchment overlay in dark mode (it would wash out the dark BG).
  if DARK_MODE then
    return tint
  end

  if type(tint.CreateColorDrawable) == "function" then
    local ok, drawable = pcall(function()
      return tint:CreateColorDrawable(0.91, 0.80, 0.57, 0.42, "background")
    end)
    if ok and drawable then
      pcall(function()
        drawable:AddAnchor("TOPLEFT", tint, 0, 0)
        drawable:AddAnchor("BOTTOMRIGHT", tint, 0, 0)
        drawable:SetColor(0.91, 0.80, 0.57, 0.42)
      end)
      showDrawable(drawable)
    end
  end

  return tint
end

local function addWindowBorder(parent, baseName, width, height)
  -- gold accent on the light UI, silver on the dark UI
  local r, g, b, a = 0.72, 0.52, 0.18, 0.90
  if DARK_MODE then
    r, g, b, a = 0.78, 0.80, 0.84, 0.90
  end
  local thickness = 2
  local function makeLine(suffix, x, y, w, h)
    local line = createWidget("emptywidget", baseName .. suffix, parent, x, y, w, h)
    pcall(function() line:EnablePick(false) end)
    pcall(function() line:SetDrawPriority(60) end)
    pcall(function() line:EnableDrawables("background") end)
    if type(line.CreateColorDrawable) == "function" then
      local ok, drawable = pcall(function()
        return line:CreateColorDrawable(r, g, b, a, "background")
      end)
      if ok and drawable then
        pcall(function()
          drawable:AddAnchor("TOPLEFT", line, 0, 0)
          drawable:AddAnchor("BOTTOMRIGHT", line, 0, 0)
          drawable:SetColor(r, g, b, a)
        end)
        showDrawable(drawable)
      end
    end
    return line
  end
  local top = makeLine("BorderTop",    0,               0,                width,     thickness)
  local bottom = makeLine("BorderBottom", 0,               height - thickness, width,  thickness)
  local left = makeLine("BorderLeft",   0,               0,                thickness, height)
  local right = makeLine("BorderRight",  width - thickness, 0,              thickness, height)
  return {top = top, bottom = bottom, left = left, right = right}
end

local function clearDrawables(widget)
  if not widget or type(widget.RemoveAllDrawables) ~= "function" then
    return
  end

  for _, layer in ipairs({ "background", "artwork", "overlay", "overoverlay" }) do
    pcall(function()
      widget:RemoveAllDrawables(layer)
    end)
  end
end

local function parseIconCoord(coord)
  if type(coord) ~= "string" then
    return nil
  end

  local x, y, w, h = coord:match("(%d+)[,%s]+(%d+)[,%s]+(%d+)[,%s]+(%d+)")
  if x then
    return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
  end
  return nil
end

local function setIcon(widget, iconInfo)
  clearDrawables(widget)
  widget:SetText("")

  if type(iconInfo) ~= "table" then
    return
  end

  local iconPath = iconInfo.icon or iconInfo.iconPath
  local iconCoord = iconInfo.iconCoord
  if type(iconPath) ~= "string" or iconPath == "" then
    return
  end

  local okIcon, iconDrawable = pcall(function()
    return widget:CreateIconDrawable("artwork")
  end)
  if okIcon and iconDrawable then
    pcall(function()
      iconDrawable:ClearAllTextures()
    end)
    pcall(function()
      iconDrawable:AddTexture(iconPath)
    end)
    pcall(function()
      iconDrawable:AddAnchor("TOPLEFT", widget, 0, 0)
    end)
    pcall(function()
      iconDrawable:SetExtent(24, 24)
    end)
    showDrawable(iconDrawable)
    return
  end

  local ok, drawable = pcall(function()
    return widget:CreateImageDrawable(iconPath, "artwork")
  end)
  if not ok or not drawable then
    return
  end

  local x, y, w, h = parseIconCoord(iconCoord)
  if x then
    pcall(function()
      drawable:SetCoords(x, y, w, h)
    end)
  end
  pcall(function()
    drawable:SetVisible(true)
  end)
end

local effectivePayoutCount
local isOnyxPayout

recordProfit = function(record)
  local payoutValue = recordPayoutValue and recordPayoutValue(record)
  local cost = runtime.totalCost(record)
  if not payoutValue or not cost then
    return nil
  end
  return payoutValue - cost
end

runtime.totalCost = function(record)
  local materials = tonumber(record and record.costCopper)
  if not materials then return nil end
  local laborRule = record and runtime.costRules.labor[record.cargoName]
  if type(laborRule) == "table" and (tonumber(laborRule.points) or 0) > 0
      and not tonumber(record.laborCostCopper) then return nil end
  return materials + math.max(0, tonumber(record.transportCostCopper) or 0)
    + math.max(0, tonumber(record.laborCostCopper) or 0)
end

isOnyxPayout = function(record)
  if type(record) ~= "table" then
    return false
  end

  -- The item-type id captured from the sale event is the most reliable signal:
  -- when it is present and names a different item (e.g. Dragon Essence
  -- Stabilizer), the record is not Onyx no matter what the name fields say.
  local itemType = tonumber(record.payoutItemType)
  if itemType and itemType > 0 then
    return ONYX_ITEM_TYPES[itemType] == true
  end

  local name = tostring(record.payoutName or ""):lower()
  if ONYX_ITEM_TYPES[tonumber(name)] == true or name:find("onyx", 1, true) ~= nil then
    return true
  end

  -- No item type and no usable name: old Auroran Cargo records predate payout
  -- tracking and were always Onyx.
  if compactText(record.cargoName) == "Auroran Cargo" then
    local compactName = compactText(record.payoutName)
    return compactName == "" or tonumber(compactName) ~= nil
  end

  return false
end

resolvePayoutItemType = function(record)
  if type(record) ~= "table" then
    return nil
  end

  local itemType = tonumber(record.payoutItemType)
  if itemType and itemType > 0 then
    return itemType
  end

  if isOnyxPayout(record) then
    record.payoutItemType = ONYX_ITEM_TYPE
    if not record.payoutName or tonumber(record.payoutName) then
      record.payoutName = ONYX_DISPLAY_NAME
    end
    return ONYX_ITEM_TYPE
  end

  return record.payoutItemType
end

local function itemIconInfo(itemType)
  itemType = tonumber(itemType)
  if not itemType or itemType <= 0 or not X2Item then
    return nil
  end

  if type(X2Item.GetItemInfoByType) == "function" then
    local ok, info = pcall(function()
      return X2Item:GetItemInfoByType(itemType)
    end)
    if ok and type(info) == "table" then
      if type(info.icon) == "string" or type(info.iconPath) == "string" then
        return {
          icon = info.icon or info.iconPath,
          overIcon = info.overIcon,
          gradeIcon = info.gradeIcon
        }
      end

      if type(X2Item.GetItemIconSet) == "function" then
        local grade = tonumber(info.itemGrade) or tonumber(info.grade) or 0
        local okIcon, iconInfo = pcall(function()
          return X2Item:GetItemIconSet(itemType, grade)
        end)
        if okIcon and type(iconInfo) == "table" and type(iconInfo.icon) == "string" then
          return {
            icon = iconInfo.icon,
            overIcon = iconInfo.overIcon,
            gradeIcon = iconInfo.gradeIcon
          }
        end
      end
    end
  end

  if type(X2Item.GetItemIconSet) == "function" then
    local okIcon, iconInfo = pcall(function()
      return X2Item:GetItemIconSet(itemType, 0)
    end)
    if okIcon and type(iconInfo) == "table" and type(iconInfo.icon) == "string" then
      return {
        icon = iconInfo.icon,
        overIcon = iconInfo.overIcon,
        gradeIcon = iconInfo.gradeIcon
      }
    end
  end

  return nil
end

local function isBaseIconPath(iconPath)
  if type(iconPath) ~= "string" or iconPath == "" then
    return false
  end

  local lower = iconPath:lower()
  if lower:find("overicon", 1, true)
      or lower:find("over_icon", 1, true)
      or lower:find("icon_grade", 1, true)
      or lower:find("gradeicon", 1, true) then
    return false
  end

  return true
end

resolveRecordIcon = function(record)
  if type(record) ~= "table" then
    return nil
  end

  if isBaseIconPath(record.iconPath) then
    return {
      icon = record.iconPath,
      iconCoord = record.iconCoord
    }
  end

  local iconInfo = itemIconInfo(record.cargoItemType)
  if iconInfo then
    return iconInfo
  end

  return nil
end

runtime.unresolvableNameTypes = {}

local function payoutDisplayName(record)
  if tonumber(record and record.payoutCopper) then
    return "Money"
  end
  if isOnyxPayout(record) then
    return ONYX_DISPLAY_NAME
  end
  -- Sale events sometimes capture the raw item-type id where the name should
  -- be; resolve the real name from the id rather than displaying the number.
  local name = compactText(record and record.payoutName)
  if name == "" or tonumber(name) then
    local itemType = tonumber(record and record.payoutItemType)
    if itemType and not runtime.unresolvableNameTypes[itemType] then
      local realName = getItemNameByType(itemType)
      if realName and realName ~= "" then
        record.payoutName = realName
        return realName
      end
      runtime.unresolvableNameTypes[itemType] = true
    end
  end
  if name ~= "" then
    return name
  end
  return "Payout"
end

payoutSearchName = function(record)
  if isOnyxPayout(record) then
    return ONYX_AUCTION_SEARCH_NAME
  end

  local name = compactText(record and record.payoutName)
  if name ~= "" and not tonumber(name) then
    return name
  end
  -- The recorded name is missing or a raw id; a resolved item name still allows
  -- the auction search fallback instead of relying on lowest-price events only.
  return getItemNameByType(record and record.payoutItemType)
end

effectivePayoutCount = function(record)
  local count = tonumber(record and record.payoutCount)
  if not count then
    return nil
  end

  if isOnyxPayout(record) then
    local interestPercent = tonumber(record.interestPercent) or 0
    if interestPercent > 0 then
      return math.ceil(count * (1 + interestPercent / 100))
    end
    return math.ceil(count)
  end

  return count
end

runtime.payoutPrice = function(record)
  local itemType = resolvePayoutItemType(record)
  local key = normalizeKey(itemType)
  local unit = getPrice(key, isOnyxPayout(record))
  if not unit then
    -- Some sale payloads have a payout name/count but no item type. Their AH
    -- searches are keyed by name; read the same key when completing the record.
    key = normalizeNameKey(payoutSearchName(record))
    unit = getPrice(key, isOnyxPayout(record))
  end
  return unit, key and state.prices[key]
end

recordPayoutValue = function(record)
  if type(record) ~= "table" then
    return nil
  end

  local moneyPayout = tonumber(record.payoutCopper)
  if moneyPayout and moneyPayout > 0 then
    return moneyPayout
  end

  local payoutCount = effectivePayoutCount(record)
  if not payoutCount then
    return nil
  end

  -- Prefer the per-record snapshot so a later auction price update never changes
  -- the payout (and profit) of records that were already priced. Only fall back
  -- to the live price when this record has not been snapshotted yet; this read is
  -- intentionally non-mutating -- locking happens in trySnapshotPayoutValue.
  local unit = tonumber(record.payoutUnitPriceCopper)
  if not unit then
    unit = runtime.payoutPrice(record)
  end
  if not unit or unit <= 0 then
    return nil
  end
  return payoutCount * unit
end

-- Lock this record's payout unit price the first time a valid price is known,
-- mirroring trySnapshotMaterialCost on the cost side. Returns (locked, changed).
trySnapshotPayoutValue = function(record)
  if type(record) ~= "table" then
    return false, false
  end
  -- Money payouts are already a fixed amount; nothing to price.
  if tonumber(record.payoutCopper) then
    return true, false
  end
  -- Already snapshotted: leave it untouched.
  if tonumber(record.payoutUnitPriceCopper) then
    return true, false
  end

  local unit, entry = runtime.payoutPrice(record)
  if not unit or unit <= 0 then
    return false, false
  end

  record.payoutUnitPriceCopper = unit
  record.payoutPricedAt = type(entry) == "table" and tonumber(entry.updatedAt) or nil
  return true, true
end

tryCompletePayoutValues = function()
  local changed = false
  for _, record in ipairs(state.records) do
    if not record.archived and not tonumber(record.payoutUnitPriceCopper)
      and not tonumber(record.payoutCopper) then
      local _, recordChanged = trySnapshotPayoutValue(record)
      changed = changed or recordChanged
    end
  end
  if changed then
    saveState()
  end
  return changed
end

local function recordPayoutText(record)
  if tonumber(record and record.payoutCopper) then
    return "Money"
  end

  local count = effectivePayoutCount(record)
  local name = payoutDisplayName(record)
  if count then
    return string.format("%d %s", count, name)
  end
  return name
end

local function recordCostText(record)
  local total = runtime.totalCost(record)
  if total then
    return formatMoney(total)
  end
  local laborRule = record and runtime.costRules.labor[record.cargoName]
  if type(laborRule) == "table" and (tonumber(laborRule.points) or 0) > 0
      and not tonumber(record.laborCostCopper) then return "pricing" end
  if record and record.costStatus == "pricing" then
    return "pricing"
  end
  return "?"
end

local function recordTotalText(record)
  local payout = recordPayoutValue and recordPayoutValue(record)
  return payout and formatMoney(payout) or "?"
end

-- Profit margin (ROI) as a percent of cost. Attached to runtime (not a new local)
-- because the main chunk is at Lua's 200-local ceiling.
runtime.recordMarginText = function(record)
  local profit = recordProfit and recordProfit(record)
  local cost = runtime.totalCost(record)
  if not profit or not cost or cost <= 0 then
    return "?"
  end
  local pct = math.floor((profit / cost) * 100 + 0.5)
  if pct > 0 then
    return "+" .. pct .. "%"
  end
  return pct .. "%"
end

local function cargoDisplayName(record)
  local name = compactText(record and record.cargoName)
  if name ~= "" and name ~= "?" and name ~= "Unknown Cargo" then
    return name
  end
  if isOnyxPayout(record) then
    return "Auroran Cargo"
  end
  return name ~= "" and name or "?"
end

local function fitDisplayText(text, maxChars)
  text = compactText(text)
  maxChars = tonumber(maxChars) or 0
  if maxChars <= 0 or #text <= maxChars then
    return text
  end
  if maxChars <= 3 then
    return text:sub(1, maxChars)
  end
  return text:sub(1, maxChars - 3) .. "..."
end

local function auctionUnitPrice(price, stackCount)
  local total = parseMoney(price)
  if not total or total <= 0 then
    return nil
  end

  stackCount = tonumber(stackCount) or 1
  if stackCount <= 1 then
    return total
  end

  if X2Auction and type(X2Auction.GetPartitionPriceByCount) == "function" then
    local ok, value = pcall(function()
      return X2Auction:GetPartitionPriceByCount(tostring(price), stackCount, 1)
    end)
    local partitionPrice = ok and parseMoney(value) or nil
    if partitionPrice and partitionPrice > 0 then
      return partitionPrice
    end
  end

  return math.floor((total / stackCount) + 0.5)
end

local function auctionResultMatchesLookup(itemInfo, lookup, price)
  local searchName = compactText(lookup and lookup.searchName):lower()
  if searchName ~= "" then
    local itemName = compactText(itemInfo and itemInfo.name):lower()
    local lookupItemType = tonumber(lookup and lookup.itemType)
    local resultItemType = tonumber(itemInfo and (itemInfo.itemType or itemInfo.type))
    local typeMatches = lookupItemType ~= nil and lookupItemType == resultItemType
    -- Results with no readable name used to pass unconditionally, letting stale
    -- results from a previous (possibly user-made) search slip through.
    if itemName ~= searchName and not typeMatches then
      return false
    end
  end

  if not lookupIsOnyx(lookup) then
    return true
  end

  price = tonumber(price)
  if not price or price < ONYX_MIN_REASONABLE_UNIT_PRICE or price > ONYX_MAX_REASONABLE_UNIT_PRICE then
    return false
  end

  local name = compactText(itemInfo and itemInfo.name):lower()
  if name ~= "" and not name:find("onyx", 1, true) then
    return false
  end

  return true
end

local function searchedAuctionPrice(itemInfo, lookup, directPrice)
  if type(itemInfo) ~= "table" then
    return nil
  end

  local stackCount = tonumber(itemInfo.stackCount) or tonumber(itemInfo.count) or 1

  local bestPrice = nil
  local buyoutPrices = {
    itemInfo.directPriceStr,
    itemInfo.directPrice,
    itemInfo.priceStr,
    itemInfo.price,
    directPrice
  }
  -- An array with holes cannot be traversed with ipairs. These fields are
  -- optional, so inspect all four positions explicitly. Bids are not a price
  -- at which the item can be bought immediately.
  for i = 1, 5 do
    local rawPrice = buyoutPrices[i]
    local price = auctionUnitPrice(rawPrice, stackCount)
    if price and auctionResultMatchesLookup(itemInfo, lookup, price) and (not bestPrice or price < bestPrice) then
      bestPrice = price
    end
  end

  return bestPrice
end

handleLowestPrice = function(itemType, grade, price)
  if price == nil or runtime.auctionSuspended then
    return
  end

  -- This event also fires for lowest-price requests made by the game's own
  -- auction UI. Only store prices the event explicitly attributes to an item;
  -- guessing the item from a pending lookup priced unrelated items in the past.
  local parsedItemType = tonumber(itemType)
  if parsedItemType then
    storeAuctionPrice(parsedItemType, grade, price)
  end
end

readSearchedAuctionResults = function(key, lookup, markNoResult)
  if not lookup or not X2Auction then
    return false
  end

  local okCount, count = pcall(function()
    return X2Auction:GetSearchedItemCount()
  end)
  count = okCount and tonumber(count) or 0

  if count and count > 0 then
    local bestPrice = nil
    for index = 1, count do
      local okInfo, itemInfo = pcall(function()
        return X2Auction:GetSearchedItemInfo(index)
      end)
      if okInfo and type(itemInfo) == "table" then
        -- In the client auction UI, buyout is returned separately from item
        -- info. Never use the first (bid) value as a buy-now price.
        local okPrice, _, directPrice = pcall(function()
          return X2Auction:GetSearchedItemPrice(index)
        end)
        local price = searchedAuctionPrice(itemInfo, lookup, okPrice and directPrice or nil)
        if price and (not bestPrice or price < bestPrice) then
          bestPrice = price
        end
      end
    end

    if bestPrice then
      return storeAuctionPrice(lookup.priceKey or lookup.itemType or key, lookup.grade or AUCTION_GRADE_NORMAL, bestPrice)
    end
  end

  if markNoResult then
    runtime.deferAuctionLookup(key, "No matching AH listing; retrying")
    if processNextAuctionSearch and processNextAuctionSearch() then
      setAuctionLoading(true)
    else
      setAuctionLoading(false)
    end
    if refreshUi then
      refreshUi()
    end
  end
  return false
end

handleAuctionItemSearched = function()
  -- This event also fires when the user searches the auction house themselves.
  -- Only read the results while one of this addon's own searches is in flight;
  -- otherwise an arbitrary pending lookup would absorb the price of whatever
  -- unrelated item the user searched for.
  if runtime.auctionSuspended then return end
  local key = runtime.activeAuctionKey
  local lookup = key and runtime.namePriceLookups[key]
  if not lookup then
    return
  end
  readSearchedAuctionResults(key, lookup, true)
end

local function updateSummary(records)
  local totalProfit, totalKnown = 0, true
  local openCount, deliveredCount = 0, 0
  for _, record in ipairs(state.records) do
    if not record.archived then
      local status = getRecordStatus(record)
      if status == "Waiting" then
        openCount = openCount + 1
        local profit = recordProfit(record)
        if profit then totalProfit = totalProfit + profit
        else totalKnown = false end
      else
        deliveredCount = deliveredCount + 1
      end
    end
  end
  if openCount == 0 then
    ui.totalLabel:SetText("Expected Profit: 0g")
  elseif totalKnown then
    ui.totalLabel:SetText("Expected Profit: " .. formatMoney(totalProfit))
  else
    ui.totalLabel:SetText("Expected Profit: " .. formatMoney(totalProfit) .. " known + unpriced")
  end
  if ui.waitingDeliveryLabel then
    ui.waitingDeliveryLabel:SetText(tostring(openCount) .. " waiting | "
      .. tostring(deliveredCount) .. " delivered")
  end
end

local function historyStatistics()
  local packCount = tonumber(historyState.packCount) or 0
  local totalProfit = tonumber(historyState.totalProfitCopper) or 0
  local unknownProfitCount = tonumber(historyState.unknownProfitCount) or 0
  local knownCount = math.max(0, packCount - unknownProfitCount)
  local favoritePack = compactText(historyState.favoritePack)
  if favoritePack == "" then
    favoritePack = "-"
  end

  local totalProfitText = "?"
  local averageProfitText = "?"
  if packCount == 0 then
    totalProfitText = formatMoney(0)
    averageProfitText = formatMoney(0)
  elseif knownCount > 0 then
    totalProfitText = formatMoney(totalProfit)
    averageProfitText = formatMoney(math.floor((totalProfit / knownCount) + 0.5))
    if unknownProfitCount > 0 then
      totalProfitText = totalProfitText .. " (" .. tostring(unknownProfitCount) .. " unpriced)"
    end
  end

  local dailyProfit = tonumber(historyState.dailyProfitCopper) or 0
  local dailyUnknown = tonumber(historyState.dailyUnknownCount) or 0
  local dailyProfitText = formatMoney(dailyProfit)
  if dailyUnknown > 0 then
    dailyProfitText = dailyProfitText .. " (" .. tostring(dailyUnknown) .. " unpriced)"
  end

  local topPacks = {}
  for name, bucket in pairs(historyState.profitByPack or {}) do
    topPacks[#topPacks + 1] = { name = name, profitCopper = tonumber(bucket.profitCopper) or 0 }
  end
  table.sort(topPacks, function(a, b)
    if a.profitCopper ~= b.profitCopper then
      return a.profitCopper > b.profitCopper
    end
    return tostring(a.name) < tostring(b.name)
  end)

  return {
    packCount = packCount,
    totalProfitText = totalProfitText,
    favoritePack = favoritePack,
    averageProfitText = averageProfitText,
    dailyProfitText = dailyProfitText,
    topPacks = topPacks
  }
end

local function updateHistoryWindow(force)
  if not ui.historyStats then
    return
  end
  if not force and (not ui.historyWindow or not ui.historyWindow:IsVisible()) then
    return
  end

  syncAllRecordsHistoryProfit()
  runtime.checkDailyReset()
  -- Read persisted daily aggregates after profit synchronization.
  runtime.recomputeDailyProfit()
  local stats = historyStatistics()
  ui.historyStats.packs:SetText("Packs Turn-ins: " .. tostring(stats.packCount))
  ui.historyStats.totalProfit:SetText("Total Profit: " .. stats.totalProfitText)
  ui.historyStats.favorite:SetText("Favourite pack: " .. fitDisplayText(stats.favoritePack, 30))
  ui.historyStats.average:SetText("Average Pack Profit: " .. stats.averageProfitText)
  ui.historyStats.dailyProfit:SetText("Daily Profit (UTC-2): " .. stats.dailyProfitText)

  if ui.dailyHistoryRows then
    local dayKeys = {}
    for k in pairs(historyState.dailyHistory or {}) do
      table.insert(dayKeys, k)
    end
    table.sort(dayKeys, function(a, b) return a > b end)
    for i = 1, MAX_DAILY_HISTORY_ROWS do
      local lbl = ui.dailyHistoryRows[i]
      if not lbl then break end
      local dk = dayKeys[i]
      if dk then
        local d = historyState.dailyHistory[dk]
        local profitText = formatMoney(d.profitCopper or 0)
        if (d.unknownCount or 0) > 0 then
          profitText = profitText .. " (+" .. tostring(d.unknownCount) .. " unpriced)"
        end
        lbl:SetText(dayKeyLabel(dk) .. ": " .. profitText)
      else
        lbl:SetText("")
      end
    end
  end

  if ui.runRows then
    local runPages = math.max(1, math.ceil(#historyState.runs / #ui.runRows))
    runtime.runPage = math.max(1, math.min(runtime.runPage, runPages))
    if ui.runPageLabel then
      ui.runPageLabel:SetText(string.format("Runs %d/%d (%d)", runtime.runPage, runPages, #historyState.runs))
    end
    for i = 1, #ui.runRows do
      local row = ui.runRows[i]
      local run = historyState.runs[#historyState.runs - (runtime.runPage - 1) * #ui.runRows - i + 1]
      if run then
        local day = math.floor(((tonumber(run.startedAt) or 0) - UTC_MINUS_2_OFFSET) / 86400)
        local suffix = (tonumber(run.unknownCount) or 0) > 0
          and (" + " .. tostring(run.unknownCount) .. " unpriced") or ""
        local at = os and os.date and os.date("!%H:%M", (tonumber(run.startedAt) or 0) - UTC_MINUS_2_OFFSET) or ""
        row:SetText(dayKeyLabel(day) .. " " .. at .. ": " .. tostring(run.count) .. " packs | "
          .. formatMoney(run.profitCopper) .. suffix)
      else
        row:SetText("")
      end
    end
  end

  if ui.topPackRows then
    local top = stats.topPacks or {}
    for i = 1, 3 do
      local lbl = ui.topPackRows[i]
      if lbl then
        local entry = top[i]
        if entry then
          lbl:SetText(tostring(i) .. ". " .. fitDisplayText(entry.name, 20) .. ": " .. formatMoney(entry.profitCopper))
        else
          lbl:SetText("")
        end
      end
    end
  end
end

local function createPopupWindow(name, width, height, anchorTarget, skipAnchor)
  local window = UIParent:CreateWidget("window", widgetName(name), "UIParent")
  if not window then
    error("failed to create popup window: " .. tostring(name))
  end

  window:SetExtent(width, height)
  if not skipAnchor then
    window:AddAnchor("CENTER", anchorTarget or "UIParent", 0, 0)
  end
  window:SetTitleText("")
  pcall(function()
    window:SetCloseOnEscape(true)
  end)
  pcall(function()
    window:EnablePick(true)
  end)
  pcall(function()
    window:EnableDrawables("background")
  end)
  pcall(function()
    window:EnableDrawablesWithChildren("background")
  end)
  addNativeWindowSkin(window, width, height)
  local tint = addSizedParchmentTint(window, name .. "Tint", width, height)
  local border = addWindowBorder(window, name, width, height)
  window:Show(false)
  -- Optional height resize for the Rates comparison legend. Native skin parts
  -- already follow the window's anchors; the tint and border children need sizing.
  return window, function(newHeight)
    window:SetExtent(width, newHeight)
    tint:SetExtent(width, newHeight)
    border.bottom:RemoveAllAnchors()
    border.bottom:AddAnchor("TOPLEFT", window, 0, newHeight - 2)
    border.left:SetExtent(2, newHeight)
    border.right:SetExtent(2, newHeight)
  end
end

local function resetStatistics()
  runtime.resetHistoryTotals()
  runtime.runPage = 1
  historyState.statsResetThroughId = (tonumber(state.nextId) or 1) - 1
  historyState.migratedFromRecords = true
  runtime.saveHistoryState()
  if ui.resetConfirmWindow then
    ui.resetConfirmWindow:Show(false)
  end
  updateHistoryWindow()
end

local function showResetConfirmation()
  if ui.resetConfirmWindow then
    ui.resetConfirmWindow:Show(true)
  end
end

local function raiseHistoryWindow()
  if ui.historyWindow and ui.historyWindow:IsVisible() then
    pcall(function() ui.historyWindow:Raise() end)
  end
end

local function showHistoryWindow()
  if ui.historyWindow then
    updateHistoryWindow(true)
    local hx, hy = loadHistoryWindowPosition()
    if not hx or not hy then
      -- default: top-right of main window
      local ok, mx, my = pcall(function() return ui.window:GetOffset() end)
      if ok and type(mx) == "number" and type(my) == "number" then
        local uiScale = getUIScaleFactor()
        hx = mx / uiScale + LEDGER_WIDTH
        hy = my / uiScale
      end
    end
    if hx and hy then
      ui.historyWindow:AddAnchor("TOPLEFT", "UIParent", hx, hy)
    end
    ui.historyWindow:Show(true)
    pcall(function() ui.historyWindow:Raise() end)
  end
end

local function hideHistoryWindow()
  if ui.resetConfirmWindow then
    ui.resetConfirmWindow:Show(false)
  end
  if ui.historyWindow then
    ui.historyWindow:Show(false)
  end
end

local function createResetConfirmationWindow(anchorTarget)
  local window = createPopupWindow("TradePacksResetConfirmWindow", RESET_CONFIRM_WIDTH, RESET_CONFIRM_HEIGHT, anchorTarget)
  ui.resetConfirmWindow = window

  local parent = window
  local title = makeLabel("TradePacksResetConfirmTitle", parent, 0, 18, RESET_CONFIRM_WIDTH, 20, "Reset Statistics?")
  styleText(title, TEXT_BROWN, ALIGN_CENTER or CENTER)
  makeTextButton("TradePacksResetConfirmClose", parent, RESET_CONFIRM_WIDTH - 34, 18, 20, 22, "X", function()
    window:Show(false)
  end)

  local message = makeLabel("TradePacksResetConfirmMessage", parent, 28, 54, RESET_CONFIRM_WIDTH - 56, 34, "Wipe the current statistics?")
  styleText(message, TEXT_BROWN, ALIGN_CENTER or CENTER)

  makeButton("TradePacksResetConfirmCancel", parent, 54, 104, 82, 28, "Cancel", function()
    window:Show(false)
  end)
  makeButton("TradePacksResetConfirmWipe", parent, 180, 104, 82, 28, "Wipe", function()
    resetStatistics()
  end)
end

local function createHistoryWindow()
  local window = createPopupWindow("TradePacksHistoryWindow", HISTORY_WIDTH, HISTORY_HEIGHT, nil, true)
  ui.historyWindow = window
  pcall(function() window:EnableDrag(true) end)
  pcall(function() window:SetDragCondition(DC_ALWAYS) end)
  window:SetHandler("OnDragStart", function(self)
    self:StartMoving()
  end)
  window:SetHandler("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local ok, x, y = pcall(function() return self:GetOffset() end)
    if ok and type(x) == "number" and type(y) == "number" then
      local uiScale = getUIScaleFactor()
      saveHistoryWindowPosition(x * uiScale, y * uiScale)
    end
  end)

  local parent = window
  local title = makeLabel("TradePacksHistoryTitle", parent, 0, 18, HISTORY_WIDTH, 20, "History")
  styleText(title, TEXT_BROWN, ALIGN_CENTER or CENTER)
  makeTextButton("TradePacksHistoryClose", parent, HISTORY_WIDTH - 34, 18, 20, 22, "X", function()
    hideHistoryWindow()
  end)
  makeSeparator("TradePacksHistorySeparator", parent, 24, 48, HISTORY_WIDTH - 48)

  ui.historyStats = {
    packs = makeLabel("TradePacksHistoryPacksTurnIns", parent, 34, 68, HISTORY_WIDTH - 68, 20, "Packs Turn-ins: 0"),
    totalProfit = makeLabel("TradePacksHistoryTotalProfit", parent, 34, 96, HISTORY_WIDTH - 68, 20, "Total Profit: 0g"),
    favorite = makeLabel("TradePacksHistoryFavouritePack", parent, 34, 124, HISTORY_WIDTH - 68, 20, "Favourite pack: -"),
    average = makeLabel("TradePacksHistoryAveragePackProfit", parent, 34, 152, HISTORY_WIDTH - 68, 20, "Average Pack Profit: 0g"),
    dailyProfit = makeLabel("TradePacksHistoryDailyProfit", parent, 34, 180, HISTORY_WIDTH - 68, 20, "Daily Profit (UTC-2): 0g")
  }

  for _, label in pairs(ui.historyStats) do
    styleText(label, TEXT_BROWN, ALIGN_CENTER or CENTER)
  end

  makeSeparator("TradePacksHistorySeparator2", parent, 24, 210, HISTORY_WIDTH - 48)

  local breakdownHeader = makeLabel("TradePacksHistoryBreakdownHeader", parent, 34, 226, HISTORY_WIDTH - 68, 20, "Daily Breakdown:")
  styleText(breakdownHeader, TEXT_BROWN, ALIGN_LEFT or LEFT)

  ui.dailyHistoryRows = {}
  for i = 1, MAX_DAILY_HISTORY_ROWS do
    local lbl = makeLabel("TradePacksHistoryDayRow" .. tostring(i), parent, 34, 226 + i * 22, HISTORY_WIDTH - 68, 20, "")
    styleText(lbl, TEXT_BROWN, ALIGN_LEFT or LEFT)
    ui.dailyHistoryRows[i] = lbl
  end

  makeSeparator("TradePacksHistorySeparator3", parent, 24, 384, HISTORY_WIDTH - 48)
  local topHeader = makeLabel("TradePacksHistoryTopHeader", parent, 34, 396, HISTORY_WIDTH - 68, 20, "Most Profitable Packs:")
  styleText(topHeader, TEXT_BROWN, ALIGN_LEFT or LEFT)
  ui.topPackRows = {}
  for i = 1, 3 do
    local lbl = makeLabel("TradePacksHistoryTopRow" .. tostring(i), parent, 34, 396 + i * 22, HISTORY_WIDTH - 68, 20, "")
    styleText(lbl, TEXT_BROWN, ALIGN_LEFT or LEFT)
    ui.topPackRows[i] = lbl
  end

  makeSeparator("TradePacksRunSeparator", parent, 24, 484, HISTORY_WIDTH - 48)
  local runHeader = makeLabel("TradePacksRunHeader", parent, 34, 496, HISTORY_WIDTH - 68, 20, "Trade runs (30 min gap, UTC-2):")
  styleText(runHeader, TEXT_BROWN, ALIGN_LEFT or LEFT)
  ui.runRows = {}
  for i = 1, 4 do
    ui.runRows[i] = makeLabel("TradePacksRunRow" .. tostring(i), parent, 34, 496 + i * 23, HISTORY_WIDTH - 68, 20, "")
    styleText(ui.runRows[i], TEXT_BROWN, ALIGN_LEFT or LEFT)
  end
  makeTextButton("TradePacksRunNewer", parent, 36, 614, 45, 22, "<", function()
    runtime.runPage = runtime.runPage - 1
    updateHistoryWindow()
  end)
  ui.runPageLabel = makeLabel("TradePacksRunPage", parent, 91, 614, 178, 22, "Runs 1/1")
  styleText(ui.runPageLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
  makeTextButton("TradePacksRunOlder", parent, 279, 614, 45, 22, ">", function()
    runtime.runPage = runtime.runPage + 1
    updateHistoryWindow()
  end)
  makeButton("TradePacksHistoryResetStatistics", parent, 108, 650, 144, 30, "Reset Statistics", function()
    showResetConfirmation()
  end)

  createResetConfirmationWindow(window)
  updateHistoryWindow()
end

local function setDetailLine(index, text, color)
  if not ui.detailLines or not ui.detailLines[index] then
    return
  end
  local label = ui.detailLines[index]
  label:SetText(text or "")
  styleText(label, color or TEXT_BROWN)
  showWidget(label, text ~= nil and text ~= "")
end

local function materialCostLabel(record)
  if not record then
    return "Materials: ?"
  end
  if record.costStatus == "manual" then
    return "Materials: " .. formatMoney(record.costCopper) .. " (manual)"
  end
  if record.costStatus == "preset" then
    return "Materials: " .. formatMoney(record.costCopper)
      .. (record.costSource == "rule" and " (pack rule)" or " (preset)")
  end
  if record.costStatus == "snapshot" then
    return "Materials: " .. formatMoney(record.costCopper) .. " (snapshotted)"
  end
  if record.costStatus == "pricing" then
    return "Materials: pricing recipe materials"
  end
  return "Materials: unavailable"
end

local function fallbackMoneyPriceCopper(record)
  local cargoName = compactText(record and record.cargoName):lower()
  if cargoName:find("fertilizer", 1, true) then
    return 75 * 100
  end
  if cargoName:find("aged", 1, true) then
    return 1 * 10000
  end
  return 50 * 100
end

local function payoutPriceLabel(record)
  if not record then
    return nil
  end

  if payoutDisplayName(record) == "Money" then
    return "Money: " .. formatMoney(fallbackMoneyPriceCopper(record))
  end

  local itemType = resolvePayoutItemType(record)
  -- Prefer this record's locked snapshot so the Details payout price matches the
  -- frozen Total/Profit instead of drifting with the live auction price.
  local price = tonumber(record.payoutUnitPriceCopper) or getPrice(itemType, isOnyxPayout(record))
  local name = payoutDisplayName(record)
  if price then
    return name .. ": " .. formatMoney(price)
  end
  if runtime.auctionStatus then
    return name .. ": " .. runtime.auctionStatus
  end
  return name .. ": No price"
end

local function materialDetailText(material)
  if isIgnoredCostMaterial(material) then
    return string.format("%dx %s (bound quest reward)", tonumber(material.count) or 0, material.name or "?")
  end

  local unitText = material.unitPriceCopper and formatMoney(material.unitPriceCopper) or "?"
  local totalText = material.totalPriceCopper and formatMoney(material.totalPriceCopper) or "?"
  return string.format("%dx %s @ %s = %s", tonumber(material.count) or 0, material.name or "?", unitText, totalText)
end

local function formatTimestamp(seconds)
  seconds = tonumber(seconds)
  if not seconds or seconds <= 0 then
    return nil
  end
  if os and type(os.date) == "function" then
    local ok, text = pcall(function()
      return os.date("%Y-%m-%d %H:%M", seconds)
    end)
    if ok and type(text) == "string" then
      return text
    end
  end
  return nil
end

local function soldAtDetailText(record)
  local text = formatTimestamp(record and record.soldAt)
  if not text then
    return nil
  end
  return "Turned in: " .. text
end

runtime.priceAgeText = function(timestamp)
  timestamp = tonumber(timestamp)
  if not timestamp or timestamp <= 0 then return "time unknown" end
  local elapsed = math.max(0, nowSeconds() - timestamp)
  if elapsed < 60 then return "now" end
  if elapsed < 3600 then return tostring(math.floor(elapsed / 60)) .. "m ago" end
  if elapsed < 86400 then return tostring(math.floor(elapsed / 3600)) .. "h ago" end
  return tostring(math.floor(elapsed / 86400)) .. "d ago"
end

runtime.priceInfoText = function(record)
  local costSource = "unknown"
  if record.costStatus == "manual" then
    costSource = "manual " .. runtime.priceAgeText(record.manualCostSetAt)
  elseif record.costStatus == "preset" then
    costSource = record.costSource == "rule" and "pack rule" or "preset"
  elseif record.costStatus == "snapshot" then
    costSource = "auction snapshot " .. runtime.priceAgeText(record.materialPricedAt)
  end
  local payoutSource = "unpriced"
  if tonumber(record.payoutCopper) then
    payoutSource = "fixed money"
  elseif tonumber(record.payoutUnitPriceCopper) then
    payoutSource = "auction snapshot " .. runtime.priceAgeText(record.payoutPricedAt)
  else
    local key = normalizeKey(resolvePayoutItemType(record))
    local cached = key and state.prices[key]
    if type(cached) == "table" and tonumber(cached.updatedAt) then
      payoutSource = "auction estimate " .. runtime.priceAgeText(cached.updatedAt)
    end
  end
  return "Sources: cost " .. costSource .. " | payout " .. payoutSource
end

local function updateDetailPanel(records, startIndex)
  if not ui.detailTitle then
    return
  end

  local selected = runtime.selectedRecordId and findRecord(runtime.selectedRecordId)
  if selected and not recordPassesFilter(selected) then
    selected = nil
  end
  if not selected then
    selected = records[startIndex]
    runtime.selectedRecordId = selected and selected.id or nil
  end

  if not selected then
    ui.detailTitle:SetText("Details")
    setDetailLine(1, "No tradepack selected.")
    for index = 2, DETAIL_LINE_COUNT do
      setDetailLine(index, "")
    end
    return
  end

  ui.detailTitle:SetText("Details: " .. cargoDisplayName(selected))
  local payoutText = payoutPriceLabel(selected) or ""
  local costText = materialCostLabel(selected) or ""
  local combinedLine = payoutText .. "   " .. costText
  local combinedColor = selected.costStatus == "unknown" and TEXT_RED or TEXT_BROWN
  setDetailLine(1, combinedLine, combinedColor)
  local laborRule = runtime.costRules.labor[selected.cargoName]
  local laborText = formatMoney(selected.laborCostCopper)
  local totalLabel = "Total cost: "
  if type(laborRule) ~= "table" and not tonumber(selected.laborCostCopper) then
    laborText = "not set (Labor editor)"
    totalLabel = "Known cost: "
  elseif (tonumber(laborRule.points) or 0) > 0 and not tonumber(selected.laborCostCopper) then
    laborText = "waiting for auction price"
  end
  setDetailLine(2, "Transport: " .. formatMoney(selected.transportCostCopper or 0)
    .. "   Labor: " .. laborText
    .. "   " .. totalLabel .. formatMoney(runtime.totalCost(selected)))
  setDetailLine(3, soldAtDetailText(selected) or "")

  setDetailLine(4, runtime.priceInfoText(selected))
  local materials = ensureRecordMaterials(selected)
  if not materials then
    if selected.costStatus == "preset" then
      setDetailLine(5, "Preset cost is used for this cargo.")
    elseif selected.costStatus == "manual" then
      setDetailLine(5, "Manual material cost is used for this cargo.")
    else
      setDetailLine(5, "Recipe data is missing for this pack.", TEXT_RED)
    end
    for index = 6, DETAIL_LINE_COUNT do setDetailLine(index, "") end
    return
  end

  local maxMaterials = DETAIL_LINE_COUNT - 4
  local shown = math.min(#materials, maxMaterials)
  for index = 1, shown do
    setDetailLine(index + 4, materialDetailText(materials[index]))
  end
  for index = shown + 5, DETAIL_LINE_COUNT do setDetailLine(index, "") end
end

runtime.toggleArchive = function(recordId)
  local record = findRecord(recordId)
  if not record then return end
  local wasArchived = record.archived
  record.archived = not wasArchived
  if not saveState() then record.archived = wasArchived; return end
  if runtime.selectedRecordId == recordId and runtime.filter ~= "archived" then
    runtime.selectedRecordId = nil
  end
  refreshUi()
end

local function archiveOrRestoreRecords()
  local changed = {}
  local restoring = runtime.filter == "archived"
  for _, record in ipairs(state.records) do
    if (restoring and record.archived)
      or (not restoring and not record.archived and getRecordStatus(record) == "Delivered") then
      changed[#changed + 1] = record
      record.archived = not restoring
    end
  end
  if #changed == 0 then return end
  if not saveState() then
    for _, record in ipairs(changed) do record.archived = restoring end
    return
  end
  runtime.selectedRecordId = nil
  refreshUi()
end

refreshUi = function()
  if not ui.window then
    return
  end
  if not ledgerIsVisible() then
    updateHistoryWindow()
    return
  end
  if ui.packMenu then ui.packMenu:Show(false) end

  markDueRecords()
  sortRecords()
  local records = filteredRecords()
  -- sortRecords() gives the default newest-first order; re-sort the filtered list
  -- when the user has picked a column. Done here (not in sortRecords) so the value
  -- helpers below are in scope. sortValue is local to refreshUi, so it adds no
  -- top-level local against the 200-local ceiling.
  if runtime.sortKey and runtime.sortKey ~= "soldAt" then
    local key, dir = runtime.sortKey, runtime.sortDir
    local function sortValue(rec)
      if key == "name" then
        return (cargoDisplayName(rec) or ""):lower()
      elseif key == "total" then
        return recordPayoutValue(rec)
      elseif key == "cost" then
        return runtime.totalCost(rec)
      elseif key == "profit" then
        return recordProfit(rec)
      elseif key == "margin" then
        local p, c = recordProfit(rec), runtime.totalCost(rec)
        if p and c and c > 0 then
          return p / c
        end
        return nil
      elseif key == "eta" then
        return (tonumber(rec.soldAt) or 0) + DEFAULT_DELAY_SECONDS
      end
      return nil
    end
    table.sort(records, function(a, b)
      local av, bv = sortValue(a), sortValue(b)
      -- Unknown ("?") values always sink to the bottom regardless of direction.
      if av == nil and bv == nil then
        return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
      end
      if av == nil then return false end
      if bv == nil then return true end
      if av == bv then
        return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
      end
      if dir == "asc" then
        return av < bv
      end
      return av > bv
    end)
  end
  local pageCount = math.max(1, math.ceil(#records / runtime.visibleRowCount))
  runtime.pageCount = pageCount
  if runtime.page > pageCount then
    runtime.page = pageCount
  end
  if runtime.page < 1 then
    runtime.page = 1
  end

  updateSummary(records)
  ui.pageLabel:SetText(string.format("Page %d/%d", runtime.page, pageCount))

  local startIndex = (runtime.page - 1) * runtime.visibleRowCount + 1
  updateFilterButtons()
  if ui.headerLabels then
    for key, h in pairs(ui.headerLabels) do
      local marker = ""
      if runtime.sortKey == key then
        marker = (runtime.sortDir == "asc") and " ^" or " v"
      end
      h.label:SetText(h.base .. marker)
    end
  end

  for rowIndex = 1, #ui.rows do
    local row = ui.rows[rowIndex]
    local selection = ui.selectionHighlights and ui.selectionHighlights[rowIndex]
    local deleteBtn = ui.deleteButtons and ui.deleteButtons[rowIndex]
    local record = rowIndex <= runtime.visibleRowCount and records[startIndex + rowIndex - 1] or nil
    row.recordId = record and record.id or nil
    row.currentStatus = record and getRecordStatus(record) or nil

    if record then
      local status = getRecordStatus(record)
      local profit = recordProfit(record)
      local readyAt = (tonumber(record.soldAt) or 0) + DEFAULT_DELAY_SECONDS
      local remaining = readyAt - nowSeconds()

      row.rownum:SetText(tostring(rowIndex))
      local nameChars = 27 + math.floor((runtime.ledgerWidth - LEDGER_WIDTH) / 8)
      row.name:SetText(fitDisplayText(cargoDisplayName(record), nameChars))
      row.total:SetText(recordTotalText(record))
      row.cost:SetText(recordCostText(record))
      row.profit:SetText(profit and formatMoney(profit) or "?")
      row.margin:SetText(runtime.recordMarginText(record))
      if record.archived then
        row.time:SetText("Archived")
        styleText(row.time, TEXT_BROWN)
        styleText(row.name, TEXT_BROWN)
      elseif status == "Waiting" then
        row.time:SetText(formatDuration(remaining))
        styleText(row.time, TEXT_BROWN)
        styleText(row.name, TEXT_BROWN)
      elseif status == "Delivered" then
        row.time:SetText("Delivered")
        styleText(row.time, TEXT_GREEN)
        styleText(row.name, TEXT_GREEN)
      end

      for _, widget in pairs(row) do
        showWidget(widget, true)
      end
      deleteBtn:SetText(record.archived and "R" or "A")
      styleText(deleteBtn, record.archived and TEXT_GREEN or TEXT_RED)
      showWidget(deleteBtn, true)
      showWidget(selection, runtime.selectedRecordId == record.id)
    else
      for _, widget in pairs(row) do
        showWidget(widget, false)
      end
      showWidget(deleteBtn, false)
      showWidget(selection, false)
    end
  end

  updateDetailPanel(records, startIndex)
  updateHistoryWindow()
end

updateFilterButtons = function()
  if not ui.filterButtons then
    return
  end
  local activeFilter = runtime.filter
  for filterId, btn in pairs(ui.filterButtons) do
    if filterId == activeFilter then
      styleText(btn, TEXT_GREEN)
    else
      styleText(btn, TEXT_BROWN)
    end
  end
  if ui.archiveButton then
    runtime.setButtonText(ui.archiveButton, activeFilter == "archived" and "Restore All" or "Archive Done")
  end
end

local function setFilter(filter)
  runtime.filter = filter
  runtime.page = 1
  updateFilterButtons()
  refreshUi()
end

runtime.createPackMenu = function(parent)
  -- The built-in combo box gives its dropdown the selector's width. Keep the
  -- 152px filter button, and show complete pack names in a wider popup.
  local packMenuRows, packMenuWidth = 9, 500
  local namesPerPage = packMenuRows - 1
  ui.packMenu = createWidget("emptywidget", "TradePacksPackMenu", parent,
    133, 174, packMenuWidth, 256)
  pcall(function() ui.packMenu:SetDrawPriority(100) end)
  pcall(function() ui.packMenu:EnablePick(true) end)
  pcall(function() ui.packMenu:Clickable(true) end)
  pcall(function() ui.packMenu:EnableDrawables("background") end)
  local menuColor = DARK_MODE and {0.08, 0.07, 0.06, 1}
    or {0.96, 0.89, 0.69, 1}
  local okMenuBg, menuBg = pcall(function()
    return ui.packMenu:CreateColorDrawable(
      menuColor[1], menuColor[2], menuColor[3], menuColor[4], "background")
  end)
  if okMenuBg and menuBg then
    menuBg:AddAnchor("TOPLEFT", ui.packMenu, 0, 0)
    menuBg:AddAnchor("BOTTOMRIGHT", ui.packMenu, 0, 0)
  end
  ui.packMenuBorder = addWindowBorder(ui.packMenu, "TradePacksPackMenu", packMenuWidth, 256)
  ui.packMenuRows = {}
  ui.packMenuChoices = {}
  ui.packMenuPage = 1
  local updatePackMenu
  for i = 1, packMenuRows do
    local rowIndex = i
    local row = makeTextButton("TradePacksPackChoice" .. i, ui.packMenu,
      12, 8 + (i - 1) * 24, packMenuWidth - 24, 22, "", function()
        local choiceIndex = rowIndex == 1 and 1
          or (2 + (ui.packMenuPage - 1) * namesPerPage + rowIndex - 2)
        local choice = ui.packMenuChoices[choiceIndex]
        if not choice then return end
        runtime.packFilter = choice.value
        runtime.page = 1
        runtime.setButtonText(ui.packFilterButton,
          choice.value and ("Pack: " .. fitDisplayText(choice.text, 12)) or "Pack: All")
        ui.packMenu:Show(false)
        refreshUi()
      end)
    styleText(row, TEXT_BROWN, ALIGN_LEFT or LEFT)
    pcall(function() row.style:SetFontSize(13) end)
    ui.packMenuRows[i] = row
  end
  ui.packMenuPrev = makeTextButton("TradePacksPackMenuPrev", ui.packMenu,
    12, 228, 65, 22, "< Prev", function()
      if ui.packMenuPage > 1 then
        ui.packMenuPage = ui.packMenuPage - 1
        updatePackMenu()
      end
    end)
  ui.packMenuPageLabel = makeLabel("TradePacksPackMenuPage", ui.packMenu,
    202, 228, 96, 22, "Page 1/1")
  styleText(ui.packMenuPageLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
  ui.packMenuNext = makeTextButton("TradePacksPackMenuNext", ui.packMenu,
    423, 228, 65, 22, "Next >", function()
      if ui.packMenuPage * namesPerPage < #ui.packMenuChoices - 1 then
        ui.packMenuPage = ui.packMenuPage + 1
        updatePackMenu()
      end
    end)
  updatePackMenu = function()
    local count = #ui.packMenuChoices - 1
    local pageCount = math.max(1, math.ceil(count / namesPerPage))
    ui.packMenuPage = math.max(1, math.min(ui.packMenuPage, pageCount))
    local startIndex = 2 + (ui.packMenuPage - 1) * namesPerPage
    local visibleCount = 1 + math.min(namesPerPage, count - (ui.packMenuPage - 1) * namesPerPage)
    local menuHeight = 12 + visibleCount * 24 + 28
    ui.packMenu:SetExtent(packMenuWidth, menuHeight)
    ui.packMenuBorder.bottom:RemoveAllAnchors()
    ui.packMenuBorder.bottom:AddAnchor("TOPLEFT", ui.packMenu, 0, menuHeight - 2)
    ui.packMenuBorder.left:SetExtent(2, menuHeight)
    ui.packMenuBorder.right:SetExtent(2, menuHeight)
    for i = 1, packMenuRows do
      local choice = ui.packMenuChoices[i == 1 and 1 or (startIndex + i - 2)]
      local row = ui.packMenuRows[i]
      if choice then
        row:SetText(choice.text)
        styleText(row, choice.value == runtime.packFilter and TEXT_GREEN or TEXT_BROWN,
          ALIGN_LEFT or LEFT)
      end
      showWidget(row, choice ~= nil)
    end
    local footerY = 12 + visibleCount * 24
    for _, entry in ipairs({
      {ui.packMenuPrev, 12}, {ui.packMenuPageLabel, 202}, {ui.packMenuNext, 423}
    }) do
      entry[1]:RemoveAllAnchors()
      entry[1]:AddAnchor("TOPLEFT", ui.packMenu, entry[2], footerY)
    end
    ui.packMenuPageLabel:SetText(string.format("Page %d/%d", ui.packMenuPage, pageCount))
    showWidget(ui.packMenuPrev, ui.packMenuPage > 1)
    showWidget(ui.packMenuNext, ui.packMenuPage < pageCount)
  end
  runtime.togglePackDropdown = function()
    if ui.packMenu:IsVisible() then
      ui.packMenu:Show(false)
      return
    end
    local names = {}
    for _, record in ipairs(state.records) do
      if type(record.cargoName) == "string" and record.cargoName ~= "" then
        names[record.cargoName] = true
      end
    end
    local sortedNames = {}
    for name in pairs(names) do sortedNames[#sortedNames + 1] = name end
    table.sort(sortedNames, function(a, b)
      return a:lower() == b:lower() and a < b or a:lower() < b:lower()
    end)
    ui.packMenuChoices = {{text = "All packs", value = nil}}
    for _, name in ipairs(sortedNames) do
      ui.packMenuChoices[#ui.packMenuChoices + 1] = {text = name, value = name}
    end
    ui.packMenuPage = 1
    if runtime.packFilter then
      for i, choice in ipairs(ui.packMenuChoices) do
        if choice.value == runtime.packFilter then
          ui.packMenuPage = math.floor((i - 2) / namesPerPage) + 1
          break
        end
      end
    end
    updatePackMenu()
    ui.packMenu:Show(true)
    pcall(function() ui.packMenu:Raise() end)
  end
  ui.packMenu:Show(false)

end

runtime.createCostEditor = function(kind)
  local title = ({transport = "Transport", labor = "Labor", materials = "Materials"})[kind]
  local prefix = "TradePacks" .. title .. "Editor"
  local height = 400
  local window = UIParent:CreateWidget("window", widgetName(prefix .. "Window"), "UIParent")
  if not window then error("failed to create " .. title .. " editor") end
  window:SetExtent(560, height)
  window:AddAnchor("CENTER", "UIParent", 0, 0)
  window:SetTitleText("")
  pcall(function() window:SetCloseOnEscape(true) end)
  pcall(function() window:EnableDrag(true) end)
  window:SetHandler("OnDragStart", function(self) self:StartMoving() end)
  window:SetHandler("OnDragStop", function(self) self:StopMovingOrSizing() end)
  pcall(function() window:EnableDrawables("background") end)
  pcall(function() window:EnableDrawablesWithChildren("background") end)
  addNativeWindowSkin(window, 560, height)
  addSizedParchmentTint(window, prefix .. "Tint", 560, height)
  addWindowBorder(window, prefix, 560, height)
  local heading = makeLabel(prefix .. "Title", window, 20, 16, 520, 26, title .. " cost by pack")
  styleText(heading, TEXT_BROWN, ALIGN_CENTER or CENTER)
  makeTextButton(prefix .. "Close", window, 523, 17, 22, 22, "X", function() window:Show(false) end)
  makeSeparator(prefix .. "TopLine", window, 20, 48, 520)

  local selectedPack = nil
  local fields = {}
  local auto = {}
  local selector = makeButton(prefix .. "Select", window, 25, 61, 200, 28, "Choose pack", function()
    if window.packMenu then
      window.packMenu:Show(not window.packMenu:IsVisible())
      if window.packMenu:IsVisible() then pcall(function() window.packMenu:Raise() end) end
    end
  end)
  local status = makeLabel(prefix .. "Status", window, 235, 64, 300, 22, "Select a pack type")
  styleText(status, TEXT_BROWN, ALIGN_LEFT or LEFT)

  local function numberField(name, x, y, width, initial)
    local box = makeEditbox(prefix .. name, window, x, y, width, 24, tostring(initial or 0))
    if not box then error("editbox unavailable") end
    fields[name] = box
    return box
  end
  local function moneyFields(base, y)
    numberField(base .. "G", 292, y, 46)
    numberField(base .. "S", 346, y, 42)
    numberField(base .. "C", 396, y, 42)
  end
  local function label(name, x, y, width, value)
    local widget = makeLabel(prefix .. name, window, x, y, width, 22, value)
    styleText(widget, TEXT_BROWN, ALIGN_LEFT or LEFT)
    return widget
  end
  label("QtyHeading", 196, 99, 70, kind == "labor" and "Points" or "Qty")
  if kind ~= "labor" then
    label("GoldHeading", 292, 99, 46, "Gold")
    label("SilverHeading", 346, 99, 45, "Silver")
    label("CopperHeading", 396, 99, 50, "Copper")
  end
  local autoButtons = {}
  local materialRows, materialEntries, boundEntries = {}, {}, {}
  if kind == "transport" then
    for _, entry in ipairs({{"fuel", "Eco-Friendly Fuel", 126}, {"grease", "Axle Grease", 170}}) do
      local key, itemName, y = entry[1], entry[2], entry[3]
      label(key .. "Name", 26, y + 2, 160, itemName)
      numberField(key .. "Qty", 198, y, 58)
      moneyFields(key, y)
      autoButtons[key] = makeButton(prefix .. key .. "Auto", window, 455, y, 75, 26, "AUTO", function()
        auto[key] = not auto[key]
        runtime.setButtonText(autoButtons[key], auto[key] and "AUTO On" or "AUTO")
        if window.saveRule then window.saveRule() end
      end)
    end
    label("UnitHint", 26, 216, 510, "Prices are per item. AUTO uses the lowest matching auction price.")
  elseif kind == "labor" then
    label("LaborName", 26, 128, 160, "Labor used")
    numberField("points", 198, 126, 58)
    local source = label("LaborSource", 26, 172, 510, "Lowest labor item: searching auction house")
    local rate = label("LaborRate", 26, 200, 510, "")
    label("LaborHint", 26, 231, 510,
      "Cost = labor used x cheapest auction price per restored labor.")
    window.refreshLaborQuote = function()
      local item = runtime.cheapestLaborItem()
      if item then
        local entry = state.prices[normalizeNameKey(item.name)]
        local age = entry and tonumber(entry.updatedAt)
        local stale = not age or nowSeconds() - age > 6 * 60 * 60
        source:SetText((stale and "Last known lowest: " or "Lowest: ")
          .. fitDisplayText(item.name, stale and 46 or 53))
        rate:SetText(formatMoney(item.price) .. " / " .. item.labor
          .. " labor = " .. string.format("%.2f", item.price / item.labor) .. "c per point")
      else
        source:SetText("Lowest labor item: no auction price yet")
        rate:SetText("Refresh prices to calculate labor cost.")
      end
      if selectedPack and type(runtime.costRules.labor[selectedPack]) == "table" then
        local cost = runtime.ruleCost("labor", selectedPack)
        status:SetText(cost and ("Saved labor cost: " .. formatMoney(cost))
          or "Saved; waiting for a labor auction price")
      end
    end
    makeButton(prefix .. "Refresh", window, 25, 272, 140, 28,
      "Refresh prices", function() startAuctionRefresh(true, false) end)
    window.refreshLaborQuote()
  else
    local totalLabel = label("MaterialName", 26, 128, 160, "Materials total")
    moneyFields("total", 126)
    local hint = label("MaterialHint", 26, 310, 510,
      "Recipe item prices are per unit. AUTO uses the auction house.")
    for i = 1, 4 do
      local key, y = "mat" .. i, 126 + (i - 1) * 44
      local nameLabel = label(key .. "Name", 26, y + 2, 165, "")
      local qtyBox = numberField(key .. "Qty", 198, y, 58)
      moneyFields(key, y)
      autoButtons[key] = makeButton(prefix .. key .. "Auto", window, 455, y, 75, 26,
        "AUTO", function()
          auto[key] = not auto[key]
          runtime.setButtonText(autoButtons[key], auto[key] and "AUTO On" or "AUTO")
          if window.saveRule then window.saveRule() end
        end)
      materialRows[i] = {nameLabel, qtyBox, fields[key .. "G"], fields[key .. "S"],
        fields[key .. "C"], autoButtons[key]}
    end
    window.totalMaterialWidgets = {totalLabel, fields.totalG, fields.totalS, fields.totalC}
    window.materialHint = hint
  end

  local function readInt(name, max)
    local raw = fields[name]:GetText()
    local value = tonumber(raw or "")
    if not value or value < 0 or value ~= math.floor(value) or value > max then return nil end
    return value
  end
  local function readMoney(base)
    local g, s, c = readInt(base .. "G", 999999), readInt(base .. "S", 99), readInt(base .. "C", 99)
    if not g or not s or not c then return nil end
    return g * 10000 + s * 100 + c
  end
  local function setMoney(base, value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    fields[base .. "G"]:SetText(tostring(math.floor(value / 10000)))
    fields[base .. "S"]:SetText(tostring(math.floor(value / 100) % 100))
    fields[base .. "C"]:SetText(tostring(value % 100))
  end
  local function loadPack(name)
    selectedPack = name
    runtime.setButtonText(selector, fitDisplayText(name, 19))
    status:SetText("Editing " .. fitDisplayText(name, 28))
    if kind == "transport" then
      local rule = runtime.costRules.transport[name] or {}
      for key in pairs(runtime.transportItems) do
        fields[key .. "Qty"]:SetText(tostring(rule[key .. "Qty"] or 0))
        auto[key] = rule[key .. "Auto"] == true
        setMoney(key, rule[key .. "Price"] or getNamedPrice(runtime.transportItems[key]))
        runtime.setButtonText(autoButtons[key], auto[key] and "AUTO On" or "AUTO")
      end
    elseif kind == "labor" then
      local rule = runtime.costRules.labor[name] or {}
      fields.points:SetText(tostring(rule.points or 0))
      window.refreshLaborQuote()
    else
      materialEntries, boundEntries = {}, {}
      local recipe = getPackMaterials(name)
      local savedRule = runtime.costRules.materials[name]
      if recipe then
        for _, material in ipairs(recipe) do
          if isIgnoredCostMaterial(material) then boundEntries[#boundEntries + 1] = material
          else materialEntries[#materialEntries + 1] = material end
        end
      end
      local hasRecipe = #materialEntries > 0
      for _, widget in ipairs(window.totalMaterialWidgets) do showWidget(widget, not hasRecipe) end
      for i, row in ipairs(materialRows) do
        local material = materialEntries[i]
        for _, widget in ipairs(row) do showWidget(widget, material ~= nil) end
        if material then
          local key = "mat" .. i
          row[1]:SetText(fitDisplayText(material.name, 19))
          local itemRule = nil
          for _, savedItem in ipairs(savedRule and savedRule.items or {}) do
            if savedItem.name == material.name then itemRule = savedItem; break end
          end
          fields[key .. "Qty"]:SetText(tostring(itemRule and itemRule.qty or material.count))
          auto[key] = itemRule and itemRule.auto == true or false
          setMoney(key, itemRule and itemRule.price or getNamedPrice(material.name))
          runtime.setButtonText(autoButtons[key], auto[key] and "AUTO On" or "AUTO")
        end
      end
      setMoney("total", state.settings.costPresets[name])
      window.materialHint:SetText(hasRecipe
        and "Recipe prices are per item. AUTO tracks each auction price."
        or "No recipe found; enter the pack's total materials cost.")
    end
  end

  local menu = createWidget("emptywidget", prefix .. "PackMenu", window, 25, 91, 500, 250)
  window.packMenu = menu
  pcall(function() menu:SetDrawPriority(100) end)
  pcall(function() menu:EnablePick(true) end)
  pcall(function() menu:EnableDrawables("background") end)
  local okBg, bg = pcall(function()
    return menu:CreateColorDrawable(DARK_MODE and 0.08 or 0.96,
      DARK_MODE and 0.07 or 0.89, DARK_MODE and 0.06 or 0.69, 1, "background")
  end)
  if okBg and bg then
    bg:AddAnchor("TOPLEFT", menu, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", menu, 0, 0)
  end
  local menuBorder = addWindowBorder(menu, prefix .. "PackMenu", 500, 250)
  local names, page = {}, 1
  local menuRows = {}
  local function refreshMenu()
    local pages = math.max(1, math.ceil(#names / 8))
    page = math.max(1, math.min(page, pages))
    local visible = math.min(8, #names - (page - 1) * 8)
    local menuHeight = 42 + visible * 24
    menu:SetExtent(500, menuHeight)
    menuBorder.bottom:RemoveAllAnchors()
    menuBorder.bottom:AddAnchor("TOPLEFT", menu, 0, menuHeight - 2)
    menuBorder.left:SetExtent(2, menuHeight)
    menuBorder.right:SetExtent(2, menuHeight)
    for i, row in ipairs(menuRows) do
      local name = names[(page - 1) * 8 + i]
      if name then row:SetText(name) end
      showWidget(row, name ~= nil)
    end
    window.menuPageLabel:SetText(string.format("Page %d/%d", page, pages))
    showWidget(window.menuPrev, page > 1)
    showWidget(window.menuNext, page < pages)
    for _, widget in ipairs({window.menuPrev, window.menuPageLabel, window.menuNext}) do
      widget:RemoveAllAnchors()
    end
    window.menuPrev:AddAnchor("TOPLEFT", menu, 12, 10 + visible * 24)
    window.menuPageLabel:AddAnchor("TOPLEFT", menu, 201, 10 + visible * 24)
    window.menuNext:AddAnchor("TOPLEFT", menu, 423, 10 + visible * 24)
  end
  for i = 1, 8 do
    local index = i
    menuRows[i] = makeTextButton(prefix .. "Choice" .. i, menu, 12, 8 + (i - 1) * 24,
      476, 22, "", function()
        local name = names[(page - 1) * 8 + index]
        if name then loadPack(name); menu:Show(false) end
      end)
    styleText(menuRows[i], TEXT_BROWN, ALIGN_LEFT or LEFT)
  end
  window.menuPrev = makeTextButton(prefix .. "MenuPrev", menu, 12, 220, 65, 22,
    "< Prev", function() page = page - 1; refreshMenu() end)
  window.menuPageLabel = makeLabel(prefix .. "MenuPage", menu, 201, 220, 98, 22, "Page 1/1")
  styleText(window.menuPageLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
  window.menuNext = makeTextButton(prefix .. "MenuNext", menu, 423, 220, 65, 22,
    "Next >", function() page = page + 1; refreshMenu() end)
  menu:Show(false)

  window.saveRule = function()
    if not selectedPack then status:SetText("Select a pack first"); return false end
    if kind == "transport" then
      local rule = {}
      for key in pairs(runtime.transportItems) do
        local qty, price = readInt(key .. "Qty", 9999), readMoney(key)
        if not qty or not price then status:SetText("Enter valid quantities and prices"); return false end
        rule[key .. "Qty"], rule[key .. "Price"], rule[key .. "Auto"] = qty, price, auto[key]
      end
      if not runtime.commitCostRule(kind, selectedPack, rule) then
        status:SetText("Could not save transport rule"); return false
      end
      if rule.fuelAuto or rule.greaseAuto then startAuctionRefresh(true, false) end
    elseif kind == "labor" then
      local points = readInt("points", 999999)
      if not points then status:SetText("Enter valid labor points"); return false end
      if not runtime.commitCostRule(kind, selectedPack, {points = points}) then
        status:SetText("Could not save labor rule"); return false
      end
      if points > 0 then startAuctionRefresh(true, false) end
    else
      if #materialEntries > 0 then
        local rule = {items = {}, boundItems = {}}
        for i, material in ipairs(materialEntries) do
          local key = "mat" .. i
          local qty, price = readInt(key .. "Qty", 999999), readMoney(key)
          if not qty or not price then
            status:SetText("Enter valid material quantities and prices")
            return false
          end
          rule.items[i] = {name = material.name, resourceId = material.resourceId,
            qty = qty, price = price, auto = auto[key] == true}
        end
        for _, material in ipairs(boundEntries) do
          rule.boundItems[#rule.boundItems + 1] = {
            name = material.name, resourceId = material.resourceId, qty = material.count
          }
        end
        if not runtime.commitCostRule(kind, selectedPack, rule) then
          status:SetText("Could not save materials rule"); return false
        end
        for _, item in ipairs(rule.items) do
          if item.auto then startAuctionRefresh(true, false); break end
        end
        status:SetText("Saved total: " .. formatMoney(runtime.ruleCost(kind, selectedPack)))
        return true
      end
      local cost = readMoney("total")
      if not cost then status:SetText("Enter a valid materials total"); return false end
      local oldPreset = state.settings.costPresets[selectedPack]
      local oldRule = runtime.costRules.materials[selectedPack]
      local changed = {}
      state.settings.costPresets[selectedPack] = cost
      runtime.costRules.materials[selectedPack] = nil
      for _, record in ipairs(state.records) do
        if record.cargoName == selectedPack then
          changed[#changed + 1] = {record, record.costCopper, record.materialCostCopper,
            record.costStatus, record.costSource, record.materials}
          record.costCopper, record.materialCostCopper = cost, nil
          record.costStatus, record.costSource = "preset", "preset"
          record.materials = nil
        end
      end
      if (oldRule and not runtime.saveCostRules()) or not saveState() then
        state.settings.costPresets[selectedPack] = oldPreset
        runtime.costRules.materials[selectedPack] = oldRule
        if oldRule then runtime.saveCostRules() end
        for _, entry in ipairs(changed) do
          entry[1].costCopper, entry[1].materialCostCopper = entry[2], entry[3]
          entry[1].costStatus, entry[1].costSource = entry[4], entry[5]
          entry[1].materials = entry[6]
        end
        status:SetText("Could not save materials cost")
        return false
      end
      syncAllRecordsHistoryProfit()
      if refreshUi then refreshUi() end
    end
    local total = runtime.ruleCost(kind, selectedPack)
      or (kind == "materials" and state.settings.costPresets[selectedPack])
    status:SetText(total and ("Saved total: " .. formatMoney(total))
      or "Saved; waiting for a labor auction price")
    return true
  end
  makeButton(prefix .. "Save", window, 25, height - 44, 112, 28, "Save", function() window.saveRule() end)
  if kind == "materials" then
    makeButton(prefix .. "Auto", window, 146, height - 44, 112, 28, "AUTO", function()
      if #materialEntries == 0 then status:SetText("No recipe for this pack"); return end
      for i in ipairs(materialEntries) do
        local key = "mat" .. i
        auto[key] = true
        runtime.setButtonText(autoButtons[key], "AUTO On")
      end
      window.saveRule()
    end)
  end
  makeButton(prefix .. "Done", window, 427, height - 44, 103, 28,
    "Done", function() window:Show(false) end)
  window.refreshPacks = function()
    local seen = {}
    names = {}
    for _, record in ipairs(state.records) do
      local name = record.cargoName
      if type(name) == "string" and name ~= "" and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    local selected = runtime.selectedRecordId and findRecord(runtime.selectedRecordId)
    if selected and seen[selected.cargoName] then loadPack(selected.cargoName)
    elseif selectedPack and seen[selectedPack] then loadPack(selectedPack)
    elseif names[1] then loadPack(names[1]) end
    page = 1
    for i, name in ipairs(names) do
      if name == selectedPack then page = math.ceil(i / 8); break end
    end
    refreshMenu()
  end
  window:Show(false)
  return window
end

runtime.showCostEditor = function(kind)
  ui.costEditors = ui.costEditors or {}
  if not ui.costEditors[kind] then
    local ok, result = pcall(runtime.createCostEditor, kind)
    if not ok then
      pcall(function() ADDON:ChatLog("TradePacks: " .. kind .. " editor failed: " .. tostring(result)) end)
      return
    end
    ui.costEditors[kind] = result
  end
  local editor = ui.costEditors[kind]
  editor.refreshPacks()
  editor:Show(true)
  pcall(function() editor:Raise() end)
end

runtime.handleLedgerEvent = function(_, eventName, ...)
  if eventName == "SELL_SPECIALTY" then
    local text = select(1, ...)
    local created = parseSaleText(text)
    if not created and runtime.latestSellPreview and runtime.latestSellPreview.cargoName then
      createSaleRecord(runtime.latestSellPreview.cargoName, text)
    end
  elseif eventName == "SELL_SPECIALTY_CONTENT_INFO" then
    cacheSellContent(select(1, ...))
  elseif eventName == "UPDATE_SPECIALTY_RATIO" then
    cacheSellContent(select(1, ...))
  elseif eventName == "BUY_SPECIALTY_CONTENT_INFO" then
    cacheBuyContent(select(1, ...))
  elseif eventName == "CHAT_MESSAGE" then
    local channel, relation, speaker, message = ...
    parseSaleText(message)
  elseif eventName == "CHAT_MSG_ALARM" then
    parseSaleText(select(1, ...))
  elseif eventName == "AUCTION_LOWEST_PRICE" then
    handleLowestPrice(...)
  elseif eventName == "AUCTION_ITEM_SEARCHED" then
    handleAuctionItemSearched()
  end
end

runtime.createAuctionDriver = function()
  -- A ledger's hidden OnUpdate is not driven by the client, and the OPS control
  -- may also be hidden. Keep finite pending quote work on its own empty widget.
  -- Addons may initialize after the initial ENTERED_WORLD event. Reconcile saved
  -- unfinished rows once even if no subsequent world event arrives this session.
  runtime.auctionRefreshPending, runtime.auctionRefreshDelay = true, 2
  local driver = createWidget("window", "TradePacksAuctionDriver", nil, 0, 0, 1, 1)
  ui.auctionDriver = driver
  pcall(function() driver:EnablePick(false) end)
  pcall(function() driver:Clickable(false) end)
  pcall(function() driver:SetCloseOnEscape(false) end)
  local elapsed = 0
  driver:SetHandler("OnUpdate", function(_, milliseconds)
    if runtime.auctionSuspended then return end
    elapsed = elapsed + math.max(0, tonumber(milliseconds) or 0) / 1000
    if elapsed < 0.5 then return end
    local dt = elapsed
    elapsed = 0
    if runtime.auctionRefreshPending then
      runtime.auctionRefreshDelay = runtime.auctionRefreshDelay - dt
      if runtime.auctionRefreshDelay <= 0 then
        runtime.auctionRefreshPending = false
        startAuctionRefresh(true, false, true)
      end
    end
    updateAuctionLookups(dt)
  end)
  driver:SetHandler("OnEvent", function(_, event)
    if event == "ENTERED_LOADING" then
      runtime.auctionSuspended = true
      local key = runtime.activeAuctionKey
      local lookup = key and runtime.namePriceLookups[key]
      if lookup then
        lookup.attempts = math.max(0, (lookup.attempts or 0) - 1)
        lookup.readyAt = nil
        if not queueHasKey(key) then table.insert(runtime.auctionQueue, 1, key) end
      end
      runtime.activeAuctionKey, runtime.lastAuctionSearchKey = nil, nil
    elseif event == "LEFT_LOADING" or event == "ENTERED_WORLD" then
      runtime.auctionSuspended = false
      runtime.lastSearchSentAt = nowSeconds()
      -- Reconcile unfinished records once after entering the world, including
      -- a previous session's incomplete quotes. Fresh cached prices are reused.
      runtime.auctionRefreshPending, runtime.auctionRefreshDelay = true, 2
      elapsed = 0
    end
  end)
  for _, event in ipairs({"ENTERED_LOADING", "LEFT_LOADING", "ENTERED_WORLD"}) do
    driver:RegisterEvent(event)
  end
  driver:Show(true)
end

runtime.initializeRatePanel = function()
  if not TradePacksRateWatch or not ui.window then return end
  local ok, result = pcall(function()
    return TradePacksRateWatch.new({ledger = ui.window, now = nowSeconds,
      scale = getUIScaleFactor, sameData = runtime.sameData, reportSaveError = runtime.reportSaveError,
      popup = createPopupWindow, widget = createWidget, label = makeLabel, editbox = makeEditbox,
      button = makeButton, textButton = makeTextButton, setButtonText = runtime.setButtonText,
      fit = fitDisplayText, money = formatMoney, dark = DARK_MODE,
      costEstimate = runtime.rateCostEstimate})
  end)
  if ok then runtime.ratePanel = result
  else runtime.reportSaveError("rate panel", result) end
end

local function createUi()
  local maxRows = 24
  local okScreen, screenHeight = pcall(function() return UIParent:GetHeight() end)
  if okScreen and type(screenHeight) == "number" and screenHeight > 744 then
    maxRows = math.max(8, math.min(maxRows, 8 + math.floor((screenHeight - 744 - 32) / 30)))
  end
  local savedRows = ADDON:LoadData("TradePacksLedgerRows")
  runtime.visibleRowCount = math.max(8, math.min(maxRows,
    math.floor(tonumber(type(savedRows) == "table" and savedRows.rows) or ROW_COUNT)))
  local initialHeight = 744 + (runtime.visibleRowCount - 8) * 30
  local listOffset = initialHeight - 744
  local window = UIParent:CreateWidget("window", widgetName("TradePacksLedgerWindow"), "UIParent")
  if not window then
    error("failed to create TradePacks ledger window")
  end
  local savedWidth = type(savedRows) == "table" and tonumber(savedRows.width) or LEDGER_WIDTH
  runtime.ledgerWidth = math.max(LEDGER_WIDTH, math.min(LEDGER_MAX_WIDTH,
    math.floor(savedWidth or LEDGER_WIDTH)))
  window:SetExtent(runtime.ledgerWidth, initialHeight)
  window:UseResizing(true)
  window:SetMinResizingExtent(LEDGER_WIDTH, 744)
  window:SetMaxResizingExtent(LEDGER_MAX_WIDTH, 744 + (maxRows - 8) * 30)
  local ledgerX, ledgerY = loadLedgerPosition()
  if ledgerX and ledgerY then
    window:AddAnchor("TOPLEFT", "UIParent", ledgerX, ledgerY)
  else
    window:AddAnchor("CENTER", "UIParent", 0, 0)
  end
  window:SetTitleText("")
  pcall(function()
    window:SetCloseOnEscape(true)
  end)
  pcall(function()
    window:EnablePick(true)
  end)
  pcall(function()
    window:EnableDrag(true)
  end)
  pcall(function()
    window:SetDragCondition(DC_ALWAYS)
  end)
  window:SetHandler("OnDragStart", function(self)
    self:StartMoving()
  end)
  window:SetHandler("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local ok, x, y = pcall(function()
      return self:GetOffset()
    end)
    if ok and type(x) == "number" and type(y) == "number" then
      local uiScale = getUIScaleFactor()
      saveLedgerPosition(x * uiScale, y * uiScale)
    end
  end)
  window:SetHandler("OnMouseDown", function()
    raiseHistoryWindow()
  end)
  pcall(function()
    window:EnableDrawables("background")
  end)
  pcall(function()
    window:EnableDrawablesWithChildren("background")
  end)
  if not addNativeWindowSkin(window, runtime.ledgerWidth, initialHeight) then
    ui.panel = createWidget("emptywidget", "TradePacksBackgroundPanel", window, 0, 0, runtime.ledgerWidth, initialHeight)
    pcall(function()
      ui.panel:SetDrawPriority(-100)
    end)
    pcall(function()
      ui.panel:Lower()
    end)
    ui.backdrop = addBackdrop(ui.panel, initialHeight)
  end
  window:Show(false)

  ui.window = window
  local parent = window
  ui.parchmentTint = addParchmentTint(parent, initialHeight)
  ui.border = addWindowBorder(parent, "TradePacksLedger", runtime.ledgerWidth, initialHeight)

  ui.titleLabel = makeLabel("TradePacksTitleLabel", parent, 0, 27, LEDGER_WIDTH, 30, "OSO Packs Service")
  styleText(ui.titleLabel, "brown", ALIGN_CENTER or CENTER)
  pcall(function() ui.titleLabel.style:SetFontSize(26) end)
  ui.versionLabel = makeLabel("TradePacksVersionLabel", parent, 14, 14, 80, 18, "v" .. ADDON_VERSION)
  styleText(ui.versionLabel, TEXT_BROWN, ALIGN_LEFT or LEFT)
  pcall(function() ui.versionLabel.style:SetFontSize(12) end)
  ui.totalLabel = makeLabel("TradePacksTotalLabel", parent, 0, 68, LEDGER_WIDTH, 22, "Expected Profit: ?")
  styleText(ui.totalLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
  ui.loadingLabel = makeLabel("TradePacksLoadingLabel", parent, 243, 92, 178, 22, "Prices Are Loading")
  styleText(ui.loadingLabel, TEXT_GREEN)
  pcall(function()
    ui.loadingLabel.style:SetOutline(true)
  end)
  ui.loadingLabel:Show(false)
  ui.pageLabel = makeLabel("TradePacksPageLabel", parent, 524, 706 + listOffset, 78, 22, "Page 1/1")
  styleText(ui.pageLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
  ui.topSeparator = makeSeparator("TradePacksTopSeparator", parent, 24, 94, 602)

  ui.refreshButton = makeButton("TradePacksRefreshButton", parent, 523, 55, 74, 32, "Refresh", function()
    startAuctionRefresh(false, true)
  end)
  ui.closeButton = makeTextButton("TradePacksCloseButton", parent, 611, 62, 20, 22, "X", function()
    window:Show(false)
    runtime.windowVisible = false
  end)
  local btnAll = makeButton("TradePacksFilterAll", parent, 31, 110, 46, 30, "All", function()
    setFilter("all")
  end)
  local btnPending = makeButton("TradePacksFilterPending", parent, 85, 110, 72, 30, "Waiting", function()
    setFilter("pending")
  end)
  local btnReady = makeButton("TradePacksFilterReady", parent, 165, 110, 100, 30, "Delivered", function()
    setFilter("ready")
  end)
  ui.filterButtons = { all = btnAll, pending = btnPending, ready = btnReady }
  ui.waitingDeliveryLabel = makeLabel("TradePacksWaitingDeliveryLabel", parent, 320, 114, 309, 22, "0 waiting | 0 delivered")
  styleText(ui.waitingDeliveryLabel, TEXT_BROWN, ALIGN_RIGHT or RIGHT)

  local headers = {
    { "#",         4,   185, 16,  nil      },
    { "Pack Name", 20,  185, 190, "name"   },
    { "Total",     214, 185, 84,  "total"  },
    { "Cost",      300, 185, 90,  "cost"   },
    { "Profit",    392, 185, 76,  "profit" },
    { "ROI",       470, 185, 72,  "margin" },
    { "ETA",       544, 185, 75,  "eta"    },
  }

  -- Clickable headers drive ledger sorting (runtime.sortKey / sortDir). The "#"
  -- column has no sort key. Header label refs are kept so refreshUi can append the
  -- active-sort marker.
  ui.headerLabels = {}
  for index, header in ipairs(headers) do
    local sortKey = header[5]
    local headerLabel = makeLabel("TradePacksHeader" .. index, parent, header[2], header[3], header[4], 20, header[1])
    styleText(headerLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
    if sortKey then
      ui.headerLabels[sortKey] = { label = headerLabel, base = header[1] }
      pcall(function() headerLabel:EnablePick(true) end)
      pcall(function() headerLabel:Clickable(true) end)
      headerLabel:SetHandler("OnClick", function()
        if runtime.sortKey == sortKey then
          runtime.sortDir = (runtime.sortDir == "asc") and "desc" or "asc"
        else
          runtime.sortKey = sortKey
          runtime.sortDir = (sortKey == "name") and "asc" or "desc"
        end
        runtime.page = 1
        refreshUi()
      end)
    end
  end
  makeButton("TradePacksDateFilter", parent, 31, 149, 94, 24, "Date: All", function(self)
    local nextDate = {all = "today", today = "yesterday", yesterday = "week", week = "all"}
    runtime.dateFilter = nextDate[runtime.dateFilter] or "all"
    runtime.setButtonText(self, ({all = "Date: All", today = "Today", yesterday = "Yesterday", week = "Last 7 Days"})[runtime.dateFilter])
    runtime.page = 1
    refreshUi()
  end)
  ui.packFilterButton = makeButton("TradePacksPackFilter", parent, 133, 149, 152, 24,
    "Pack: All", function()
      if runtime.togglePackDropdown then runtime.togglePackDropdown() end
  end)
  makeButton("TradePacksUnpricedFilter", parent, 293, 149, 110, 24, "Unpriced: Off", function(self)
    runtime.unpricedOnly = not runtime.unpricedOnly
    runtime.setButtonText(self, runtime.unpricedOnly and "Unpriced: On" or "Unpriced: Off")
    runtime.page = 1
    refreshUi()
  end)
  local btnArchived = makeButton("TradePacksFilterArchived", parent, 411, 149, 104, 24, "Archived", function()
    setFilter("archived")
  end)
  ui.filterButtons.archived = btnArchived
  ui.payoutFilterButton = makeButton("TradePacksPayoutFilter", parent, 523, 149, 125, 24, "Payout: All", function(self)
    local choices, seen = {}, {}
    for _, record in ipairs(state.records) do
      local key = runtime.payoutFilterKey(record)
      if not seen[key] then
        seen[key] = true
        local name = key == "money" and "Money" or key == "onyx" and "Onyx"
          or key == "unknown" and "Unknown" or payoutDisplayName(record)
        choices[#choices + 1] = {key = key, name = name}
      end
    end
    table.sort(choices, function(a, b) return a.name < b.name end)
    local nextChoice
    if not runtime.payoutFilter then
      nextChoice = choices[1]
    else
      for i, choice in ipairs(choices) do
        if choice.key == runtime.payoutFilter then nextChoice = choices[i + 1]; break end
      end
    end
    runtime.payoutFilter = nextChoice and nextChoice.key or nil
    runtime.setButtonText(self, nextChoice and ("Payout: " .. fitDisplayText(nextChoice.name, 8)) or "Payout: All")
    runtime.page = 1
    refreshUi()
  end)
  ui.headerSeparator = makeSeparator("TradePacksHeaderSeparator", parent, 24, 178, 602)

  ui.selectionHighlights = {}
  ui.deleteButtons = {}
  for i = 1, maxRows do
    local y = 215 + (i - 1) * 30
    local row = {}
    ui.selectionHighlights[i] = makeSelectionHighlight("TradePacksSelection" .. i, parent, 0, y - 2, LEDGER_WIDTH, 28)
    row.rownum = makeLabel("TradePacksRowNum" .. i, parent, 4,   y + 4, 16,  20, "")
    row.name   = makeLabel("TradePacksName"   .. i, parent, 20,  y + 4, 190, 20, "")
    row.total  = makeLabel("TradePacksTotal"  .. i, parent, 214, y + 4, 84,  20, "")
    row.cost   = makeLabel("TradePacksCost"   .. i, parent, 300, y + 4, 90,  20, "")
    row.profit = makeLabel("TradePacksProfit" .. i, parent, 392, y + 4, 76,  20, "")
    row.margin = makeLabel("TradePacksMargin" .. i, parent, 470, y + 4, 72,  20, "")
    row.time   = makeLabel("TradePacksTime"   .. i, parent, 544, y + 4, 75,  20, "")
    styleText(row.rownum, TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.name,   TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.total,  TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.cost,   TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.profit, TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.margin, TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.time,   TEXT_BROWN, ALIGN_CENTER or CENTER)
    for _, widget in pairs(row) do
      pcall(function() widget:EnablePick(true) end)
      pcall(function() widget:Clickable(true) end)
      widget:SetHandler("OnClick", function()
        if row.recordId then
          runtime.selectedRecordId = row.recordId
          refreshUi()
        end
      end)
    end
    ui.rows[i] = row

    local deleteBtn = makeTextButton("TradePacksArchive" .. i, parent, 626, y + 4, 16, 20, "A", function()
      if row.recordId then runtime.toggleArchive(row.recordId) end
    end)
    styleText(deleteBtn, TEXT_RED)
    deleteBtn:Show(false)
    ui.deleteButtons[i] = deleteBtn
  end

  ui.detailSeparator = makeSeparator("TradePacksDetailSeparator", parent, 24, 466 + listOffset, 602)
  ui.detailTitle = makeLabel("TradePacksDetailTitle", parent, 31, 486 + listOffset, 588, 20, "Details")
  ui.detailLines = {}
  for i = 1, DETAIL_LINE_COUNT do
    ui.detailLines[i] = makeLabel("TradePacksDetailLine" .. i, parent, 31,
      516 + listOffset + (i - 1) * 18, 588, 16, "")
    styleText(ui.detailLines[i], TEXT_BROWN, ALIGN_CENTER or CENTER)
  end

  ui.alertButton = makeButton("TradePacksDueAlerts", parent, 31, 664 + listOffset, 104, 28,
    state.settings.dueAlerts and "Alerts: On" or "Alerts: Off", function(self)
      local old = state.settings.dueAlerts
      if old then
        state.settings.dueAlerts = nil
      else
        state.settings.dueAlerts = true
      end
      if not saveState() then state.settings.dueAlerts = old; return end
      runtime.setButtonText(self, state.settings.dueAlerts and "Alerts: On" or "Alerts: Off")
    end)
  ui.materialsButton = makeButton("TradePacksMaterialsEditor", parent, 143, 664 + listOffset,
    145, 28, "Materials", function() runtime.showCostEditor("materials") end)
  ui.transportButton = makeButton("TradePacksTransportEditor", parent, 296, 664 + listOffset,
    145, 28, "Transport", function() runtime.showCostEditor("transport") end)
  ui.laborButton = makeButton("TradePacksLaborEditor", parent, 449, 664 + listOffset,
    145, 28, "Labor", function() runtime.showCostEditor("labor") end)
  ui.historyButton = makeButton("TradePacksHistoryButton", parent, 31, 706 + listOffset, 90, 24, "History", function()
    showHistoryWindow()
  end)
  ui.archiveButton = makeButton("TradePacksArchiveDelivered", parent, 129, 706 + listOffset, 106, 24,
    "Archive", function() archiveOrRestoreRecords() end)
  ui.ratesButton = makeButton("TradePacksRatesButton", parent, 243, 706 + listOffset, 90, 24,
    "Rates", function()
      if not runtime.ratePanel then runtime.initializeRatePanel() end
      if runtime.ratePanel then runtime.ratePanel:toggle() end
    end)
  ui.firstPageButton = makeTextButton("TradePacksFirstPage", parent, 468, 706 + listOffset, 26, 22, "<<", function()
    runtime.page = 1
    refreshUi()
  end)
  ui.prevPageButton = makeTextButton("TradePacksPrevPage", parent, 496, 706 + listOffset, 26, 22, "<", function()
    runtime.page = runtime.page - 1
    refreshUi()
  end)
  ui.nextPageButton = makeTextButton("TradePacksNextPage", parent, 604, 706 + listOffset, 26, 22, ">", function()
    runtime.page = runtime.page + 1
    refreshUi()
  end)
  ui.lastPageButton = makeTextButton("TradePacksLastPage", parent, 632, 706 + listOffset, 26, 22, ">>", function()
    runtime.page = runtime.pageCount or 999
    refreshUi()
  end)

  local movedWidgets = {
    {ui.detailSeparator, 24, 466}, {ui.detailTitle, 31, 486},
    {ui.alertButton, 31, 664}, {ui.materialsButton, 143, 664},
    {ui.transportButton, 296, 664}, {ui.laborButton, 449, 664},
    {ui.historyButton, 31, 706}, {ui.archiveButton, 129, 706},
    {ui.ratesButton, 243, 706},
    {ui.firstPageButton, 468, 706}, {ui.prevPageButton, 496, 706},
    {ui.pageLabel, 524, 706}, {ui.nextPageButton, 604, 706},
    {ui.lastPageButton, 632, 706}
  }
  for i = 1, DETAIL_LINE_COUNT do
    movedWidgets[#movedWidgets + 1] = {ui.detailLines[i], 31, 516 + (i - 1) * 18}
  end
  ui.resizeGrip = makeButton("TradePacksResizeGrip", parent, 632,
    initialHeight - 15, 26, 14, "///")
  styleText(ui.resizeGrip, TEXT_BROWN, ALIGN_CENTER or CENTER)
  movedWidgets[#movedWidgets + 1] = {ui.resizeGrip, 632, 729}

  local lastAppliedHeight = initialHeight
  local lastAppliedWidth = LEDGER_WIDTH
  ui.applyLedgerWidth = function(width)
    width = math.max(LEDGER_WIDTH, math.min(LEDGER_MAX_WIDTH,
      math.floor(tonumber(width) or LEDGER_WIDTH)))
    if width == lastAppliedWidth then return end
    local oldNameChars = 27 + math.floor((lastAppliedWidth - LEDGER_WIDTH) / 8)
    lastAppliedWidth = width
    runtime.ledgerWidth = width
    local extra = width - LEDGER_WIDTH
    local offset = lastAppliedHeight - 744
    local function place(widget, x, y)
      widget:RemoveAllAnchors()
      widget:AddAnchor("TOPLEFT", parent, x, y)
    end
    ui.titleLabel:SetExtent(width, 30)
    ui.totalLabel:SetExtent(width, 22)
    place(ui.loadingLabel, 243 + math.floor(extra / 2), 92)
    place(ui.refreshButton, 523 + extra, 55)
    place(ui.closeButton, 611 + extra, 62)
    place(ui.waitingDeliveryLabel, 320 + extra, 114)
    place(btnArchived, 411 + extra, 149)
    place(ui.payoutFilterButton, 523 + extra, 149)
    ui.topSeparator:SetExtent(width - 58, 1)
    ui.headerSeparator:SetExtent(width - 58, 1)
    ui.detailSeparator:SetExtent(width - 58, 1)
    ui.detailTitle:SetExtent(width - 72, 20)
    for _, line in ipairs(ui.detailLines) do line:SetExtent(width - 72, 16) end
    for _, key in ipairs({"total", "cost", "profit", "margin", "eta"}) do
      local baseX = ({total = 214, cost = 300, profit = 392, margin = 470, eta = 544})[key]
      place(ui.headerLabels[key].label, baseX + extra, 185)
    end
    ui.headerLabels.name.label:SetExtent(190 + extra, 20)
    for i, row in ipairs(ui.rows) do
      local y = 215 + (i - 1) * 30
      ui.selectionHighlights[i]:SetExtent(width, 28)
      row.name:SetExtent(190 + extra, 20)
      for _, entry in ipairs({{row.total, 214}, {row.cost, 300},
        {row.profit, 392}, {row.margin, 470}, {row.time, 544}}) do
        place(entry[1], entry[2] + extra, y + 4)
      end
      place(ui.deleteButtons[i], 626 + extra, y + 4)
    end
    for _, entry in ipairs({{ui.firstPageButton, 468}, {ui.prevPageButton, 496},
      {ui.pageLabel, 524}, {ui.nextPageButton, 604},
      {ui.lastPageButton, 632}, {ui.resizeGrip, 632}}) do
      local y = entry[1] == ui.resizeGrip and 729 or 706
      place(entry[1], entry[2] + extra, y + offset)
      for _, moved in ipairs(movedWidgets) do
        if moved[1] == entry[1] then moved[2] = entry[2] + extra; break end
      end
    end
    ui.parchmentTint:SetExtent(width, lastAppliedHeight)
    if ui.panel then ui.panel:SetExtent(width, lastAppliedHeight) end
    if ui.backdrop then
      pcall(function() ui.backdrop:SetExtent(width, lastAppliedHeight) end)
      pcall(function() ui.backdrop:SetCoords(0, 0, width, lastAppliedHeight) end)
    end
    ui.border.top:SetExtent(width, 2)
    ui.border.bottom:SetExtent(width, 2)
    place(ui.border.right, width - 2, 0)
    if ui.floatingButton and oldNameChars ~= 27 + math.floor(extra / 8) then
      refreshUi()
    end
  end
  ui.applyLedgerWidth(runtime.ledgerWidth)

  local function applyLedgerHeight(height)
    height = math.max(744, math.min(744 + (maxRows - 8) * 30,
      tonumber(height) or initialHeight))
    if height == lastAppliedHeight then return end
    lastAppliedHeight = height
    local offset = height - 744
    for _, entry in ipairs(movedWidgets) do
      entry[1]:RemoveAllAnchors()
      entry[1]:AddAnchor("TOPLEFT", parent, entry[2], entry[3] + offset)
    end
    ui.parchmentTint:SetExtent(runtime.ledgerWidth, height)
    if ui.panel then ui.panel:SetExtent(runtime.ledgerWidth, height) end
    if ui.backdrop then
      pcall(function() ui.backdrop:SetExtent(runtime.ledgerWidth, height) end)
      pcall(function() ui.backdrop:SetCoords(0, 0, runtime.ledgerWidth, height) end)
    end
    ui.border.bottom:RemoveAllAnchors()
    ui.border.bottom:AddAnchor("TOPLEFT", parent, 0, height - 2)
    ui.border.left:SetExtent(2, height)
    ui.border.right:SetExtent(2, height)
    local rows = math.max(8, math.min(maxRows, 8 + math.floor(offset / 30)))
    if rows ~= runtime.visibleRowCount then
      runtime.visibleRowCount = rows
      refreshUi()
    end
  end
  ui.resizeGrip:EnableDrag(true)
  ui.resizeGrip:SetHandler("OnDragStart", function()
    if okScreen and type(screenHeight) == "number" then
      local _, top = window:GetOffset()
      if type(top) == "number" then
        local maxHeight = math.max(window:GetHeight(),
          math.min(744 + (maxRows - 8) * 30, screenHeight - top - 16))
        window:SetMaxResizingExtent(LEDGER_MAX_WIDTH, maxHeight)
      end
    end
    window:StartSizing("BOTTOMRIGHT")
    return true
  end)
  ui.resizeGrip:SetHandler("OnDragStop", function()
    window:StopMovingOrSizing()
    local rows = math.max(8, math.min(maxRows,
      8 + math.floor(((tonumber(window:GetHeight()) or initialHeight) - 744) / 30)))
    local height = 744 + (rows - 8) * 30
    local width = math.max(LEDGER_WIDTH, math.min(LEDGER_MAX_WIDTH,
      math.floor(tonumber(window:GetWidth()) or runtime.ledgerWidth)))
    window:SetExtent(width, height)
    applyLedgerHeight(height)
    if ui.applyLedgerWidth then ui.applyLedgerWidth(width) end
    pcall(function() ADDON:SaveData("TradePacksLedgerRows", {rows = rows, width = width}) end)
  end)

  -- Wrapped so a failure can't abort createUi before the floating OPS button is
  -- created (and surfaces the real error to chat for diagnosis).
  runtime._okHist, runtime._errHist = pcall(createHistoryWindow)
  if not runtime._okHist then
    pcall(function() ADDON:ChatLog("TradePacks: History window failed: " .. tostring(runtime._errHist)) end)
  end

  local openerX, openerY = loadOpenerPosition()
  ui.floatingButton = makeButton("TradePacksFloatingButton", nil, openerX, openerY, 46, 28, "OPS", function()
    local shouldShow = not window:IsVisible()
    window:Show(shouldShow)
    runtime.windowVisible = shouldShow
    if shouldShow then
      runtime.filter = "all"
      runtime.page = 1
      refreshUi()
      startAuctionRefresh()
    end
  end, true)
  pcall(function()
    ui.floatingButton:EnablePick(true)
  end)
  pcall(function()
    ui.floatingButton:EnableDrag(true)
  end)
  pcall(function()
    ui.floatingButton:SetDragCondition(DC_ALWAYS)
  end)
  ui.floatingButton:SetHandler("OnDragStart", function(self)
    self:StartMoving()
  end)
  ui.floatingButton:SetHandler("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local ok, x, y = pcall(function()
      return self:GetOffset()
    end)
    if ok and type(x) == "number" and type(y) == "number" then
      local uiScale = getUIScaleFactor()
      saveOpenerPosition(x * uiScale, y * uiScale)
    end
  end)

  ui.floatingButton:SetHandler("OnUpdate", function(_, elapsed)
    local dt = normalizedElapsed(elapsed)
    runtime.dueCheckElapsed = runtime.dueCheckElapsed + dt
    if runtime.dueCheckElapsed >= 10 then
      runtime.dueCheckElapsed = 0
      markDueRecords()
      runtime.retryHistorySave()
    end

    runtime.dailyCheckElapsed = runtime.dailyCheckElapsed + dt
    if runtime.dailyCheckElapsed >= 60 then
      runtime.dailyCheckElapsed = 0
      if historyState.dailyStartTime < currentDayKeyUtc2() then
        runtime.recomputeDailyProfit()
        runtime.saveHistoryState()
        updateHistoryWindow()
        if runtime.dateFilter ~= "all" then refreshUi() end
      end
    end
  end)

  -- The floating OPS control is ready before optional dropdown construction.
  -- A bad menu widget must not prevent the addon from opening its ledger.
  local menuOk, menuErr = pcall(runtime.createPackMenu, parent)
  if not menuOk then
    if ui.packMenu then pcall(function() ui.packMenu:Show(false) end) end
    ui.packMenu = nil
    runtime.togglePackDropdown = nil
    pcall(function() ADDON:ChatLog("TradePacks: pack dropdown failed: " .. tostring(menuErr)) end)
  end

  window:SetHandler("OnUpdate", function(_, elapsed)
    ui.applyLedgerWidth(window:GetWidth())
    applyLedgerHeight(window:GetHeight())
    runtime.windowVisible = window:IsVisible()
    if not runtime.windowVisible then
      return
    end
    local dt = normalizedElapsed(elapsed)
    updateLoadingLabel(dt)
    runtime.uiUpdateElapsed = runtime.uiUpdateElapsed + dt
    if runtime.uiUpdateElapsed >= 1 then
      runtime.uiUpdateElapsed = 0
      local statusChanged = false
      for _, row in ipairs(ui.rows) do
        local record = row.recordId and findRecord(row.recordId)
        if record and not record.archived then
          local status = getRecordStatus(record)
          if status ~= row.currentStatus then
            statusChanged = true
            break
          end
          if status == "Waiting" then
            local dueAt = (tonumber(record.soldAt) or 0) + DEFAULT_DELAY_SECONDS
            row.time:SetText(formatDuration(dueAt - nowSeconds()))
          end
        end
      end
      if statusChanged then refreshUi() end
    end
  end)

  window:SetHandler("OnEvent", runtime.handleLedgerEvent)

  local events = {
    "SELL_SPECIALTY",
    "SELL_SPECIALTY_CONTENT_INFO",
    "UPDATE_SPECIALTY_RATIO",
    "BUY_SPECIALTY_CONTENT_INFO",
    "CHAT_MESSAGE",
    "CHAT_MSG_ALARM",
    "AUCTION_LOWEST_PRICE",
    "AUCTION_ITEM_SEARCHED"
  }

  for _, eventName in ipairs(events) do
    pcall(function()
      window:RegisterEvent(eventName)
    end)
  end

  registerAuctionHandlers()

  ADDON:RegisterContentWidget(UIC_TRADEPACKS, window, function(show)
    local shouldShow = show
    if shouldShow == nil then
      shouldShow = not window:IsVisible()
    end

    window:Show(shouldShow)
    runtime.windowVisible = shouldShow
    if shouldShow then
      runtime.filter = "all"
      runtime.page = 1
      refreshUi()
      startAuctionRefresh()
    end
  end)

  updateFilterButtons()
  refreshUi()
end

migrateHistoryFromRecords()
if historyState.lastRecordId == nil then
  -- Existing history predates this recovery marker. Do not count old rows twice.
  historyState.lastRecordId = (tonumber(state.nextId) or 1) - 1
  runtime.saveHistoryState()
elseif not runtime.recordsLoadIncomplete then
  local missing = {}
  for _, record in ipairs(state.records) do
    if (tonumber(record.id) or 0) > tonumber(historyState.lastRecordId) then
      missing[#missing + 1] = record
    end
  end
  table.sort(missing, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
  for _, record in ipairs(missing) do addRecordToHistory(record) end
  if #missing > 0 then runtime.saveHistoryState(); saveState() end
end
runtime.migrateRuns = function()
if #historyState.runs == 0 and #state.records > 0 and not runtime.recordsLoadIncomplete then
  local ordered = {}
  for _, record in ipairs(state.records) do ordered[#ordered + 1] = record end
  table.sort(ordered, function(a, b)
    local at, bt = tonumber(a.soldAt) or 0, tonumber(b.soldAt) or 0
    if at == bt then return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end
    return at < bt
  end)
  for _, record in ipairs(ordered) do
    local runs = historyState.runs
    local last = runs[#runs]
    local soldAt = tonumber(record.soldAt) or 0
    if not last or soldAt - (tonumber(last.lastAt) or 0) > 30 * 60 then
      last = {id = tostring(soldAt) .. ":" .. tostring(record.id), startedAt = soldAt,
        lastAt = soldAt, count = 0, profitCopper = 0, unknownCount = 0}
      runs[#runs + 1] = last
    end
    record.runId = last.id
    last.lastAt = soldAt
    last.count = last.count + 1
    local profit = recordProfit(record)
    if profit then last.profitCopper = last.profitCopper + profit
    else last.unknownCount = last.unknownCount + 1 end
  end
  runtime.saveHistoryState()
  saveState()
end
end
runtime.migrateRuns()
runtime.backfillRetainedRuns = function()
  if runtime.recordsLoadIncomplete or runtime.runHistoryLoadIncomplete then return end
  local known, recovered = {}, {}
  for _, run in ipairs(historyState.runs) do known[run.id] = true end
  for _, record in ipairs(state.records) do
    if record.runId and (tonumber(record.id) or 0) > (tonumber(historyState.statsResetThroughId) or 0)
      and not known[record.runId] then
      recovered[record.runId] = true
    end
  end
  if next(recovered) then
    for _, record in ipairs(state.records) do
      if recovered[record.runId] then
        local soldAt = tonumber(record.soldAt) or 0
        local run = recovered[record.runId]
        if run == true then
          run = {id = record.runId, startedAt = soldAt, lastAt = soldAt,
            count = 0, profitCopper = 0, unknownCount = 0}
          recovered[record.runId] = run
          historyState.runs[#historyState.runs + 1] = run
        end
        run.startedAt = math.min(run.startedAt, soldAt)
        run.lastAt = math.max(run.lastAt, soldAt)
        run.count = run.count + 1
        local profit = recordProfit(record)
        if profit then run.profitCopper = run.profitCopper + profit
        else run.unknownCount = run.unknownCount + 1 end
      end
    end
    table.sort(historyState.runs, function(a, b)
      if a.startedAt == b.startedAt then return tostring(a.id) < tostring(b.id) end
      return (tonumber(a.startedAt) or 0) < (tonumber(b.startedAt) or 0)
    end)
    runtime.saveHistoryState()
  end
end
runtime.backfillRetainedRuns()
runtime.recomputeDailyProfit()
-- One-time v1.1.2 repair: auction events fired by the user's own auction-house
-- activity used to be attributed to arbitrary pending lookups, storing unrelated
-- items' prices on item payouts (e.g. Dragon Essence Stabilizer priced at the
-- cheapest listing of whatever was searched). Unlock those snapshots on unpaid
-- records and purge the cached prices so they re-fetch cleanly. Onyx payouts are
-- excluded: they are range-guarded and repaired by the startup migration. PAID
-- records stay locked; their profit is final.
;(function()
  if state.settings.repairedContaminatedPayouts then
    return
  end
  state.settings.repairedContaminatedPayouts = true
  for _, record in ipairs(state.records) do
    if not record.paid
      and not tonumber(record.payoutCopper)
      and tonumber(record.payoutUnitPriceCopper)
      and not isOnyxPayout(record) then
      record.payoutUnitPriceCopper = nil
      record.payoutPricedAt = nil
      local key = normalizeKey(tonumber(record.payoutItemType))
      if key then
        state.prices[key] = nil
      end
    end
  end
  saveState()
end)()
-- Backfill payout names from the captured item type when the name is missing or
-- numeric (covers records repaired by the startup migration after being
-- mislabelled "Onyx").
;(function()
  for _, record in ipairs(state.records) do
    local payoutName = compactText(record.payoutName)
    if record.payoutItemType and (payoutName == "" or tonumber(payoutName)) then
      local realName = getItemNameByType(record.payoutItemType)
      if realName and realName ~= "" then
        record.payoutName = realName
      end
    end
  end
end)()
-- Backfill payout snapshots for records saved before per-record payout pricing
-- existed. They have no payoutUnitPriceCopper, so lock them at the currently
-- known price now to stop a future Onyx price update from retroactively shifting
-- their profit. Records still lacking a resolvable price lock on the next lookup.
if tryCompletePayoutValues then
  tryCompletePayoutValues()
end
-- Replace saved manual-rate labor totals when loading older cost rules.
;(function()
  local changed = false
  for _, record in ipairs(state.records) do
    if type(runtime.costRules.labor[record.cargoName]) == "table" then
      local cost = runtime.ruleCost("labor", record.cargoName)
      if cost ~= record.laborCostCopper then
        record.laborCostCopper = cost
        changed = true
      end
    end
  end
  if changed and saveState() then syncAllRecordsHistoryProfit() end
end)()
-- Startup reconciliation is data work; hidden windows no longer run it while
-- repainting their initial labels.
markDueRecords()
syncAllRecordsHistoryProfit()
;(function()
  if runtime.recordsLoadIncomplete then return end
  -- Older versions saved newest-first chunks. Convert both banks during load,
  -- so the first two sales after upgrading do not rewrite the entire ledger.
  -- Mark migration complete only after the second verified bank commit.
  if state.recordOrder ~= "id" then
    if saveState() then saveState("id") end
  end
  local function warm(prefix, otherPrefix, count)
    for i = 1, count do
      local key = prefix .. i
      if not runtime.verifiedChunks[key] then
        local saved = ADDON:LoadData(key)
        if type(saved) == "table" then
          runtime.verifiedChunks[key] = saved
        else
          -- A new installation or recovered history may have only one bank.
          -- Stage missing chunks from its saved copy now, without switching
          -- any pointers or overwriting an existing fallback chunk.
          local otherKey = otherPrefix .. i
          local other = runtime.verifiedChunks[otherKey] or ADDON:LoadData(otherKey)
          if type(other) == "table" then
            runtime.verifiedChunks[otherKey] = other
            runtime.saveVerifiedChunk(key, other, "initial chunk copy did not read back: " .. key)
          end
        end
      end
    end
  end
  -- Independent reads: objects loaded into the live ledger/history are mutable
  -- and must never be used as our saved snapshots. Existing chunks are read only.
  local ok, err = pcall(function()
    for _, bank in ipairs({"A", "B"}) do
      local other = bank == "A" and "B" or "A"
      warm("TradePacksRecords" .. bank .. "_", "TradePacksRecords" .. other .. "_",
        math.ceil(#state.records / RECORDS_CHUNK_SIZE))
      if not runtime.runHistoryLoadIncomplete then
        warm("TradePacksRuns" .. bank .. "_", "TradePacksRuns" .. other .. "_",
          math.ceil(#historyState.runs / RUNS_CHUNK_SIZE))
        for _, field in ipairs(runtime.historyMapFields) do
          local count = 0
          for _ in pairs(historyState[field] or {}) do count = count + 1 end
          warm("TradePacksHistory" .. bank .. field .. "_",
            "TradePacksHistory" .. other .. field .. "_",
            math.ceil(count / runtime.historyMapChunkSize))
        end
      end
    end
  end)
  if not ok then runtime.reportSaveError("cache", err) end
end)()
;(function()
  local ok, err = pcall(createUi)
  if not ok then
    pcall(function() ADDON:ChatLog("TradePacks: createUi failed: " .. tostring(err)) end)
  end
end)()

;(function()
  local ok, err = pcall(runtime.createAuctionDriver)
  if not ok then runtime.reportSaveError("auction scheduler", err) end
end)()

runtime.initializeRatePanel()

TradePacksLedger = {
  AddSaleText = function(text)
    parseSaleText(text)
  end,
  AddRecord = function(name)
    return createSaleRecord(name)
  end,
  RefreshPrices = function()
    runtime.windowVisible = true
    startAuctionRefresh()
  end,
  State = state
}

ADDON:ChatLog("TradePacks v" .. ADDON_VERSION .. " loaded")
