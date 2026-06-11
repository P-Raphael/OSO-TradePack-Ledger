local ADDON_NAME = "TradePacks"
local ADDON_VERSION = "1.1.1"
local SAVE_KEY = "TradePacksState"
local HISTORY_SAVE_KEY = "TradePacksHistoryState"
local OPENER_SAVE_KEY = "TradePacksOpenerPosition"
local LEDGER_SAVE_KEY = "TradePacksLedgerPosition"
local HISTORY_WINDOW_SAVE_KEY = "TradePacksHistoryWindowPosition"
local RECORDS_CHUNK_PREFIX = "TradePacksRecords_"
local PRICES_SAVE_KEY = "TradePacksPrices"
local RECORDS_CHUNK_SIZE = 20
local RECORDS_CHUNK_SAFETY_CAP = 500
local UIC_TRADEPACKS = 1301
local ROW_COUNT = 11
local AUCTION_GRADE_ALL = 0
local AUCTION_GRADE_NORMAL = 1
local DEFAULT_DELAY_SECONDS = 8 * 60 * 60
local DETAIL_LINE_COUNT = 7
local ONYX_ITEM_TYPE = 979983
local ONYX_DISPLAY_NAME = "Onyx"
local ONYX_AUCTION_SEARCH_NAME = "Onyx Archeum Essence"
local ONYX_MIN_REASONABLE_UNIT_PRICE = 1 * 10000
local ONYX_MAX_REASONABLE_UNIT_PRICE = 100 * 10000
-- The Onyx item-type id has changed across game patches; ids the client used in
-- earlier patches still appear on old records and must keep resolving as Onyx.
local ONYX_LEGACY_ITEM_TYPES = {
  [1107253] = true
}
local LEDGER_WIDTH = 610
local LEDGER_HEIGHT = 762
local HISTORY_WIDTH = 360
local HISTORY_HEIGHT = 440
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
  Editbox = 3,
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

local function normalizeDelay(value)
  value = tonumber(value)
  if not value or value <= 0 then
    return nil
  end
  if value <= 72 then
    return value * 60 * 60
  end
  return value
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
    favoritePack = "-",
    favoriteCount = 0,
    migratedFromRecords = false,
    dailyProfitCopper = 0,
    dailyUnknownCount = 0,
    dailyStartTime = 0,
    dailyHistory = {}
  }
end

local state = ADDON:LoadData(SAVE_KEY)
if type(state) ~= "table" then
  state = defaultState()
end

local historyState = ADDON:LoadData(HISTORY_SAVE_KEY)
if type(historyState) ~= "table" then
  historyState = defaultHistoryState()
end

state.version = 2

