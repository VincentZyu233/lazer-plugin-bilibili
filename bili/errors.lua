-- Error classification for the Bilibili provider.
--
-- Internal code throws a structured four-tuple as a plain string
-- (`KIND <kind>`, `Gateway code <n>`, `HTTP <n>`); main.lua maps it once into the
-- host's `{error={code, httpStatus}}` shape. Keeping the throw protocol textual
-- means http.lua's existing call sites do not change.
--
-- Host parsing rules this table is built against
-- (lua_music_gateway.dart:98-112, music_gateway.dart:235-236,
--  catalog.dart:1130-1131):
--   * `{error={code=N, httpStatus=M}}` becomes a MusicGatewayException.
--   * When httpStatus is absent, `400 <= code <= 599` IS the httpStatus. So a
--     transient error must carry code 70 and NO httpStatus, or 70 would be read
--     as a status.
--   * authenticationFailure is `code in {40,41,44} || httpStatus == 401`.
--   * rate limiting is `httpStatus == 429`.
local M = {}

-- kind -> { code, httpStatus }
local TABLE = {
  auth        = { code = 40,  status = 401 },
  param       = { code = nil, status = 400 },
  forbidden   = { code = nil, status = 403 },
  notfound    = { code = nil, status = 404 },
  ratelimit   = { code = nil, status = 429 },
  -- 70 is a transient application code, deliberately not in 400..599 so the
  -- host does not mistake it for an HTTP status.
  transient   = { code = 70,  status = nil },
  unsupported = { code = 501, status = nil },
}

-- Upstream B-site / HTTP codes -> kind. Order matters: the first match wins.
--
-- Positive HTTP statuses sit in the same table as the negative B-site codes so
-- that http.lua can throw one uniform `HTTP <n>` string and let this table
-- classify it. Before T01 a plain 403 became `transient(70)`, which the client
-- renders as "retry" for a permission problem that retrying cannot fix.
local RULES = {
  { kind = "auth",      codes = { -101, -2, 301, 302, 401 } },
  { kind = "ratelimit", codes = { -412, -509, 412, 429 } },
  -- -352 is anonymous risk control, not an expired login. Reporting 401 made
  -- the client print "check your username and password" for a problem that
  -- signing in actually fixes, but 401 also stops the host from retrying, so it
  -- is reported as transient (code 70) and the caller may retry once.
  { kind = "transient", codes = { -352, -799 } },
  { kind = "forbidden", codes = { -403, -10403, 403 } },
  { kind = "notfound",  codes = { -404, 62002, 62004, 404 } },
  { kind = "param",     codes = { -400, -40400, 400 } },
}

function M.throw(kind)
  error("KIND " .. tostring(kind), 0)
end

function M.kind_of_code(code)
  if code == nil then return nil end
  local value = tonumber(code)
  if value == nil then return nil end
  for index = 1, #RULES do
    local rule = RULES[index]
    for at = 1, #rule.codes do
      if rule.codes[at] == value then return rule.kind end
    end
  end
  return nil
end

-- Maps a thrown message to the host's status pair. `kind` may arrive either as
-- `KIND <kind>` or as an upstream numeric code.
function M.describe(kind)
  local entry = TABLE[kind]
  if entry == nil then entry = TABLE.transient end
  return entry.code, entry.status
end

function M.is_known(kind)
  return TABLE[kind] ~= nil
end

-- Reads the number that follows `marker` in a thrown message. Shared by
-- main.lua's failure() and by M.kind_from below so the parsing lives once.
local function number_after(message, marker)
  local start = string.find(message, marker, 1, true)
  if start == nil then return nil end
  local index = start + string.len(marker)
  local negative = false
  if string.sub(message, index, index) == "-" then negative = true; index = index + 1 end
  local digits = index
  while index <= string.len(message) do
    local byte = string.byte(message, index)
    if byte == nil or byte < 48 or byte > 57 then break end
    index = index + 1
  end
  if index == digits then return nil end
  local value = tonumber(string.sub(message, digits, index - 1))
  if value == nil then return nil end
  if negative then value = -value end
  return value
end

-- Kind of a thrown message, or nil when the message carries no classification.
--
-- This is public because the retry matrix lives in wbi.lua: it must decide
-- "refresh the salt and try once more" vs "pass the failure straight through"
-- from the SAME classification main.lua uses, not from a string prefix guess.
-- A duplicated copy would drift the first time a code is reclassified.
function M.kind_from(message)
  local reason = tostring(message)
  local at = string.find(reason, "KIND ", 1, true)
  if at ~= nil then
    local start = at + 5
    local finish = start
    while finish <= string.len(reason) do
      local byte = string.byte(reason, finish)
      if byte == nil or byte <= 32 then break end
      finish = finish + 1
    end
    local name = string.sub(reason, start, finish - 1)
    if TABLE[name] ~= nil then return name end
    return nil
  end
  local code = number_after(reason, "Gateway code ")
  if code == nil then code = number_after(reason, "HTTP ") end
  return M.kind_of_code(code)
end

return M
