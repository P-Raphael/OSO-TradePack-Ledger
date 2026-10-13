-- Run from the Addon directory: lua TradePacks/tests/test_rate_costs.lua
-- Exercise the actual ledger adapter and context wiring without auction calls.
local clock, writes, reads, ctx = 1700000000, 0, 0
local saved, logs = {}, {}
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, part in pairs(value) do result[key] = copy(part) end
  return result
end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, part in pairs(a) do if not same(part, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end
ADDON = {
  ImportAPI = function() end, ImportObject = function() end,
  GetCurrentTimeStamp = function() return clock end,
  LoadData = function(_, key) reads = reads + 1; return copy(saved[key]) end,
  SaveData = function(_, key, value) writes = writes + 1; saved[key] = copy(value) end,
  ClearData = function(_, key) writes = writes + 1; saved[key] = nil end,
  ChatLog = function(_, message) logs[#logs + 1] = message end,
  RegisterContentWidget = function() end
}
local Widget = {}
Widget.__index = function(_, key) return Widget[key] or function() end end
local function newWidget()
  return setmetatable({handlers = {}, visible = false, style = setmetatable({}, Widget)}, Widget)
end
function Widget:CreateChildWidget() return newWidget() end
function Widget:CreateColorDrawable() return newWidget() end
function Widget:CreateImageDrawable() return newWidget() end
function Widget:CreateIconDrawable() return newWidget() end
function Widget:SetHandler(event, handler) self.handlers[event] = handler end
function Widget:SetText(value) self.text = value end
function Widget:GetText() return self.text end
function Widget:Show(value) self.visible = value end
function Widget:IsVisible() return self.visible end
function Widget:GetOffset() return 0, 0 end
function Widget:GetHeight() return self.height end
function Widget:GetWidth() return self.width end
function Widget:SetExtent(width, height) self.width, self.height = width, height end
UIParent = {CreateWidget = function() return newWidget() end}
TradePacksRateWatch = {new = function(context) ctx = context; return {} end}
saved.TradePacksState = {version = 2, nextId = 2, prices = {}, records = {
  {id = 1, cargoName = "Test Pack", soldAt = clock - 3600,
   costCopper = 99999999, costStatus = "manual", costSource = "manual", payoutCopper = 500000}
}, settings = {costPresets = {["Auroran Cargo"] = 260000}, repairedContaminatedPayouts = true}}
dofile("TradePacks/Packsresources.lua")
dofile("TradePacks/TradePacks.lua")
for _, message in ipairs(logs) do assert(not message:find("failed", 1, true), message) end
assert(ctx and type(ctx.costEstimate) == "function", "graph did not receive cost adapter")
local runtime
for i = 1, 60 do
  local name, value = debug.getupvalue(ctx.costEstimate, i)
  if not name then break end
  if name == "runtime" then runtime = value; break end
end
assert(runtime, "missing runtime closure")
local state, rules = TradePacksLedger.State, runtime.costRules
X2Auction = setmetatable({}, {__index = function()
  error("cost preview must not access the auction API")
end})
local function estimate(pack)
  local beforeState, beforeRules, beforeSaved = copy(state), copy(rules), copy(saved)
  local beforeReads, beforeWrites = reads, writes
  local result = ctx.costEstimate(pack)
  assert(reads == beforeReads and writes == beforeWrites, "preview touched persistence")
  assert(same(state, beforeState), "preview changed ledger state")
  assert(same(rules, beforeRules) and same(saved, beforeSaved), "preview changed saved cost rules")
  return result
end
local function price(name, copper, age)
  state.prices["name:" .. name:lower()] = {copper = copper, updatedAt = clock - (age or 0)}
end
local function zeroExtras(pack)
  rules.transport[pack] = {fuelQty = 0, greaseQty = 0}
  rules.labor[pack] = {points = 0}
end
local function contains(text, part) assert(text and text:find(part, 1, true), tostring(text)) end

-- A historical manually priced sale does not establish current graph costs.
local result = estimate("Test Pack")
assert(result.totalCopper == nil and #result.missingComponents == 3)
contains(result.missing, "Materials: not configured")
contains(result.missing, "Transport: not configured")
contains(result.missing, "Labor: not configured")
assert(estimate(nil).totalCopper == nil)

state.settings.costPresets["Test Pack"] = 10000
zeroExtras("Test Pack")
result = estimate("Test Pack")
assert(result.totalCopper == 10000 and result.transportCopper == 0 and result.laborCopper == 0)
assert(not result.missing and not result.usesCachedPrices)

-- Exact pack settings, manual amounts, explicit free items, and rule precedence.
rules.materials["Test Pack"] = {items = {{name = "Dried Flowers", qty = 3, price = 200}}}
rules.transport["Test Pack"] = {fuelQty = 2, fuelPrice = 400, greaseQty = 3, greasePrice = 150}
result = estimate("Test Pack")
assert(result.materialsCopper == 600 and result.transportCopper == 1250 and result.totalCopper == 1850)
rules.materials["Test Pack"].items[1].price = 0
assert(estimate("Test Pack").materialsCopper == 0, "manual zero should be honored")
assert(estimate("Other Pack").totalCopper == nil, "costs leaked between pack types")

-- AUTO missing quotes never silently become free; a positive manual fallback works.
local item = rules.materials["Test Pack"].items[1]
item.auto = true
result = estimate("Test Pack")
assert(result.totalCopper == nil)
contains(result.missing, "price missing for Dried Flowers")
item.price = 120
assert(estimate("Test Pack").materialsCopper == 360)
price("Dried Flowers", 300)
assert(estimate("Test Pack").materialsCopper == 900)
price("Dried Flowers", 400)
assert(estimate("Test Pack").materialsCopper == 1200, "preview retained old material snapshot")
rules.transport["Test Pack"].fuelAuto = true
rules.transport["Test Pack"].fuelPrice = 0
contains(estimate("Test Pack").missing, "price missing for Eco-Friendly Fuel")
rules.transport["Test Pack"].fuelPrice = 25
assert(estimate("Test Pack").transportCopper == 500)
price("Eco-Friendly Fuel", 100)
assert(estimate("Test Pack").transportCopper == 650)
rules.transport["Test Pack"].fuelQty = 0
price("Eco-Friendly Fuel", nil)
assert(estimate("Test Pack").transportCopper == 450)
rules.transport["Test Pack"].greaseQty = nil
contains(estimate("Test Pack").missing, "invalid amount for Axle Grease")
zeroExtras("Test Pack")

-- Labor uses the cheapest cached cost per restored point, not item sticker price.
rules.labor["Test Pack"] = {points = 110}
contains(estimate("Test Pack").missing, "Labor: waiting for auction price")
price("Worker's Compensation: 50", 50000)
price("Worker's Compensation: 500", 400000)
price("Worker's Compensation", 900000)
result = estimate("Test Pack")
assert(result.laborCopper == 88000 and result.laborSource == "Worker's Compensation: 500")
price("Worker's Compensation", 700000)
assert(estimate("Test Pack").laborCopper == 77000, "updated labor quote was ignored")
price("Worker's Compensation: 500", 100000, 7 * 3600)
assert(estimate("Test Pack").laborCopper == 77000, "stale quote outranked fresh labor quotes")
price("Worker's Compensation", 700000, 7 * 3600)
price("Worker's Compensation: 50", 50000, 7 * 3600)
result = estimate("Test Pack")
assert(result.laborCopper == 22000 and result.stalePrices and result.usesCachedPrices)
rules.labor["Test Pack"].points = -1
contains(estimate("Test Pack").missing, "Labor: invalid amount")

-- Recipe defaults require every tradable item; bound quest Gilda remains zero.
Nuia_Specialty["Graph Recipe"] = {{2, 3, 4}, {4, 2, 7}}
zeroExtras("Graph Recipe")
price("Ground Grain", nil)
contains(estimate("Graph Recipe").missing, "price missing for Ground Grain")
price("Ground Grain", 50)
result = estimate("Graph Recipe")
assert(result.materialsCopper == 950 and result.totalCopper == 950)
price("Dried Flowers", 500, 7 * 3600)
result = estimate("Graph Recipe")
assert(result.materialsCopper == 1150 and result.stalePrices)
Nuia_Specialty["Graph Recipe"] = {{2, 3, 4}, {4, 2, 99999}}
contains(estimate("Graph Recipe").missing, "unknown recipe resource 99999")
rules.materials["Graph Recipe"] = {items = {false}}
contains(estimate("Graph Recipe").missing, "invalid saved item")
rules.materials["Graph Recipe"] = {items = {}, boundItems = {{name = "Gilda Star", qty = 3}}}
assert(estimate("Graph Recipe").totalCopper == 0)
zeroExtras("Auroran Cargo")
assert(estimate("Auroran Cargo").materialsCopper == 260000, "cargo preset was not used")
print("TradePacks rate cost preview: exact rules, AUTO/missing quotes, recipes, labor and read-only checks passed")