local recordChunkCount = tonumber(state.recordChunkCount) or 0
if recordChunkCount > 0 then
  local loaded = {}
  for chunkIndex = 1, recordChunkCount do
    local chunk = ADDON:LoadData(RECORDS_CHUNK_PREFIX .. chunkIndex)
    if type(chunk) == "table" then
      for _, record in ipairs(chunk) do
        loaded[#loaded + 1] = record
      end
    end
  end
  state.records = loaded
end

if type(state.records) ~= "table" then
  state.records = {}
end

local separatePrices = ADDON:LoadData(PRICES_SAVE_KEY)
if type(separatePrices) == "table" then
  state.prices = separatePrices
end
if type(state.settings) ~= "table" then
  state.settings = {}
end
if type(state.settings.costPresets) ~= "table" then
  state.settings.costPresets = {}
end
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

for _, record in ipairs(state.records) do
  if record.cargoName == "Auroran Cargo" then
    local existingName = type(record.payoutName) == "string" and record.payoutName:lower() or ""
    local nameIsOnyx = existingName == ""
      or existingName:find("onyx", 1, true) ~= nil
      or tonumber(existingName) ~= nil
    local itemType = tonumber(record.payoutItemType)
    local typeIsOnyx = itemType == nil
      or itemType == ONYX_ITEM_TYPE
      or ONYX_LEGACY_ITEM_TYPES[itemType] == true
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

do -- TEST MOCK: Auroran Cargo / Dragon Essence Stabilizer price lookup check
  local DES_ITEM_TYPE = 32106
  local mock = nil
  for _, r in ipairs(state.records) do
    if r.cargoName == "Auroran Cargo" and r.payoutName == "Dragon Essence Stabilizer" then
      mock = r
      break
    end
  end
  if mock then
    -- Repair a mock saved before the Onyx migration fix: force the real item
    -- type and unlock any payout price snapshotted from the Onyx lookup.
    if tonumber(mock.payoutItemType) ~= DES_ITEM_TYPE then
      mock.payoutItemType = DES_ITEM_TYPE
      mock.payoutUnitPriceCopper = nil
      mock.payoutPricedAt = nil
    end
  else
    local now = os.time()
    table.insert(state.records, {
      id = state.nextId,
      cargoName = "Auroran Cargo",
      payoutName = "Dragon Essence Stabilizer",
      payoutItemType = DES_ITEM_TYPE,
      payoutCount = 1,
      soldAt = now,
      dayKeyUtc2 = math.floor((now - 2 * 3600) / 86400),
      delaySeconds = DEFAULT_DELAY_SECONDS,
      costCopper = 260000,
      costStatus = "preset",
      costSource = "preset",
      paid = false,
    })
    state.nextId = state.nextId + 1
  end
end

local lastSavedChunkCount = recordChunkCount or 0
local function saveState()
  pcall(function()
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
      leanRecords[#leanRecords + 1] = lean
    end

    local chunkCount = math.ceil(#leanRecords / RECORDS_CHUNK_SIZE)
    for chunkIndex = 1, chunkCount do
      local chunk = {}
      local startIdx = (chunkIndex - 1) * RECORDS_CHUNK_SIZE + 1
      local endIdx = math.min(chunkIndex * RECORDS_CHUNK_SIZE, #leanRecords)
      for i = startIdx, endIdx do
        chunk[#chunk + 1] = leanRecords[i]
      end
      pcall(function()
        ADDON:SaveData(RECORDS_CHUNK_PREFIX .. chunkIndex, chunk)
      end)
    end

    local clearUpTo = math.max(lastSavedChunkCount, chunkCount + 5)
    if clearUpTo > RECORDS_CHUNK_SAFETY_CAP then
      clearUpTo = RECORDS_CHUNK_SAFETY_CAP
    end
    if type(ADDON.ClearData) == "function" then
      for chunkIndex = chunkCount + 1, clearUpTo do
        pcall(function()
          ADDON:ClearData(RECORDS_CHUNK_PREFIX .. chunkIndex)
        end)
      end
    else
      for chunkIndex = chunkCount + 1, clearUpTo do
        pcall(function()
          ADDON:SaveData(RECORDS_CHUNK_PREFIX .. chunkIndex, {})
        end)
      end
    end
    lastSavedChunkCount = chunkCount

    pcall(function()
      ADDON:SaveData(PRICES_SAVE_KEY, state.prices or {})
    end)

    local meta = {
      version = state.version,
      nextId = state.nextId,
      settings = state.settings,
      recordChunkCount = chunkCount,
      recordCount = #leanRecords
    }
    ADDON:SaveData(SAVE_KEY, meta)
  end)
end

local function saveHistoryState()
  pcall(function()
    ADDON:SaveData(HISTORY_SAVE_KEY, historyState)
  end)
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
      if forceOnyxLimit or tonumber(itemType) == ONYX_ITEM_TYPE then
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

local function getItemNameByType(itemType)
  itemType = tonumber(itemType)
  if not itemType or itemType <= 0 or not X2Item or type(X2Item.GetItemInfoByType) ~= "function" then
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
  if record.costStatus == "preset" or record.costSource == "preset" then
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
  local pricedAt = nowSeconds()

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
        if not material.pricedAt then
          material.pricedAt = pricedAt
          changed = true
        end
        total = total + totalPrice
      else
        allKnown = false
      end
    end
  end

  if allKnown then
    if record.materialCostCopper ~= total or record.costCopper ~= total or record.costStatus ~= "snapshot" then
      record.materialCostCopper = total
      record.costCopper = total
      record.costStatus = "snapshot"
      record.costSource = "folio"
      record.materialPricedAt = pricedAt
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
    if record.costStatus ~= "snapshot" and record.costStatus ~= "preset" then
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
    delaySeconds = normalizeDelay(info.delay),
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
  record.delaySeconds = record.delaySeconds or source.delaySeconds
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

local function getRecordStatus(record)
  if record.paid then
    return "PAID"
  end

  local soldAt = tonumber(record.soldAt) or 0
  local delay = tonumber(record.delaySeconds) or DEFAULT_DELAY_SECONDS
  if nowSeconds() >= soldAt + delay then
    return "PAID"
  end
  return "Waiting"
end

local refreshUi
local updateFilterButtons
local startAuctionRefresh
local resolvePayoutItemType
local payoutSearchName
local resolveRecordIcon
local handleAuctionItemSearched
local handleLowestPrice
local readSearchedAuctionResults
local recordProfit
local trySnapshotPayoutValue
local tryCompletePayoutValues

local function markDeliveredRecordsPaid()
  local changed = false
  local now = nowSeconds()
  for _, record in ipairs(state.records) do
    if not record.paid then
      local soldAt = tonumber(record.soldAt) or 0
      local delay = tonumber(record.delaySeconds) or DEFAULT_DELAY_SECONDS
      if now >= soldAt + delay then
        record.paid = true
        -- Freeze the payout at delivery so later price changes never shift the
        -- profit of a PAID record.
        if trySnapshotPayoutValue then
          trySnapshotPayoutValue(record)
        end
        changed = true
      end
    end
  end

  if changed then
    saveState()
  end
end

local function recordPassesFilter(record)
  if runtime.filter == "pending" then
    return getRecordStatus(record) == "Waiting"
  end
  if runtime.filter == "ready" then
    return getRecordStatus(record) == "PAID"
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

local function resetHistoryTotals()
  historyState.packCount = 0
  historyState.totalProfitCopper = 0
  historyState.unknownProfitCount = 0
  historyState.packCounts = {}
  historyState.favoritePack = "-"
  historyState.favoriteCount = 0
  historyState.dailyProfitCopper = 0
  historyState.dailyUnknownCount = 0
  historyState.dailyStartTime = 0
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

local function recomputeDailyProfit()
  local todayKey = currentDayKeyUtc2()
  historyState.dailyStartTime = todayKey
  historyState.dailyProfitCopper = 0
  historyState.dailyUnknownCount = 0
  local byDay = {}
  for _, record in ipairs(state.records) do
    local dk = recordDayKeyUtc2(record)
    if not byDay[dk] then
      byDay[dk] = {profitCopper = 0, unknownCount = 0, packCount = 0}
    end
    byDay[dk].packCount = byDay[dk].packCount + 1
    local profit = recordProfit and recordProfit(record)
    if profit then
      byDay[dk].profitCopper = byDay[dk].profitCopper + profit
      if dk == todayKey then
        historyState.dailyProfitCopper = historyState.dailyProfitCopper + profit
      end
    else
      byDay[dk].unknownCount = byDay[dk].unknownCount + 1
      if dk == todayKey then
        historyState.dailyUnknownCount = historyState.dailyUnknownCount + 1
      end
    end
  end
  historyState.dailyHistory = byDay
end

local function checkDailyReset()
  if historyState.dailyStartTime < currentDayKeyUtc2() then
    recomputeDailyProfit()
    saveHistoryState()
  end
end

local function addRecordToHistory(record)
  if type(record) ~= "table" then
    return
  end

  local packName = historyPackName(record)
  local packCount = (tonumber(historyState.packCounts[packName]) or 0) + 1
  historyState.packCounts[packName] = packCount
  historyState.packCount = (tonumber(historyState.packCount) or 0) + 1

  if packCount > (tonumber(historyState.favoriteCount) or 0) then
    historyState.favoritePack = packName
    historyState.favoriteCount = packCount
  end

  local profit = recordProfit and recordProfit(record)
  if profit then
    historyState.totalProfitCopper = (tonumber(historyState.totalProfitCopper) or 0) + profit
    record.historyProfitContrib = profit
  else
    historyState.unknownProfitCount = (tonumber(historyState.unknownProfitCount) or 0) + 1
    record.historyProfitContrib = "unknown"
  end
end

local function syncRecordHistoryProfit(record)
  if type(record) ~= "table" then
    return false
  end
  local prev = record.historyProfitContrib
  if prev == nil then
    return false
  end
  local curr = recordProfit and recordProfit(record)
  if prev == "unknown" then
    if type(curr) == "number" then
      historyState.unknownProfitCount = math.max(0, (tonumber(historyState.unknownProfitCount) or 0) - 1)
      historyState.totalProfitCopper = (tonumber(historyState.totalProfitCopper) or 0) + curr
      record.historyProfitContrib = curr
      return true
    end
    return false
  end
  if type(prev) == "number" then
    if type(curr) == "number" then
      if curr ~= prev then
        historyState.totalProfitCopper = (tonumber(historyState.totalProfitCopper) or 0) + (curr - prev)
        record.historyProfitContrib = curr
        return true
      end
      return false
    end
    historyState.totalProfitCopper = (tonumber(historyState.totalProfitCopper) or 0) - prev
    historyState.unknownProfitCount = (tonumber(historyState.unknownProfitCount) or 0) + 1
    record.historyProfitContrib = "unknown"
    return true
  end
  return false
end

local function syncAllRecordsHistoryProfit()
  local changed = false
  for _, record in ipairs(state.records) do
    if syncRecordHistoryProfit(record) then
      changed = true
    end
  end
  if changed then
    saveHistoryState()
  end
  return changed
end

local function migrateHistoryFromRecords()
  if historyState.migratedFromRecords then
    return
  end

  resetHistoryTotals()
  for _, record in ipairs(state.records) do
    addRecordToHistory(record)
  end
  historyState.migratedFromRecords = true
  saveHistoryState()
end

local function createSaleRecord(cargoName, sourceText)
  cargoName = compactText(cargoName)
  if cargoName == "" or cargoName == "?" or cargoName == "Unknown Cargo" then
    return nil
  end

  local now = nowSeconds()

  local record = {
    id = state.nextId,
    cargoName = cargoName,
    costCopper = nil,
    soldAt = now,
    dayKeyUtc2 = math.floor((now - UTC_MINUS_2_OFFSET) / 86400),
    delaySeconds = DEFAULT_DELAY_SECONDS,
    interestPercent = nil,
    paid = false
  }
  state.nextId = state.nextId + 1

  if cargoName and runtime.latestSellByName[cargoName] then
    mergeRecordData(record, runtime.latestSellByName[cargoName])
  end
  mergeRecordData(record, runtime.latestSellPreview)
  if cargoName and runtime.latestBuyByName[cargoName] then
    mergeRecordData(record, runtime.latestBuyByName[cargoName])
  end

  if cargoName then
    record.cargoName = cargoName
  end

  if runtime.pendingSaleTerms then
    record.delaySeconds = runtime.pendingSaleTerms.delaySeconds or record.delaySeconds
    record.interestPercent = runtime.pendingSaleTerms.interestPercent
    runtime.pendingSaleTerms = nil
  end

  initializeRecordCost(record)
  if trySnapshotPayoutValue then
    trySnapshotPayoutValue(record)
  end

  table.insert(state.records, record)
  addRecordToHistory(record)
  saveHistoryState()
  sortRecords()
  saveState()

  if refreshUi then
    refreshUi()
  end
  if startAuctionRefresh then
    if record.costStatus == "snapshot" or record.costStatus == "preset" then
      -- phase 1 succeeded: cost and payout price already cached, no auction refresh needed.
      -- (use the Refresh button to re-pull fresh auction prices on demand)
    else
      -- cost still unknown: schedule a debounced refresh so rapid turn-ins of unpriced
      -- packs collapse into a single auction pull instead of one per turn-in
      runtime.auctionRefreshPending = true
      runtime.auctionRefreshDelay = 10
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
  local hours, interest = text:match("[Pp]ayment will be mailed in (%d+) hours? with (%d+)%% interest")
  if hours then
    runtime.pendingSaleTerms = {
      delaySeconds = tonumber(hours) * 60 * 60,
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
    createSaleRecord(cargoName, text)
    createdRecord = true
  end

  return createdRecord
end

local function lookupIsOnyx(lookup)
  if type(lookup) ~= "table" then
    return false
  end
  if tonumber(lookup.itemType) == ONYX_ITEM_TYPE then
    return true
  end

  local searchName = tostring(lookup.searchName or ""):lower()
  return searchName:find("onyx", 1, true) ~= nil
end

local function isOnyxAuctionLookup(itemType)
  if tonumber(itemType) == ONYX_ITEM_TYPE then
    return true
  end

  local key = normalizeKey(itemType)
  if key and (lookupIsOnyx(runtime.priceLookups[key]) or lookupIsOnyx(runtime.namePriceLookups[key])) then
    return true
  end

  local activeKey = runtime.lastAuctionSearchKey
  if activeKey and lookupIsOnyx(runtime.namePriceLookups[activeKey] or runtime.priceLookups[activeKey]) then
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
  finishAuctionLookup(key)
  runtime.auctionStatus = nil
  tryCompleteMaterialCosts()
  if tryCompletePayoutValues then
    tryCompletePayoutValues()
  end
  if processNextAuctionSearch and processNextAuctionSearch() then
    setAuctionLoading(true)
  elseif hasPendingAuctionLookups() then
    setAuctionLoading(true)
  else
    setAuctionLoading(false)
  end
  saveState()
  if refreshUi then
    refreshUi()
  end
  return true
end

processNextAuctionSearch = function()
  if runtime.activeAuctionKey then
    return true
  end
  if not X2Auction or type(X2Auction.SearchAuctionArticle) ~= "function" then
    return false
  end

  while #runtime.auctionQueue > 0 do
    local key = table.remove(runtime.auctionQueue, 1)
    local lookup = runtime.namePriceLookups[key]
    if lookup and type(lookup.searchName) == "string" and lookup.searchName ~= "" then
      registerAuctionHandlers()
      local ok = pcall(function()
        X2Auction:SearchAuctionArticle(1, 0, 55, AUCTION_GRADE_NORMAL, 0, false, lookup.searchName, "0", "99999999999")
      end)
      if ok then
        lookup.startedAt = nowSeconds()
        lookup.elapsed = 0
        lookup.lastTry = 0
        runtime.activeAuctionKey = key
        runtime.lastAuctionSearchKey = key
        setAuctionLoading(true)
        return true
      end
      finishAuctionLookup(key)
    end
  end

  return false
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
  if itemType then
    local lowestSent, lowestStored = askLowestPrice(itemType)
    if lowestStored then
      return true
    end
    sent = sent or lowestSent
  end

  if allowSearchFallback and askAuctionSearch(itemType, searchName, lookupKey) then
    sent = true
  end

  if sent then
    runtime.auctionStatus = "Searching " .. tostring(searchName or itemType)
    setAuctionLoading(true)
  else
    runtime.auctionStatus = "Search failed"
    setAuctionLoading(false)
  end
  return sent
end

startAuctionRefresh = function(force)
  runtime.windowVisible = ledgerIsVisible()
  if not runtime.windowVisible and not force then
    return
  end

  runtime.priceLookups = {}
  runtime.namePriceLookups = {}
  runtime.auctionQueue = {}
  runtime.activeAuctionKey = nil
  runtime.lastAuctionSearchKey = nil
  setAuctionLoading(false)
  tryCompleteMaterialCosts()
  if tryCompletePayoutValues then
    tryCompletePayoutValues()
  end

  local records = state.records
  local requested = {}
  local now = nowSeconds()
  local requestCount = 0

  local function requestPrice(key, itemType, searchName, lookupType)
    if not key or requested[key] or isUnpricedAuctionName(searchName) then
      return
    end
    requested[key] = true
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
    end
  end

  for _, record in ipairs(records) do
    if record.costStatus ~= "snapshot" and record.costStatus ~= "preset" then
      local materials = ensureRecordMaterials(record)
      if materials then
        for _, material in ipairs(materials) do
          if material.name and not tonumber(material.unitPriceCopper) and not getNamedPrice(material.name) then
            requestPrice(normalizeNameKey(material.name), nil, material.name, "material")
          end
        end
      end
    end

    if not (recordPayoutValue and recordPayoutValue(record)) then
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

  if requestCount == 0 then
    runtime.auctionStatus = nil
    setAuctionLoading(false)
  end

  if refreshUi then
    refreshUi()
  end
end

local function updateAuctionLookups(elapsed)
  runtime.windowVisible = ledgerIsVisible()
  if not runtime.windowVisible then
    return
  end

  elapsed = normalizedElapsed(elapsed)

  for key, lookup in pairs(runtime.priceLookups) do
    local waitingForQueuedSearch = runtime.namePriceLookups[key] and runtime.activeAuctionKey ~= key and not lookup.itemType
    if waitingForQueuedSearch then
      -- This lookup has not been sent yet; the active search will advance the queue.
    else
    lookup.elapsed = (lookup.elapsed or 0) + elapsed
    local searchLookup = runtime.namePriceLookups[key]
    local searchDone = searchLookup and runtime.activeAuctionKey == key and readSearchedAuctionResults(key, searchLookup, false)
    if searchDone then
      -- The result handler stored the price and cleared this lookup.
    elseif lookup.elapsed >= 8 then
      finishAuctionLookup(key)
      if runtime.auctionStatus and runtime.auctionStatus:find("Searching", 1, true) then
        runtime.auctionStatus = "No response"
      end
      if processNextAuctionSearch and processNextAuctionSearch() then
        setAuctionLoading(true)
      else
        setAuctionLoading(false)
      end
    elseif lookup.itemType and lookup.elapsed - (lookup.lastTry or 0) >= 0.7 then
      lookup.lastTry = lookup.elapsed
      queryAuctionPrice(lookup.itemType, lookup.searchName, false, key)
    end
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

local function makeButton(name, parent, x, y, width, height, text, handler)
  local button = createWidget("button", name, parent, x, y, width, height)
  pcall(function()
    button:SetStyle("text_default")
  end)
  button:SetText(text or "")
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
  local editbox = createWidget("editbox", name, parent, x, y, width, height)
  editbox:SetText(text or "")
  pcall(function()
    editbox:SetInset(4, 1, 4, 1)
  end)
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

local function addBackdrop(widget)
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
  sizeDrawable(drawable, widget, LEDGER_WIDTH, LEDGER_HEIGHT)
  pcall(function()
    drawable:Show(true)
  end)
  return drawable
end

local function addParchmentTint(parent)
  local tint = createWidget("emptywidget", "TradePacksParchmentTint", parent, 0, 0, LEDGER_WIDTH, LEDGER_HEIGHT)
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
  end
  makeLine("BorderTop",    0,               0,                width,     thickness)
  makeLine("BorderBottom", 0,               height - thickness, width,  thickness)
  makeLine("BorderLeft",   0,               0,                thickness, height)
  makeLine("BorderRight",  width - thickness, 0,              thickness, height)
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
local recordPayoutValue

recordProfit = function(record)
  local payoutValue = recordPayoutValue and recordPayoutValue(record)
  local cost = tonumber(record.costCopper)
  if not payoutValue or not cost then
    return nil
  end
  return payoutValue - cost
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
    return itemType == ONYX_ITEM_TYPE or ONYX_LEGACY_ITEM_TYPES[itemType] == true
  end

  local name = tostring(record.payoutName or ""):lower()
  if name == tostring(ONYX_ITEM_TYPE) or name:find("onyx", 1, true) ~= nil then
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

local function payoutDisplayName(record)
  if tonumber(record and record.payoutCopper) then
    return "Money"
  end
  if isOnyxPayout(record) then
    return ONYX_DISPLAY_NAME
  end
  return record.payoutName or "Payout"
end

payoutSearchName = function(record)
  if isOnyxPayout(record) then
    return ONYX_AUCTION_SEARCH_NAME
  end

  local name = compactText(record and record.payoutName)
  if name ~= "" and not tonumber(name) then
    return name
  end
  return nil
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
    local itemType = resolvePayoutItemType(record)
    unit = getPrice(itemType, isOnyxPayout and isOnyxPayout(record))
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

  local itemType = resolvePayoutItemType(record)
  local unit = getPrice(itemType, isOnyxPayout and isOnyxPayout(record))
  if not unit or unit <= 0 then
    return false, false
  end

  record.payoutUnitPriceCopper = unit
  record.payoutPricedAt = nowSeconds()
  return true, true
end

tryCompletePayoutValues = function()
  local changed = false
  for _, record in ipairs(state.records) do
    if not tonumber(record.payoutUnitPriceCopper) and not tonumber(record.payoutCopper) then
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
  if tonumber(record and record.costCopper) then
    return formatMoney(record.costCopper)
  end
  if record and record.costStatus == "pricing" then
    return "pricing"
  end
  return "?"
end

local function recordTotalText(record)
  local payout = recordPayoutValue and recordPayoutValue(record)
  return payout and formatMoney(payout) or "?"
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
    if itemName ~= "" and itemName ~= searchName and (not lookupItemType or lookupItemType ~= resultItemType) then
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

local function searchedAuctionPrice(itemInfo, lookup)
  if type(itemInfo) ~= "table" then
    return nil
  end

  local stackCount = tonumber(itemInfo.stackCount) or tonumber(itemInfo.count) or 1

  local bestPrice = nil
  for _, rawPrice in ipairs({
    itemInfo.directPriceStr,
    itemInfo.directPrice,
    itemInfo.priceStr,
    itemInfo.price,
    itemInfo.bidPriceStr,
    itemInfo.bidPrice
  }) do
    local price = auctionUnitPrice(rawPrice, stackCount)
    if price and auctionResultMatchesLookup(itemInfo, lookup, price) and (not bestPrice or price < bestPrice) then
      bestPrice = price
    end
  end

  return bestPrice
end

local function activeAuctionLookup()
  if runtime.activeAuctionKey and runtime.namePriceLookups[runtime.activeAuctionKey] then
    return runtime.activeAuctionKey, runtime.namePriceLookups[runtime.activeAuctionKey]
  end
  local key = runtime.lastAuctionSearchKey
  if key and runtime.namePriceLookups[key] then
    return key, runtime.namePriceLookups[key]
  end
  for lookupKey, lookup in pairs(runtime.namePriceLookups) do
    return lookupKey, lookup
  end
  for lookupKey, lookup in pairs(runtime.priceLookups) do
    return lookupKey, lookup
  end
  return nil, nil
end

handleLowestPrice = function(itemType, grade, price)
  if price == nil then
    return
  end

  local parsedItemType = tonumber(itemType)
  if not parsedItemType then
    local _, lookup = activeAuctionLookup()
    parsedItemType = lookup and lookup.itemType
  end

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
        local price = searchedAuctionPrice(itemInfo, lookup)
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
    finishAuctionLookup(key)
    runtime.lastAuctionSearchKey = nil
    runtime.auctionStatus = "No AH result"
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
  local key, lookup = activeAuctionLookup()
  readSearchedAuctionResults(key, lookup, true)
end

local function updateSummary(records)
  local totalProfit = 0
  local totalKnown = true
  local openCount = 0
  local paidCount = 0

  for _, record in ipairs(state.records) do
    if getRecordStatus(record) == "Waiting" then
      openCount = openCount + 1
      local profit = recordProfit(record)
      if profit then
        totalProfit = totalProfit + profit
      else
        totalKnown = false
      end
    else
      paidCount = paidCount + 1
    end
  end

  if openCount == 0 then
    ui.totalLabel:SetText("Expected Profit: 0g")
  elseif totalKnown then
    ui.totalLabel:SetText("Expected Profit: " .. formatMoney(totalProfit))
  else
    ui.totalLabel:SetText("Expected Profit: ?")
  end

  if ui.waitingDeliveryLabel then
    ui.waitingDeliveryLabel:SetText(tostring(openCount) .. " pending | " .. tostring(paidCount) .. " paid")
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

  return {
    packCount = packCount,
    totalProfitText = totalProfitText,
    favoritePack = favoritePack,
    averageProfitText = averageProfitText,
    dailyProfitText = dailyProfitText
  }
end

local function updateHistoryWindow()
  if not ui.historyStats then
    return
  end

  syncAllRecordsHistoryProfit()
  checkDailyReset()
  -- Daily profit must be recomputed every refresh: records sold (or priced)
  -- during the same day don't update the daily counters incrementally, so
  -- without this the displayed value freezes until the next day rollover.
  recomputeDailyProfit()
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
  addSizedParchmentTint(window, name .. "Tint", width, height)
  addWindowBorder(window, name, width, height)
  window:Show(false)
  return window
end

local function resetStatistics()
  resetHistoryTotals()
  historyState.migratedFromRecords = true
  saveHistoryState()
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
    updateHistoryWindow()
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

  makeButton("TradePacksHistoryResetStatistics", parent, 108, 400, 144, 30, "Reset Statistics", function()
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
    return "Cost: ?"
  end
  if record.costStatus == "preset" then
    return "Cost: " .. formatMoney(record.costCopper) .. " (preset)"
  end
  if record.costStatus == "snapshot" then
    return "Cost: " .. formatMoney(record.costCopper) .. " (snapshotted)"
  end
  if record.costStatus == "pricing" then
    return "Cost: pricing recipe materials"
  end
  return "Cost: unavailable"
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
  local price = getPrice(itemType, isOnyxPayout(record))
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
  setDetailLine(2, soldAtDetailText(selected) or "")

  local materials = ensureRecordMaterials(selected)
  if not materials then
    if selected.costStatus == "preset" then
      setDetailLine(3, "Preset cost is used for this cargo.")
    else
      setDetailLine(3, "Recipe data is missing for this pack.", TEXT_RED)
    end
    for index = 4, DETAIL_LINE_COUNT do
      setDetailLine(index, "")
    end
    return
  end

  local maxMaterials = DETAIL_LINE_COUNT - 2
  local shown = math.min(#materials, maxMaterials)
  for index = 1, shown do
    setDetailLine(index + 2, materialDetailText(materials[index]))
  end
  for index = shown + 3, DETAIL_LINE_COUNT do
    setDetailLine(index, "")
  end
end

local function deleteRecord(recordId)
  for index, record in ipairs(state.records) do
    if record.id == recordId then
      if syncRecordHistoryProfit(record) then
        saveHistoryState()
      end
      table.remove(state.records, index)
      if runtime.selectedRecordId == recordId then
        runtime.selectedRecordId = nil
      end
      saveState()
      refreshUi()
      return
    end
  end
end

local function clearPaidRecords()
  local historyChanged = false
  local remaining = {}
  for _, record in ipairs(state.records) do
    if getRecordStatus(record) ~= "PAID" then
      remaining[#remaining + 1] = record
    else
      if syncRecordHistoryProfit(record) then
        historyChanged = true
      end
    end
  end
  state.records = remaining
  if historyChanged then
    saveHistoryState()
  end
  saveState()
  refreshUi()
end

refreshUi = function()
  if not ui.window then
    return
  end

  markDeliveredRecordsPaid()
  sortRecords()
  local records = filteredRecords()
  local pageCount = math.max(1, math.ceil(#records / ROW_COUNT))
  runtime.pageCount = pageCount
  if runtime.page > pageCount then
    runtime.page = pageCount
  end
  if runtime.page < 1 then
    runtime.page = 1
  end

  updateSummary(records)
  ui.pageLabel:SetText(string.format("Page %d/%d", runtime.page, pageCount))

  local startIndex = (runtime.page - 1) * ROW_COUNT + 1
  updateFilterButtons()

  for rowIndex = 1, ROW_COUNT do
    local row = ui.rows[rowIndex]
    local selection = ui.selectionHighlights and ui.selectionHighlights[rowIndex]
    local deleteBtn = ui.deleteButtons and ui.deleteButtons[rowIndex]
    local record = records[startIndex + rowIndex - 1]
    row.recordId = record and record.id or nil

    if record then
      local status = getRecordStatus(record)
      local profit = recordProfit(record)
      local readyAt = (tonumber(record.soldAt) or 0) + (tonumber(record.delaySeconds) or DEFAULT_DELAY_SECONDS)
      local remaining = readyAt - nowSeconds()

      row.rownum:SetText(tostring(rowIndex))
      row.name:SetText(fitDisplayText(cargoDisplayName(record), 27))
      row.total:SetText(recordTotalText(record))
      row.cost:SetText(recordCostText(record))
      row.profit:SetText(profit and formatMoney(profit) or "?")
      if status == "Waiting" then
        row.time:SetText(formatDuration(remaining))
        styleText(row.time, TEXT_BROWN)
        styleText(row.name, TEXT_BROWN)
      elseif status == "PAID" then
        row.time:SetText("Delivered")
        styleText(row.time, TEXT_GREEN)
        styleText(row.name, TEXT_GREEN)
      else
        row.time:SetText("-")
        styleText(row.time, TEXT_BROWN)
        styleText(row.name, TEXT_BROWN)
      end

      for _, widget in pairs(row) do
        showWidget(widget, true)
      end
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
end

local function setFilter(filter)
  runtime.filter = filter
  runtime.page = 1
  updateFilterButtons()
  refreshUi()
end

local function createUi()
  local window = UIParent:CreateWidget("window", widgetName("TradePacksLedgerWindow"), "UIParent")
  if not window then
    error("failed to create TradePacks ledger window")
  end
  window:SetExtent(LEDGER_WIDTH, LEDGER_HEIGHT)
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
  if not addNativeWindowSkin(window, LEDGER_WIDTH, LEDGER_HEIGHT) then
    ui.panel = createWidget("emptywidget", "TradePacksBackgroundPanel", window, 0, 0, LEDGER_WIDTH, LEDGER_HEIGHT)
    pcall(function()
      ui.panel:SetDrawPriority(-100)
    end)
    pcall(function()
      ui.panel:Lower()
    end)
    ui.backdrop = addBackdrop(ui.panel)
  end
  window:Show(false)

  ui.window = window
  local parent = window
  ui.parchmentTint = addParchmentTint(parent)
  addWindowBorder(parent, "TradePacksLedger", LEDGER_WIDTH, LEDGER_HEIGHT)

  ui.titleLabel = makeLabel("TradePacksTitleLabel", parent, 0, 27, LEDGER_WIDTH, 30, "OSO Packs Service")
  styleText(ui.titleLabel, "brown", ALIGN_CENTER or CENTER)
  pcall(function() ui.titleLabel.style:SetFontSize(26) end)
  ui.versionLabel = makeLabel("TradePacksVersionLabel", parent, 14, 14, 80, 18, "v" .. ADDON_VERSION)
  styleText(ui.versionLabel, TEXT_BROWN, ALIGN_LEFT or LEFT)
  pcall(function() ui.versionLabel.style:SetFontSize(12) end)
  ui.totalLabel = makeLabel("TradePacksTotalLabel", parent, 0, 68, LEDGER_WIDTH, 22, "Expected Profit: ?")
  styleText(ui.totalLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
  ui.loadingLabel = makeLabel("TradePacksLoadingLabel", parent, 218, 92, 178, 22, "Prices Are Loading")
  styleText(ui.loadingLabel, TEXT_GREEN)
  pcall(function()
    ui.loadingLabel.style:SetOutline(true)
  end)
  ui.loadingLabel:Show(false)
  ui.pageLabel = makeLabel("TradePacksPageLabel", parent, 474, 726, 78, 22, "Page 1/1")
  styleText(ui.pageLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
  makeSeparator("TradePacksTopSeparator", parent, 24, 94, 552)

  makeButton("TradePacksRefreshButton", parent, 473, 55, 74, 32, "Refresh", function()
    startAuctionRefresh()
  end)
  makeTextButton("TradePacksCloseButton", parent, 561, 62, 20, 22, "X", function()
    window:Show(false)
    runtime.windowVisible = false
  end)
  local btnAll = makeButton("TradePacksFilterAll", parent, 31, 114, 66, 32, "All", function()
    setFilter("all")
  end)
  local btnPending = makeButton("TradePacksFilterPending", parent, 127, 114, 84, 32, "Pending", function()
    setFilter("pending")
  end)
  local btnReady = makeButton("TradePacksFilterReady", parent, 226, 114, 66, 32, "Paid", function()
    setFilter("ready")
  end)
  ui.filterButtons = { all = btnAll, pending = btnPending, ready = btnReady }
  ui.waitingDeliveryLabel = makeLabel("TradePacksWaitingDeliveryLabel", parent, 374, 119, 202, 22, "0 pending | 0 paid")
  styleText(ui.waitingDeliveryLabel, TEXT_BROWN, ALIGN_RIGHT or RIGHT)

  local headers = {
    { "#",         4,   174, 16  },
    { "Pack Name", 20,  174, 190 },
    { "Total",     218, 174, 90  },
    { "Cost",      316, 174, 100 },
    { "Profit",    424, 174, 76  },
    { "ETA",       508, 174, 60  },
  }

  for index, header in ipairs(headers) do
    local headerLabel = makeLabel("TradePacksHeader" .. index, parent, header[2], header[3], header[4], 20, header[1])
    styleText(headerLabel, TEXT_BROWN, ALIGN_CENTER or CENTER)
  end
  makeSeparator("TradePacksHeaderSeparator", parent, 24, 157, 552)

  ui.selectionHighlights = {}
  ui.deleteButtons = {}
  for i = 1, ROW_COUNT do
    local y = 207 + (i - 1) * 30
    local row = {}
    ui.selectionHighlights[i] = makeSelectionHighlight("TradePacksSelection" .. i, parent, 0, y - 2, LEDGER_WIDTH, 28)
    row.rownum = makeLabel("TradePacksRowNum" .. i, parent, 4,   y + 4, 16,  20, "")
    row.name   = makeLabel("TradePacksName"   .. i, parent, 20,  y + 4, 190, 20, "")
    row.total  = makeLabel("TradePacksTotal"  .. i, parent, 218, y + 4, 90,  20, "")
    row.cost   = makeLabel("TradePacksCost"   .. i, parent, 316, y + 4, 100, 20, "")
    row.profit = makeLabel("TradePacksProfit" .. i, parent, 424, y + 4, 76,  20, "")
    row.time   = makeLabel("TradePacksTime"   .. i, parent, 508, y + 4, 60,  20, "")
    styleText(row.rownum, TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.name,   TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.total,  TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.cost,   TEXT_BROWN, ALIGN_CENTER or CENTER)
    styleText(row.profit, TEXT_BROWN, ALIGN_CENTER or CENTER)
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

    local deleteBtn = makeTextButton("TradePacksDelete" .. i, parent, 576, y + 4, 16, 20, "x", function()
      if row.recordId then
        deleteRecord(row.recordId)
      end
    end)
    styleText(deleteBtn, TEXT_RED)
    deleteBtn:Show(false)
    ui.deleteButtons[i] = deleteBtn
  end

  makeSeparator("TradePacksDetailSeparator", parent, 24, 548, 552)
  ui.detailTitle = makeLabel("TradePacksDetailTitle", parent, 31, 568, 538, 20, "Details")
  ui.detailLines = {}
  for i = 1, DETAIL_LINE_COUNT do
    ui.detailLines[i] = makeLabel("TradePacksDetailLine" .. i, parent, 31, 598 + (i - 1) * 18, 538, 16, "")
    styleText(ui.detailLines[i], TEXT_BROWN, ALIGN_CENTER or CENTER)
  end

  makeButton("TradePacksHistoryButton", parent, 31, 726, 82, 24, "history", function()
    showHistoryWindow()
  end)
  makeButton("TradePacksClearPaid", parent, 122, 726, 82, 24, "Clear Paid", function()
    clearPaidRecords()
  end)
  makeTextButton("TradePacksFirstPage", parent, 418, 726, 26, 22, "<<", function()
    runtime.page = 1
    refreshUi()
  end)
  makeTextButton("TradePacksPrevPage", parent, 446, 726, 26, 22, "<", function()
    runtime.page = runtime.page - 1
    refreshUi()
  end)
  makeTextButton("TradePacksNextPage", parent, 554, 726, 26, 22, ">", function()
    runtime.page = runtime.page + 1
    refreshUi()
  end)
  makeTextButton("TradePacksLastPage", parent, 582, 726, 26, 22, ">>", function()
    runtime.page = runtime.pageCount or 999
    refreshUi()
  end)

  createHistoryWindow()

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
  end)
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

    if runtime.auctionRefreshPending then
      runtime.auctionRefreshDelay = runtime.auctionRefreshDelay - dt
      if runtime.auctionRefreshDelay <= 0 then
        runtime.auctionRefreshPending = false
        startAuctionRefresh(true)
      end
    end

    runtime.dailyCheckElapsed = runtime.dailyCheckElapsed + dt
    if runtime.dailyCheckElapsed >= 60 then
      runtime.dailyCheckElapsed = 0
      if historyState.dailyStartTime < currentDayKeyUtc2() then
        recomputeDailyProfit()
        saveHistoryState()
        updateHistoryWindow()
      end
    end
  end)

  window:SetHandler("OnUpdate", function(_, elapsed)
    runtime.windowVisible = window:IsVisible()
    if not runtime.windowVisible then
      return
    end
    local dt = normalizedElapsed(elapsed)
    updateAuctionLookups(dt)
    updateLoadingLabel(dt)
    runtime.uiUpdateElapsed = runtime.uiUpdateElapsed + dt
    if runtime.uiUpdateElapsed >= 1 then
      runtime.uiUpdateElapsed = 0
      refreshUi()
    end
  end)

  window:SetHandler("OnEvent", function(_, eventName, ...)
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
  end)

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
createUi()

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
