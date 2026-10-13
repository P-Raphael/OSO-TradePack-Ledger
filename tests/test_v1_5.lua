-- Run from the Addon directory: lua TradePacks/tests/test_v1_5.lua
local clock = 1700000000
local widgetSuffix
local saved, logs, widgets = {}, {}, {}
local failRunWrites = false
local failHistoryWrites = false
local failHistoryMapWrites = false
local failCostRuleWrites = false
local quantizeNumbers = false
local failPackMenuCreation = false

local function copy(value)
  if type(value) == "number" and quantizeNumbers then
    return string.unpack("f", string.pack("f", value))
  end
  if type(value) ~= "table" then return value end
  local result = {}
  for key, part in pairs(value) do result[copy(key)] = copy(part) end
  return result
end

ADDON = {
  ImportAPI = function() end,
  ImportObject = function() end,
  GetCurrentTimeStamp = function() return clock end,
  LoadData = function(_, key) return copy(saved[key]) end,
  SaveData = function(_, key, value)
    saved[key] = copy(value)
    if failRunWrites and key:match("^TradePacksRuns[AB]_%d+$") then
      saved[key][#saved[key]] = nil
    end
    if failHistoryWrites and key:match("^TradePacksHistory[AB]$") then
      saved[key].totalProfitCopper = nil
    end
    if failHistoryMapWrites and key:match("^TradePacksHistory[AB]%a+_%d+$") then
      saved[key][#saved[key]] = nil
    end
    if failCostRuleWrites and key:match("^TradePacksCostRules[AB]$") then
      saved[key].materials = nil
    end
  end,
  ClearData = function(_, key) saved[key] = nil end,
  ChatLog = function(_, message) logs[#logs + 1] = message end,
  RegisterContentWidget = function() end
}

local Widget = {}
Widget.__index = function(_, key)
  return Widget[key] or function() end
end
local function newWidget(name, kind)
  local widget = setmetatable({name = name, kind = kind, handlers = {}, visible = true}, Widget)
  widget.style = setmetatable({}, Widget)
  widgets[name] = widget
  return widget
end
function Widget:CreateChildWidget(kind, name)
  if failPackMenuCreation and name == "TradePacksPackMenu" .. widgetSuffix then return nil end
  return newWidget(name, kind)
end
function Widget:CreateColorDrawable() return newWidget("drawable") end
function Widget:CreateImageDrawable() return newWidget("image") end
function Widget:CreateIconDrawable() return newWidget("icon") end
function Widget:SetHandler(event, handler) self.handlers[event] = handler end
function Widget:SetStyle()
  self.autoSized = true
  self.width, self.height = 55, 22
end
function Widget:SetText(value)
  self.text = value
  if rawget(self, "autoSized") then self.width = #value * 9 + 20 end
end
function Widget:GetText()
  if self.kind == "editbox" then return end -- Mirrors the broken client widget.
  return self.text
end
function Widget:Show(value) self.visible = value end
function Widget:IsVisible() return self.visible end
function Widget:GetOffset() return 0, 0 end
function Widget:GetHeight() return self.height end
function Widget:GetWidth() return self.width end
function Widget:SetExtent(width, height) self.width, self.height = width, height end
function Widget:UseResizing(value) self.resizable = value end
function Widget:SetMinResizingExtent(width, height) self.minResize = {width, height} end
function Widget:SetMaxResizingExtent(width, height) self.maxResize = {width, height} end
function Widget:StartSizing(anchor) self.resizingAnchor = anchor end
function Widget:StopMovingOrSizing() self.resizingAnchor = nil end
function Widget:AddAnchor(_, _, x, y)
  if type(x) == "number" and type(y) == "number" then self.x, self.y = x, y end
end
UIParent = {CreateWidget = function(_, kind, name) return newWidget(name, kind) end}

local function widget(prefix)
  return assert(widgets[prefix .. widgetSuffix], "missing widget: " .. prefix)
end
local function click(prefix)
  local control = widget(prefix)
  assert(control.handlers.OnClick, "missing click handler: " .. prefix)
  control.handlers.OnClick(control)
end
local function history()
  local meta = saved.TradePacksHistoryMeta
  return meta and saved["TradePacksHistory" .. meta.bank]
end
local function costRules()
  local meta = saved.TradePacksCostRulesMeta
  return meta and saved["TradePacksCostRules" .. meta.bank]
end
local function recordById(id)
  for _, record in ipairs(TradePacksLedger.State.records) do
    if record.id == id then return record end
  end
end
local function loadAddon()
  widgets = {}
  widgetSuffix = tostring(clock)
  dofile("TradePacks/MinuteHistory.lua")
  dofile("TradePacks/RateRoutes.lua")
  dofile("TradePacks/RateChart.lua")
  dofile("TradePacks/RateCombined.lua")
  dofile("TradePacks/RateWatch.lua")
  dofile("TradePacks/TradePacks.lua")
  -- Display assertions exercise visible windows. Closed windows deliberately
  -- skip repainting; test_turnin_performance.lua covers that behavior.
  widget("TradePacksLedgerWindow"):Show(true)
  click("TradePacksFilterAll")
  click("TradePacksHistoryButton")
  for _, message in ipairs(logs) do
    assert(not message:find("createUi failed", 1, true), message)
    assert(not message:find("save failed", 1, true), message)
  end
end

local records = {}
for id = 1, 15 do
  local onyx = id == 15
  records[id] = {
    id = id, cargoName = "Pack " .. id, soldAt = clock - (16 - id) * 3600,
    costCopper = 20000, costStatus = "manual", costSource = "manual",
    payoutCopper = not onyx and 100000 or nil,
    payoutItemType = onyx and 32103 or nil,
    payoutName = onyx and "Onyx" or nil,
    payoutCount = onyx and 1 or nil,
    payoutUnitPriceCopper = onyx and 100000 or nil,
    delaySeconds = 8 * 3600
  }
end
saved.TradePacksState = {
  version = 2, nextId = 16, records = records, prices = {},
  settings = {costPresets = {['Auroran Cargo'] = 260000}, opener = {x = 24, y = 260},
    repairedContaminatedPayouts = true}
}
saved.TradePacksPrices = {
  ["name:worker's compensation: 500"] = {copper = 500000, updatedAt = clock}
}

loadAddon()
assert(widget("TradePacksLedgerWindow").height == 864)
assert(widget("TradePacksFloatingButton").width == 47,
  "the OPS launcher should use its original skin-sized button")
local function separated(names, gap)
  for i = 2, #names do
    local left, right = widget(names[i - 1]), widget(names[i])
    assert(left.x + left.width + gap <= right.x,
      names[i - 1] .. " overlaps " .. names[i])
  end
end
separated({"TradePacksFilterAll", "TradePacksFilterPending", "TradePacksFilterReady"}, 7)
assert(widgets["TradePacksFilterReceived" .. widgetSuffix] == nil)
assert(widgets["TradePacksConfirmReceipt" .. widgetSuffix] == nil)
separated({"TradePacksDateFilter", "TradePacksPackFilter", "TradePacksUnpricedFilter",
  "TradePacksFilterArchived", "TradePacksPayoutFilter"}, 7)
separated({"TradePacksDueAlerts", "TradePacksMaterialsEditor",
  "TradePacksTransportEditor", "TradePacksLaborEditor"}, 6)
assert(widget("TradePacksHeader1").y >= widget("TradePacksPayoutFilter").y
  + widget("TradePacksPayoutFilter").height + 10)
assert(widget("TradePacksDetailLine8").y + widget("TradePacksDetailLine8").height
  < widget("TradePacksMaterialsEditor").y)
assert(widget("TradePacksHistoryButton").y + widget("TradePacksHistoryButton").height
  < widget("TradePacksLedgerWindow").height)
assert(widget("TradePacksName12").text == "Pack 4", "twelfth pack is not visible")
assert(widget("TradePacksTime12").y + widget("TradePacksTime12").height
  < widget("TradePacksDetailTitle").y, "ledger rows overlap details")
assert(widget("TradePacksPageLabel").text == "Page 1/2")
click("TradePacksNextPage")
assert(widget("TradePacksName1").text == "Pack 3", "second page starts at the wrong pack")
assert(widget("TradePacksName3").text == "Pack 1")
assert(widget("TradePacksName4").visible == false)
click("TradePacksFirstPage")
local ledger = widget("TradePacksLedgerWindow")
local grip = widget("TradePacksResizeGrip")
assert(ledger.resizable and ledger.minResize[2] == 744 and ledger.maxResize[2] >= 984)
assert(ledger.maxResize[1] == 990)
assert(grip.handlers.OnDragStart and grip.handlers.OnDragStop)
grip.handlers.OnDragStart(grip)
assert(ledger.resizingAnchor == "BOTTOMRIGHT")
ledger:SetExtent(660, 984) -- grow from 12 to 16 rows
ledger.handlers.OnUpdate(ledger, 0)
assert(widget("TradePacksPageLabel").text == "Page 1/1")
assert(widget("TradePacksName15").text == "Pack 1")
assert(widget("TradePacksName16").visible == false)
assert(widget("TradePacksParchmentTint").height == 984)
assert(widget("TradePacksLedgerBorderBottom").y == 982)
assert(widget("TradePacksHistoryButton").y == 946)
assert(widget("TradePacksResizeGrip").y == 969)
assert(widget("TradePacksTime16").y + widget("TradePacksTime16").height
  < widget("TradePacksDetailTitle").y)
ledger:SetExtent(660, 744) -- shrink to eight rows
ledger.handlers.OnUpdate(ledger, 0)
assert(widget("TradePacksPageLabel").text == "Page 1/2")
assert(widget("TradePacksName9").visible == false)
ledger:SetExtent(660, 864)
grip.handlers.OnDragStop(grip)
assert(rawget(ledger, "resizingAnchor") == nil)
assert(saved.TradePacksLedgerRows.rows == 12)
ledger:SetExtent(990, 864)
ledger.handlers.OnUpdate(ledger, 0)
assert(widget("TradePacksName1").width == 520)
assert(widget("TradePacksTotal1").x == 544)
assert(widget("TradePacksResizeGrip").x == 962)
grip.handlers.OnDragStop(grip)
assert(saved.TradePacksLedgerRows.width == 990)
local fullPackName = "Karkasse Commercial Gilda Specialty"
local originalPackName = recordById(1).cargoName
recordById(1).cargoName = fullPackName
assert(widget("TradePacksPackFilter").width == 152)
assert(widget("TradePacksPackMenu").visible == false)
click("TradePacksPackFilter")
assert(widget("TradePacksPackMenu").visible == true)
assert(widget("TradePacksPackChoice1").text == "All packs")
assert(widget("TradePacksPackChoice2").text == fullPackName,
  "dropdown must show the complete pack name")
click("TradePacksPackChoice2")
assert(widget("TradePacksPackMenu").visible == false)
assert(widget("TradePacksPackFilter").width == 152,
  "selecting a pack resized the filter button")
assert(widget("TradePacksName1").text == fullPackName,
  "the widened pack-name column still truncates a name that fits")
ledger:SetExtent(660, 864)
ledger.handlers.OnUpdate(ledger, 0)
assert(widget("TradePacksName1").text ~= fullPackName
  and widget("TradePacksName1").text:sub(-3) == "...",
  "the compact ledger should still shorten names that exceed its column")
ledger:SetExtent(990, 864)
ledger.handlers.OnUpdate(ledger, 0)
assert(widget("TradePacksName1").text == fullPackName,
  "growing the ledger should restore the full pack name immediately")
assert(widget("TradePacksPageLabel").text == "Page 1/1")
click("TradePacksPackFilter")
click("TradePacksPackChoice1") -- All packs
recordById(1).cargoName = originalPackName
click("TradePacksPackFilter")
click("TradePacksPackMenuNext")
assert(widget("TradePacksPackMenuPage").text == "Page 2/2")
assert(widget("TradePacksPackChoice1").text == "All packs")
assert(widget("TradePacksPackChoice2").text == "Pack 3")
click("TradePacksPackChoice8") -- Pack 9
assert(widget("TradePacksName1").text == "Pack 9")
click("TradePacksPackFilter")
click("TradePacksPackChoice1") -- All packs
assert(widget("TradePacksPackFilter").text == "Pack: All")
click("TradePacksPackFilter")
click("TradePacksFilterReady")
assert(widget("TradePacksPackMenu").visible == false,
  "changing another filter should close the pack dropdown")
click("TradePacksFilterAll")
assert(saved.TradePacksRunsMeta, "run manifest was not created")
local runManifest = saved["TradePacksRunsManifest" .. saved.TradePacksRunsMeta.bank]
assert(runManifest.count == 15 and runManifest.chunks == 2, "all 15 runs must be saved in chunks")
assert(widget("TradePacksRunPage").text == "Runs 1/4 (15)")
click("TradePacksRunOlder")
assert(widget("TradePacksRunPage").text == "Runs 2/4 (15)")

click("TradePacksPayoutFilter")
assert(widget("TradePacksPayoutFilter").text == "Payout: Money")
click("TradePacksPayoutFilter")
assert(widget("TradePacksPayoutFilter").text == "Payout: Onyx")
assert(widget("TradePacksPayoutFilter").width == 125,
  "changing a label resized the filter artwork/hitbox")
assert(widget("TradePacksName1").text == "Pack 15", tostring(widget("TradePacksName1").text))
assert(widget("TradePacksName2").visible == false)

click("TradePacksName1") -- Select Pack 15 for the pack-wide editors.
assert(widget("TradePacksDetailLine2").text:find("Labor: not set (Labor editor)", 1, true))
assert(widget("TradePacksDetailLine2").text:find("Known cost:", 1, true))
click("TradePacksTransportEditor")
assert(widget("TradePacksTransportEditorSelect").text == "Pack 15")
assert(widget("TradePacksTransportEditorPackMenu").visible == false)
click("TradePacksTransportEditorSelect")
assert(widget("TradePacksTransportEditorPackMenu").visible == true)
assert(widget("TradePacksTransportEditorChoice1").text == "Pack 1")
click("TradePacksTransportEditorSelect")
widget("TradePacksTransportEditorfuelQty"):SetText("1")
widget("TradePacksTransportEditorfuelG"):SetText("1")
widget("TradePacksTransportEditorgreaseQty"):SetText("2")
widget("TradePacksTransportEditorgreaseS"):SetText("50")
click("TradePacksTransportEditorSave")
assert(costRules().transport["Pack 15"].fuelQty == 1)
assert(costRules().transport["Pack 15"].greaseQty == 2)
assert(recordById(15).transportCostCopper == 20000)
assert(history().totalProfitCopper == 15 * 80000 - 20000)
click("TradePacksLaborEditor")
assert(widget("TradePacksLaborEditorpoints").kind == "editboxmultiline",
  "labor points must use the client editbox with a working GetText")
widget("TradePacksLaborEditorpoints"):SetText("10")
assert(widgets["TradePacksLaborEditorrateS" .. widgetSuffix] == nil,
  "the manual labor rate field should be removed")
assert(widget("TradePacksLaborEditorLaborSource").text == "Lowest: Worker's Compensation: 500")
click("TradePacksLaborEditorSave")
assert(costRules().labor["Pack 15"].rate == nil)
widget("TradePacksLaborEditorpoints").kind = "editbox"
click("TradePacksLaborEditorSave")
assert(widget("TradePacksLaborEditorStatus").text == "Enter valid labor points",
  "an editbox that returns no text should report invalid input without a Lua error")
widget("TradePacksLaborEditorpoints").kind = "editboxmultiline"
assert(recordById(15).laborCostCopper == 10000)
assert(history().totalProfitCopper == 15 * 80000 - 30000)
assert(widget("TradePacksCost1").text == "5g")
assert(widget("TradePacksMargin1").text == "+100%")
click("TradePacksMaterialsEditor")
widget("TradePacksMaterialsEditortotalG"):SetText("3")
click("TradePacksMaterialsEditorSave")
assert(recordById(15).costCopper == 30000)
assert(saved.TradePacksState.settings.costPresets["Pack 15"] == 30000)
assert(history().totalProfitCopper == 15 * 80000 - 40000)

assert(widget("TradePacksDueAlerts").text == "Alerts: Off")
click("TradePacksDueAlerts")
assert(saved.TradePacksState.settings.dueAlerts == true)
local waiting = {
  id = 16, cargoName = "Fresh Pack", soldAt = clock, delaySeconds = 10,
  received = true, receivedAt = clock, paid = true,
  costCopper = 20000, payoutCopper = 100000
}
TradePacksLedger.State.records[#TradePacksLedger.State.records + 1] = waiting
clock = clock + 11
local opener = widget("TradePacksFloatingButton")
opener.handlers.OnUpdate(opener, 10)
click("TradePacksPayoutFilter") -- All
click("TradePacksFilterPending")
assert(waiting.paid == false, "legacy early paid marker survived before eight hours")
assert(widget("TradePacksName1").text == "Fresh Pack",
  "a legacy receipt flag should not hide a waiting pack")
assert(widget("TradePacksWaitingDeliveryLabel").text:find("delivered", 1, true))
clock = clock + 8 * 3600
opener.handlers.OnUpdate(opener, 10)
assert(waiting.paid == true)
click("TradePacksFilterReady")
assert(widget("TradePacksName1").text == "Fresh Pack")
assert(widget("TradePacksTime1").text == "Delivered")
local savedWaiting
for chunkIndex = 1, saved.TradePacksState.recordChunkCount do
  local chunk = saved["TradePacksRecords" .. saved.TradePacksState.recordBank .. "_" .. chunkIndex]
  for _, record in ipairs(chunk) do
    if record.id == 16 then savedWaiting = record end
  end
end
assert(savedWaiting and savedWaiting.delaySeconds == nil and savedWaiting.received == nil)
local notices = 0
for _, message in ipairs(logs) do
  if message:find("payment", 1, true) and message:find("delivered", 1, true) then notices = notices + 1 end
end
assert(notices == 1, "delivery alert must fire once")
opener.handlers.OnUpdate(opener, 10)
notices = 0
for _, message in ipairs(logs) do
  if message:find("payment", 1, true) and message:find("delivered", 1, true) then notices = notices + 1 end
end
assert(notices == 1, "delivery alert repeated")
click("TradePacksArchiveDelivered")
assert(waiting.archived == true, "Archive Done did not archive delivered packs")
click("TradePacksFilterArchived")
click("TradePacksArchiveDelivered")
assert(waiting.archived == false, "Restore All did not restore archived packs")

loadAddon()
runManifest = saved["TradePacksRunsManifest" .. saved.TradePacksRunsMeta.bank]
assert(runManifest.count == 16, "run history or recovered sale was lost after reload")
assert(widget("TradePacksRunPage").text == "Runs 1/4 (16)")
assert(recordById(15).transportCostCopper == 20000)
assert(recordById(15).laborCostCopper == 10000)
assert(recordById(15).costCopper == 30000)
assert(widget("TradePacksLedgerWindow").width == 990)
assert(saved.TradePacksState.settings.dueAlerts == true)

-- Simulate migration from the former 12-run summary, using retained record IDs.
local oldHistory = saved["TradePacksHistory" .. saved.TradePacksHistoryMeta.bank]
oldHistory.runBank = nil
saved.TradePacksRunsMeta = nil
loadAddon()
assert(saved["TradePacksRunsManifest" .. saved.TradePacksRunsMeta.bank].count == 16,
  "older runs with retained records were not backfilled")

-- A truncated new run chunk must leave the previously committed pair readable.
local committedRunsBank = saved.TradePacksRunsMeta.bank
local committedHistoryBank = saved.TradePacksHistoryMeta.bank
local laborPoints = 10
local function increaseLaborPoints()
  if not widgets["TradePacksLaborEditorSave" .. widgetSuffix] then
    click("TradePacksPayoutFilter") -- Money
    click("TradePacksPayoutFilter") -- Onyx
    click("TradePacksName1")
    click("TradePacksLaborEditor")
  end
  laborPoints = laborPoints + 10
  widget("TradePacksLaborEditorpoints"):SetText(tostring(laborPoints))
  click("TradePacksLaborEditorSave")
end
failRunWrites = true
increaseLaborPoints()
assert(saved.TradePacksRunsMeta.bank == committedRunsBank)
assert(saved.TradePacksHistoryMeta.bank == committedHistoryBank)
failRunWrites = false
logs = {}
loadAddon()
assert(saved["TradePacksRunsManifest" .. saved.TradePacksRunsMeta.bank].count == 16)
assert(history().totalProfitCopper == 16 * 80000 - 50000,
  "profit change was not recovered after the failed run save")

-- Run chunks may write successfully while the matching aggregate write fails.
committedRunsBank = saved.TradePacksRunsMeta.bank
committedHistoryBank = saved.TradePacksHistoryMeta.bank
failHistoryWrites = true
increaseLaborPoints()
assert(saved.TradePacksRunsMeta.bank == committedRunsBank)
assert(saved.TradePacksHistoryMeta.bank == committedHistoryBank)
failHistoryWrites = false
logs = {}
loadAddon()
assert(history().totalProfitCopper == 16 * 80000 - 60000,
  "aggregate and run bank diverged after a partial history save")

-- If the active run chunk is damaged, use the prior matching history/run pair.
local activeChunk = "TradePacksRuns" .. saved.TradePacksRunsMeta.bank .. "_1"
saved[activeChunk][#saved[activeChunk]] = nil
logs = {}
loadAddon()
local usedPreviousPair = false
for _, message in ipairs(logs) do
  if message:find("previous complete history and run copy", 1, true) then
    usedPreviousPair = true
  end
end
assert(usedPreviousPair, "damaged active run bank did not use a matching fallback")
assert(saved["TradePacksRunsManifest" .. saved.TradePacksRunsMeta.bank].count == 16)

-- The actual client rounds addon numbers to single precision. UI settings,
-- records, and run totals must still read back successfully after that loss.
quantizeNumbers = true
logs = {}
loadAddon()
assert(widget("TradePacksDueAlerts").text == "Alerts: On",
  "expected an enabled alert before testing Off")
click("TradePacksDueAlerts") -- Off
assert(saved.TradePacksState.settings.dueAlerts == nil,
  "alert off did not save: " .. table.concat(logs, " | "))
assert(widget("TradePacksDueAlerts").text == "Alerts: Off")
click("TradePacksDueAlerts") -- On
assert(saved.TradePacksState.settings.dueAlerts == true)
assert(widget("TradePacksDueAlerts").text == "Alerts: On")
increaseLaborPoints()
for _, message in ipairs(logs) do
  assert(not message:find("save failed", 1, true), message)
end
failRunWrites = true
logs = {}
increaseLaborPoints()
increaseLaborPoints()
local runErrors = 0
for _, message in ipairs(logs) do
  if message:find("run save failed", 1, true) then runErrors = runErrors + 1 end
end
assert(runErrors == 1, "repeated failures should not flood chat")
ledger = widget("TradePacksLedgerWindow")
grip = widget("TradePacksResizeGrip")
ledger:SetExtent(660, 984)
grip.handlers.OnDragStop(grip)
assert(saved.TradePacksLedgerRows.rows == 16)
failRunWrites = false
logs = {}
loadAddon()
assert(widget("TradePacksLedgerWindow").height == 984,
  "resized ledger height did not survive reload")
assert(widget("TradePacksName16").visible,
  "saved ledger size did not restore the extra rows")
failPackMenuCreation = true
logs = {}
loadAddon()
assert(widget("TradePacksFloatingButton").width == 47,
  "a dropdown creation failure must not remove the OPS launcher")
click("TradePacksPackFilter") -- Fallback is inert, but must not error.
local reportedMenuFailure = false
for _, message in ipairs(logs) do
  if message:find("pack dropdown failed", 1, true) then reportedMenuFailure = true end
end
assert(reportedMenuFailure, "dropdown failure was not reported")
failPackMenuCreation = false
logs = {}
loadAddon()
assert(widget("TradePacksPackMenu"))

-- AUTO uses the existing named auction search and updates every matching pack.
local auctionHandlers, auctionResult, searchedName, auctionBuyout = {}, nil, nil, nil
UIEVENT_TYPE = {AUCTION_ITEM_SEARCHED = "AUCTION_ITEM_SEARCHED"}
UIParent.SetEventHandler = function(_, event, handler) auctionHandlers[event] = handler end
X2Auction = {
  SearchAuctionArticle = function(_, _, _, _, _, _, _, name) searchedName = name end,
  GetSearchedItemCount = function() return auctionResult and 1 or 0 end,
  GetSearchedItemInfo = function() return auctionResult end,
  GetSearchedItemPrice = function() return "999999", auctionBuyout end
}
click("TradePacksPayoutFilter") -- Money
click("TradePacksPayoutFilter") -- Onyx
click("TradePacksName1")
click("TradePacksTransportEditor")
click("TradePacksTransportEditorfuelAuto")
assert(costRules().transport["Pack 15"].fuelAuto == true)
assert(searchedName == "Eco-Friendly Fuel")
auctionResult = {name = "Eco-Friendly Fuel", directPrice = 20000, stackCount = 1}
assert(auctionHandlers.AUCTION_ITEM_SEARCHED)
auctionHandlers.AUCTION_ITEM_SEARCHED()
assert(recordById(15).transportCostCopper == 30000,
  "AUTO fuel price did not update the transport total")
assert(saved.TradePacksPrices["name:eco-friendly fuel"].copper == 20000)
local nextSale = TradePacksLedger.AddRecord("Pack 15")
assert(nextSale and nextSale.transportCostCopper == 30000,
  "future sales did not inherit the pack's transport rule")
assert(nextSale.costCopper == 30000 and nextSale.laborCostCopper == laborPoints * 1000)

-- Recipe packs expose each material quantity and unit price in their editor.
dofile("TradePacks/Packsresources.lua")
local recipeName = "Halcyona Preserved Gilda Specialty"
local recipeSale = TradePacksLedger.AddRecord(recipeName)
assert(recipeSale)
click("TradePacksPayoutFilter") -- All
click("TradePacksName1")
click("TradePacksLaborEditor")
assert(widget("TradePacksLaborEditorSelect").text:find("Halcyona", 1, true),
  "reopening Labor must select the currently highlighted pack")
widget("TradePacksLaborEditorpoints"):SetText("25")
click("TradePacksLaborEditorSave")
assert(costRules().labor[recipeName].points == 25)
assert(recipeSale.laborCostCopper == 25000,
  "labor points were not applied to the selected recipe pack")
assert(widget("TradePacksDetailLine2").text:find("Labor: 2g 50s", 1, true))
click("TradePacksMaterialsEditor")
assert(widget("TradePacksMaterialsEditormat1Name").text == "Ground Grain")
assert(widget("TradePacksMaterialsEditormat2Name").text == "Egg")
assert(widget("TradePacksMaterialsEditormat1Qty").text == "300")
widget("TradePacksMaterialsEditormat1G"):SetText("1")
widget("TradePacksMaterialsEditormat2S"):SetText("20")
click("TradePacksMaterialsEditorSave")
assert(recipeSale.costCopper == 3020000)
assert(costRules().materials[recipeName].items[1].qty == 300)
local secondRecipeSale = TradePacksLedger.AddRecord(recipeName)
assert(secondRecipeSale and secondRecipeSale.costCopper == 3020000)
failCostRuleWrites = true
widget("TradePacksMaterialsEditormat1Qty"):SetText("301")
click("TradePacksMaterialsEditorSave")
assert(recipeSale.costCopper == 3020000)
assert(costRules().materials[recipeName].items[1].qty == 300,
  "a truncated cost-rule write replaced the committed copy")
failCostRuleWrites = false
clock = clock + 3
widget("TradePacksMaterialsEditormat1Qty"):SetText("300")
click("TradePacksMaterialsEditormat1Auto")
assert(costRules().materials[recipeName].items[1].auto == true)
assert(searchedName == "Eco-Friendly Fuel")
auctionResult = {name = "Eco-Friendly Fuel", directPrice = 20000, stackCount = 1}
auctionHandlers.AUCTION_ITEM_SEARCHED()
clock = clock + 3
ledger = widget("TradePacksLedgerWindow")
ledger:Show(true)
for _ = 1, 12 do
  widget("TradePacksAuctionDriver").handlers.OnUpdate(nil, 3000)
  if searchedName == "Ground Grain" then break end
  auctionResult = {name = searchedName, directPrice = 500000, stackCount = 1}
  auctionHandlers.AUCTION_ITEM_SEARCHED()
  clock = clock + 3
end
assert(searchedName == "Ground Grain")
assert(recordById(15).laborCostCopper == laborPoints * 500,
  "a fresh labor quote should replace a stale saved rate")
auctionResult = {name = "Ground Grain", directPrice = 5000, stackCount = 1}
auctionHandlers.AUCTION_ITEM_SEARCHED()
assert(recipeSale.costCopper == 1520000 and secondRecipeSale.costCopper == 1520000,
  "AUTO material price did not refresh saved packs")

-- A lower price per restored point must replace the selected labor item and
-- update saved pack costs through the auction-result event.
click("TradePacksLaborEditor")
click("TradePacksLaborEditorRefresh")
for _ = 1, 10 do
  if searchedName == "Worker's Compensation" then break end
  auctionResult = {name = searchedName, directPrice = 500000, stackCount = 1}
  auctionHandlers.AUCTION_ITEM_SEARCHED()
  clock = clock + 3
  widget("TradePacksAuctionDriver").handlers.OnUpdate(nil, 3000)
end
assert(searchedName == "Worker's Compensation", "labor auction search was not queued")
auctionResult = {name = searchedName, stackCount = 2}
auctionBuyout = "800000"
auctionHandlers.AUCTION_ITEM_SEARCHED()
assert(saved.TradePacksPrices["name:worker's compensation"].copper == 400000,
  "the auction stack price was not reduced to a per-item price")
assert(saved.TradePacksLaborPrices["name:worker's compensation"].copper == 400000,
  "the labor quote was not saved outside the oversized general price cache")
assert(recordById(15).laborCostCopper == laborPoints * 400,
  "cheaper labor restoration did not update saved packs")
assert(nextSale.laborCostCopper == laborPoints * 400,
  "cheaper labor restoration did not update a later sale")
assert(widget("TradePacksLaborEditorLaborSource").text == "Lowest: Worker's Compensation")

-- No matching quote must not silently treat nonzero labor as free.
saved.TradePacksPrices = {}
logs = {}
loadAddon()
assert(recordById(15).laborCostCopper == laborPoints * 400,
  "the dedicated labor quote did not survive a restart")
saved.TradePacksLaborPrices = {}
saved.TradePacksPrices = {}
logs = {}
loadAddon()
assert(recordById(15).laborCostCopper == nil,
  "old manual labor cost survived without an auction quote")
click("TradePacksPayoutFilter") -- Money
click("TradePacksPayoutFilter") -- Onyx
assert(widget("TradePacksCost1").text == "pricing")

-- A growing legacy aggregate must migrate into small verified values. This
-- reproduces the history readback failure without relying on real game data.
local largeHistory = history()
local largeBank = saved.TradePacksHistoryMeta.bank
for field, manifest in pairs(largeHistory.chunkedFields) do
  local map = {}
  for i = 1, manifest.chunks do
    for _, entry in ipairs(saved["TradePacksHistory" .. largeBank .. field .. "_" .. i]) do
      map[entry.key] = entry.value
    end
  end
  largeHistory[field] = map
end
largeHistory.chunkedFields = nil
for i = 1, 300 do
  local name = "Archived specialty " .. i
  largeHistory.packCounts[name] = i
  largeHistory.profitByPack[name] = {profitCopper = i * 100, count = 1}
  largeHistory.dirtyContribs[tostring(10000 + i)] = i * 100
end
logs = {}
loadAddon()
assert(TradePacksLedger.AddRecord("History growth probe"))
local chunkedHistory = history()
assert(chunkedHistory.chunkedFields.packCounts.count >= 300)
assert(chunkedHistory.packCounts == nil and chunkedHistory.dirtyContribs == nil)
local function roughSize(value)
  if type(value) == "string" then return #value + 8 end
  if type(value) ~= "table" then return 24 end
  local size = 16
  for key, part in pairs(value) do size = size + roughSize(key) + roughSize(part) end
  return size
end
assert(roughSize(chunkedHistory) < 12000, "aggregate still exceeds the client value limit")
local committedBank = saved.TradePacksHistoryMeta.bank
for field, manifest in pairs(chunkedHistory.chunkedFields) do
  for i = 1, manifest.chunks do
    local part = saved["TradePacksHistory" .. committedBank .. field .. "_" .. i]
    assert(roughSize(part) < 12000, field .. " chunk may exceed the client value limit")
  end
end
logs = {}
loadAddon()
assert(TradePacksLedger.AddRecord("History reload probe"))
assert(history().chunkedFields.packCounts.count >= 300,
  "chunked history maps were lost during reload")

-- A torn map chunk must not move the aggregate or run commit pointers.
committedHistoryBank = saved.TradePacksHistoryMeta.bank
committedRunsBank = saved.TradePacksRunsMeta.bank
failHistoryMapWrites = true
assert(TradePacksLedger.AddRecord("History chunk failure probe"))
assert(saved.TradePacksHistoryMeta.bank == committedHistoryBank)
assert(saved.TradePacksRunsMeta.bank == committedRunsBank)
failHistoryMapWrites = false
logs = {}
loadAddon()
assert(history().chunkedFields.packCounts.count >= 300,
  "large history was lost after a failed chunk write")
local damagedHistoryBank = saved.TradePacksHistoryMeta.bank
local damagedMapKey = "TradePacksHistory" .. damagedHistoryBank .. "packCounts_1"
saved[damagedMapKey][#saved[damagedMapKey]] = nil
logs = {}
loadAddon()
local usedPreviousHistory = false
for _, message in ipairs(logs) do
  if message:find("active history save is missing", 1, true) then
    usedPreviousHistory = true
  end
end
assert(usedPreviousHistory, "damaged history map did not use the prior bank")

-- The client stores large totals as single-precision numbers. A complete
-- summary must commit even when its total rounds by a few copper on readback.
local precisionRecord = recordById(1)
local priorTotal = history().totalProfitCopper
local priorProfit = precisionRecord.payoutCopper - precisionRecord.costCopper
local largePayout = 33554433
while (priorTotal - priorProfit + largePayout - precisionRecord.costCopper) % 4 == 0 do
  largePayout = largePayout + 1
end
local exactTotal = priorTotal - priorProfit + largePayout - precisionRecord.costCopper
precisionRecord.payoutCopper = largePayout
local priorBank = saved.TradePacksHistoryMeta.bank
logs = {}
click("TradePacksHistoryButton")
assert(saved.TradePacksHistoryMeta.bank ~= priorBank,
  "a complete rounded history summary did not commit")
assert(history().totalProfitCopper ~= exactTotal,
  "precision test did not exercise single-precision rounding")
for _, message in ipairs(logs) do
  assert(not message:find("history save failed", 1, true), message)
end
print("TradePacks v1.7.0 mock checks passed")
