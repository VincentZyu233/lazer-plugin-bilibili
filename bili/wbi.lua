-- Bili WBI request signing, ported from BiliMusic's bilibili_creators.rs.
--
-- No `%` pattern classes and no capture groups: the salt filename is extracted
-- with plain find/sub byte scans. Verified live: saltLen=32, code=0 for both
-- CJK keywords and punctuation-laden queries.
local http = require("bili.http")
local errors = require("bili.errors")

local M = {}

local MIX = {
  46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,
  37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52,
}

-- The salt is derived from the two nav keys. It is stable for days, but not
-- forever: Bili rotates wbi_img, and a stale salt yields -403 on every signed
-- endpoint with no other symptom. 30 minutes bounds that without refreshing on
-- every request (frequent nav calls are themselves a risk-control signal).
local SALT_TTL_MS = 30 * 60 * 1000
local SALT_LENGTH = 32

local salt = nil
local salt_at = 0

-- wbi excludes `!'()*` from the encoded query, then percent-encodes the rest.
local function encode(value)
  local text = tostring(value)
  local out = {}
  local index = 1
  local length = string.len(text)
  while index <= length do
    local byte = string.byte(text, index)
    if byte ~= 33 and byte ~= 39 and byte ~= 40 and byte ~= 41 and byte ~= 42 then
      out[#out + 1] = string.sub(text, index, index)
    end
    index = index + 1
  end
  return host.url_encode(table.concat(out))
end

local function basename(url)
  local cut = string.find(url, "?", 1, true)
  if cut ~= nil then url = string.sub(url, 1, cut - 1) end
  local slash = 1
  local index = 1
  while index <= string.len(url) do
    if string.sub(url, index, index) == "/" then slash = index end
    index = index + 1
  end
  local name = string.sub(url, slash + 1)
  local dot = string.find(name, ".", 1, true)
  if dot ~= nil then name = string.sub(name, 1, dot - 1) end
  return name
end

local function fetch_salt()
  -- nav returns -101 when anonymous; that is normal and still carries wbi_img.
  local body = http.get("/x/web-interface/nav", nil, { allow = { 0, -101 } })
  local wbi = body.data and body.data.wbi_img
  if type(wbi) ~= "table" then errors.throw("transient") end
  local key = basename(wbi.img_url) .. basename(wbi.sub_url)
  if string.len(key) < 64 then errors.throw("transient") end
  local out = {}
  for index = 1, SALT_LENGTH do
    local at = MIX[index] + 1
    out[index] = string.sub(key, at, at)
  end
  local value = table.concat(out)
  if string.len(value) ~= SALT_LENGTH then errors.throw("transient") end
  return value
end

function M.get_salt()
  if salt ~= nil and host.now() - salt_at < SALT_TTL_MS then return salt end
  salt = fetch_salt()
  salt_at = host.now()
  return salt
end

function M.invalidate()
  salt = nil
  salt_at = 0
end

-- Returns the signed query string (without a leading '?').
-- `params` is a flat table of scalar values. Every WBI endpoint expects a `wts`
-- timestamp in the signed string; /x/space/wbi/arc/search rejects the request
-- with HTTP 412 when it is missing.
--
-- `wts` is SECONDS. host.now() is epoch milliseconds, so it must be divided:
-- sending milliseconds produced a wts ~1000x in the future, which Bili accepts
-- for a while and then rejects as a replay.
function M.sign(params)
  local keys = {}
  for key in pairs(params) do keys[#keys + 1] = key end
  if params.wts == nil then
    params.wts = tostring(math.floor(host.now() / 1000))
    keys[#keys + 1] = "wts"
  end
  table.sort(keys)
  local parts = {}
  for index = 1, #keys do
    local key = keys[index]
    local value = params[key]
    if value ~= nil then
      parts[#parts + 1] = encode(key) .. "=" .. encode(value)
    end
  end
  local query = table.concat(parts, "&")
  local w_rid = host.crypto({ operation = "md5", text = query .. M.get_salt() })
  return query .. "&w_rid=" .. w_rid
end

-- A signed GET. `path` is an API path, `params` a flat table.
--
-- Retry matrix (T6 §3.2), applied by kind rather than "anything failed":
--
--   transient            -> refresh salt, retry ONCE (network blip, bad JSON,
--                           or a failure inside the signature itself: the salt
--                           is the only part that can go stale)
--   forbidden            -> refresh salt, retry ONCE (-403 is the one stable
--                           symptom of a rotated wbi_img)
--   ratelimit / auth     -> pass through untouched. Retrying a throttle adds
--                           to the throttle, and auth has nothing to do with
--                           signing; the old blanket retry doubled every
--                           request during risk control (D4 / probe D1).
--   anything else        -> pass through.
local RETRYABLE = { transient = true, forbidden = true }

local function attempt(path, params, options)
  local query = M.sign(params)
  local url = (options.base or http.API) .. path .. "?" .. query
  return http.request(url, options)
end

function M.get(path, params, options)
  options = options or {}
  local ok, result = pcall(attempt, path, params, options)
  if ok then return result end
  if not RETRYABLE[errors.kind_from(result)] then error(result, 0) end
  M.invalidate()
  return attempt(path, params, options)
end

return M
