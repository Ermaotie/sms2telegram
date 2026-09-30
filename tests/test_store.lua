local root = assert(arg[1], "source root required")
local t = dofile("tests/testlib.lua")
local store_module = dofile(root .. "/usr/lib/sms2telegram/store.lua")

local function mode(path)
  local pipe = assert(io.popen("stat -f '%Lp' '" .. path .. "' 2>/dev/null || stat -c '%a' '" .. path .. "'"))
  local value = pipe:read("*l")
  pipe:close()
  return value
end

local function encode(record)
  return table.concat({ record.number, record.timestamp, record.text,
    tostring(record.stored_at) }, "\t")
end

local function decode(line)
  local number, timestamp, text, stored_at = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([0-9]+)$")
  if not number then return nil end
  return { number = number, timestamp = timestamp, text = text,
    stored_at = tonumber(stored_at) }
end

local pipe = assert(io.popen("echo $$"))
local pid = assert(pipe:read("*l"))
pipe:close()
local path = "/tmp/sms2telegram-store-" .. pid .. ".jsonl"
local cycle_path = path .. ".cycle"
os.remove(path); os.remove(path .. ".tmp")
os.remove(cycle_path); os.remove(cycle_path .. ".tmp")

local now = 2000000000
local store = assert(store_module.new({
  path = path,
  cycle_path = cycle_path,
  encode = encode,
  decode = decode,
  now = function() return now end
}))
t.eq("retention defaults to off", store:cycle(), nil)
t.eq("first SMS persists", store:append({
  number = "10086", text = "旧套餐提醒", timestamp = "2033-05-18 03:33:20"
}), true)
t.eq("store file is private", mode(path), "600")

now = now + 31 * 86400
t.eq("second SMS persists", store:append({
  number = "13800138000", text = "验证码 2468", timestamp = "2033-06-18 03:33:20"
}), true)
local all = assert(store:records())
t.eq("cycle off keeps all SMS", #all, 2)
t.eq("keyword filters message text", #assert(store:records("验证码")), 1)
t.eq("keyword filters sender", #assert(store:records("10086")), 1)

t.eq("30 day retention is accepted", store:set_cycle("30"), true)
t.eq("expired SMS is pruned immediately", #assert(store:records()), 1)
t.eq("cycle value survives reload", assert(store_module.new({
  path = path, cycle_path = cycle_path, encode = encode,
  decode = decode, now = function() return now end
})):cycle(), 30)
t.eq("invalid retention is rejected", store:set_cycle("0"), nil)
t.eq("cycle off is accepted", store:set_cycle("off"), true)
t.eq("cycle is disabled", store:cycle(), nil)
t.eq("clear reports deleted SMS", store:clear(), 1)
t.eq("clear empties the store", #assert(store:records()), 0)

os.remove(path); os.remove(path .. ".tmp")
os.remove(cycle_path); os.remove(cycle_path .. ".tmp")
t.finish()
