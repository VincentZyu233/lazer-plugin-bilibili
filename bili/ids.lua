-- Track identity for multi-part videos.
--
-- The host passes only the opaque id string to `stream` and `lyrics`
-- (lua_music_gateway.dart:500-503 and :518-520), so `args.cid` is never
-- populated on those paths: identity has to be carried inside the id.
--
--   BV1xx411c7mD        -> whole video, first part (old behaviour, old cache key)
--   BV1xx411c7mD:1001   -> exactly that part
--
-- A plain bvid stays byte-identical to what earlier versions emitted, so the
-- host's cached lyrics and play state keep resolving.
local util = require("bili.util")
local errors = require("bili.errors")

local M = {}

local BVID_LENGTH = 12

local function valid_bvid(value)
  if string.len(value) ~= BVID_LENGTH then return false end
  if string.sub(value, 1, 2) ~= "BV" then return false end
  for index = 1, BVID_LENGTH do
    local byte = string.byte(value, index)
    local ok = (byte >= 48 and byte <= 57) or
               (byte >= 65 and byte <= 90) or
               (byte >= 97 and byte <= 122)
    if not ok then return false end
  end
  return true
end

local function valid_cid(value)
  if value == "" then return false end
  for index = 1, string.len(value) do
    local byte = string.byte(value, index)
    if byte < 48 or byte > 57 then return false end
  end
  return true
end

-- Returns bvid, cid (cid may be ""). Raises `param` on a malformed id instead of
-- sending a request that can only come back -400.
function M.parse(value)
  local text = util.trim(util.text(value))
  if text == "" then errors.throw("param") end
  local colon = string.find(text, ":", 1, true)
  local bvid, cid
  if colon == nil then
    bvid = text
    cid = ""
  else
    bvid = util.trim(string.sub(text, 1, colon - 1))
    cid = util.trim(string.sub(text, colon + 1))
  end
  if not valid_bvid(bvid) then errors.throw("param") end
  if colon ~= nil and not valid_cid(cid) then errors.throw("param") end
  return bvid, cid
end

function M.format(bvid, cid)
  local base = util.text(bvid)
  local part = util.text(cid)
  if part == "" then return base end
  return base .. ":" .. part
end

-- Identity for a song row: precise when the cid is already known, plain bvid
-- otherwise (search rows do not carry a cid, and fetching one per row would be
-- a view request per result).
function M.of(bvid, cid)
  local base = util.text(bvid)
  if base == "" then return "" end
  return M.format(base, cid)
end

return M
