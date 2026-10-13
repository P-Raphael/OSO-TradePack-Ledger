-- Run from Addon: lua TradePacks/tests/test_minute_history.lua
local now, saved, reads, writes = 20000 * 86400 + 12 * 3600, {}, 0, 0
local jobs, queued = {}, {}
local failBank, failMeta = false, false
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}; for k, part in pairs(v) do out[k] = copy(part) end; return out
end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
ADDON = {
  LoadData = function(_, key) reads = reads + 1; return copy(saved[key]) end,
  SaveData = function(_, key, data)
    writes = writes + 1
    if failMeta and key:match("Meta$") then error("injected metadata failure") end
    saved[key] = copy(data)
    if failBank and key:match("[AB]$") then saved[key].minutes = nil end
  end
}
local ctx = {now = function() return now end, sameData = equal,
  enqueue = function(key, work, retry)
    if queued[key] then return end
    queued[key] = true; jobs[#jobs + 1] = {key = key, work = work, retry = retry}
  end}
local function drain()
  while #jobs > 0 do
    local job = table.remove(jobs, 1); queued[job.key] = nil
    local ok, err = pcall(job.work)
    if not ok then return false, err, job end
  end
  return true
end
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function serialize(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" then return tostring(v) end
  local out = {"{"}; for k, part in pairs(v) do out[#out + 1] = "[" .. serialize(k) .. "]=" .. serialize(part) .. "," end
  return table.concat(out) .. "}"
end
local series = {key = "TradePacksRates_22_8_test", name = "Halcyona Preserved Gilda Specialty", from = 22, to = 8}
local function keyAt(at, suffix) return series.key .. "Minute" .. math.floor(at / 3600) % 3 .. suffix end
dofile("TradePacks/MinuteHistory.lua")
local h = TradePacksMinuteHistory.new(ctx)
assert(h:sample(series, now, 130))
assert(not h:sample(series, now, 125), "same-minute duplicate overwrote first reading")
assert(not h:sample(series, now + 1, 130), "future reading accepted")
assert(not h:sample(series, now - 3 * 3600, 130), "expired reading accepted")
assert(not h:sample(series, now, 0) and not h:sample(series, now, math.huge))
assert(not h:sample(series, 0 / 0, 130))
assert(drain())
local firstMeta = copy(saved[keyAt(now, "Meta")])
assert(firstMeta.bank == "A")
assert(count(saved) == 2, "initial write needs only a bank and metadata")
local readsBefore = reads
assert(#h:rows(series, now) == 1 and h:rows(series, now)[1].ratio == 130)
assert(reads == readsBefore, "rendering performed native reads")

-- A corrupt inactive write must leave the committed pointer and bank intact.
now = now + 60
assert(h:sample(series, now, 129))
failBank = true
local ok, err, failedJob = drain()
assert(not ok and err:find("read back"))
assert(equal(firstMeta, saved[keyAt(now, "Meta")]))
assert(saved[keyAt(now, "A")].minutes[0] == 130)
failBank = false
failedJob.work()
assert(saved[keyAt(now, "Meta")].bank == "B")

-- A metadata failure also keeps the old pointer until retry succeeds.
now = now + 60
assert(h:sample(series, now, 128))
local beforeMeta = copy(saved[keyAt(now, "Meta")])
failMeta = true
ok, err, failedJob = drain()
assert(not ok and equal(beforeMeta, saved[keyAt(now, "Meta")]))
failMeta = false
failedJob.work()
local restarted = TradePacksMinuteHistory.new(ctx)
local boundedReads = reads
restarted:loadRecent(series)
assert(reads - boundedReads <= 9, "loadRecent exceeded its three-slot read bound")
assert(#restarted:rows(series, now) == 3)
assert(not restarted:sample(series, now, 140), "restart allowed same-minute duplicate")

-- Fall back to the other valid copy of the same hour if the active copy is corrupt.
local meta = saved[keyAt(now, "Meta")]
local active, inactive = meta.bank, meta.bank == "A" and "B" or "A"
local savedActive = copy(saved[keyAt(now, active)])
saved[keyAt(now, active)].minutes = nil
local fallback = TradePacksMinuteHistory.new(ctx)
fallback:loadRecent(series)
assert(#fallback:rows(series, now) == 2)
saved[keyAt(now, inactive)].minutes = nil
local corrupt = TradePacksMinuteHistory.new(ctx)
assert(not pcall(function() corrupt:loadRecent(series) end), "two corrupt banks were silently reset")
saved[keyAt(now, active)] = savedActive

-- Three hours of full observations remain small, survive UTC midnight, and leave gaps empty.
saved, jobs, queued = {}, {}, {}
h = TradePacksMinuteHistory.new(ctx)
now = 20000 * 86400 + 23 * 3600
local start = now
for i = 0, 179 do
  now = start + i * 60
  assert(h:sample(series, now, 100 + (i % 30) / 10))
  assert(drain())
end
assert(#h:rows(series, now) == 180)
assert(count(h.entries) == 3)
for _, value in pairs(saved) do assert(#serialize(value) < 16383, "minute slot exceeds SaveData capacity") end
local totalKeys = count(saved)
assert(totalKeys <= 9)
now = now + 60
assert(h:sample(series, now, 135))
assert(drain())
assert(#h:rows(series, now) == 121, "old ring slot was not replaced")
assert(count(h.entries) == 3 and count(saved) <= 9)
assert(not h:sample(series, start + 10 * 60, 99), "delayed old reading displaced the newer hour")
assert(h:rows(series, now)[121].ratio == 135)
restarted = TradePacksMinuteHistory.new(ctx)
restarted:loadRecent(series)
assert(equal(h:rows(series, now), restarted:rows(series, now)))
now = now + 10 * 86400
assert(#restarted:rows(series, now) == 0, "stale readings leaked into a later session")
assert(restarted:sample(series, now, 130) and drain())
assert(#restarted:rows(series, now) == 1 and count(saved) <= 9)

-- A queued old write/retry uses the new ring occupant rather than overwriting it.
saved, jobs, queued = {}, {}, {}
h = TradePacksMinuteHistory.new(ctx)
assert(h:sample(series, now, 110))
local oldAt = now
now = now + 3 * 3600
assert(h:sample(series, now, 140))
assert(#jobs == 1 and drain())
assert(saved[keyAt(now, "Meta")].hour == math.floor(now / 3600))
assert(#h:rows(series, now) == 1 and h:rows(series, now)[1].ratio == 140)
now = oldAt -- A clock rollback must not erase a slot whose hour is newer.
assert(not h:sample(series, now, 105))
now = now + 3 * 3600

-- Different routes have separate storage; even a colliding key cannot overwrite an identity.
local route = copy(series); route.key = "TradePacksRates_22_5_test"; route.to = 5
assert(h:sample(route, now, 95) and drain())
assert(h:rows(route, now)[1].ratio == 95 and h:rows(series, now)[1].ratio == 140)
local collision = copy(series); collision.name = "Another pack"
assert(not pcall(function() h:sample(collision, now, 130) end))
local fresh = TradePacksMinuteHistory.new(ctx)
assert(not pcall(function() fresh:loadRecent(collision) end))
assert(#fresh:rows(collision, now) == 0)

-- Missing/invalid metadata and malformed minute keys remain protected.
local metaKey = keyAt(now, "Meta")
local originalMeta = copy(saved[metaKey])
saved[metaKey] = nil
assert(not pcall(function() TradePacksMinuteHistory.new(ctx):sample(series, now, 130) end))
saved[metaKey] = {bank = "C"}
assert(not pcall(function() TradePacksMinuteHistory.new(ctx):loadRecent(series) end))
saved[metaKey] = originalMeta
local dataKey = keyAt(now, originalMeta.bank)
saved[dataKey].minutes[60] = 130
assert(not pcall(function() TradePacksMinuteHistory.new(ctx):loadRecent(series) end))
saved[dataKey].minutes[60] = nil
saved[dataKey].minutes[0.5] = 130
assert(not pcall(function() TradePacksMinuteHistory.new(ctx):loadRecent(series) end))

print("TradePacks minute history checks passed")
