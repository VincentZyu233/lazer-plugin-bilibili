-- Audio stream resolution via /x/player/playurl.
--
-- The client passes only the id, so the part identity must already be inside it
-- (`BV1xx:cid`, see bili/ids.lua); `args.cid` exists for compatibility but the
-- host never fills it on the stream path.
--
-- Every stream answer carries Referer+UA: a bare request is 403 (measured).
local http = require("bili.http")
local util = require("bili.util")
local ids = require("bili.ids")
local errors = require("bili.errors")
local store = require("bili.store")

local M = {}

-- Host quality names (platform_catalog.dart:358-363): lossless/exhigh/higher/
-- standard map to original/high/medium/low. Ids are Bili's audio quality codes.
local QUALITY_ID = {
  low = 30216,
  medium = 30232,
  high = 30280,
  original = 30251,
  hires = 30251,
  flac = 30251,
}

-- playurl answers are short-lived by design: the DASH `deadline` is the
-- authoritative expiry, and BiliMusic caps the cache at 180 s
-- (bilibili.rs:714-739). Caching them turns "play, seek, switch back" into one
-- request instead of three, and stays inside the deadline.
local CACHE_TTL_MS = 180 * 1000
local CACHE_LIMIT = 16
local cache = {}
local cache_order = {}

local function cache_get(key)
  local entry = cache[key]
  if entry == nil then return nil end
  if host.now() - entry.at >= entry.ttl then
    cache[key] = nil
    return nil
  end
  return entry.value
end

local function cache_put(key, value, ttl)
  if cache[key] == nil then
    cache_order[#cache_order + 1] = key
    while #cache_order > CACHE_LIMIT do
      local oldest = table.remove(cache_order, 1)
      cache[oldest] = nil
    end
  end
  cache[key] = { value = value, at = host.now(), ttl = ttl }
end

-- Login change invalidates the resolved URLs: they are issued to a session.
store.on_reset(function()
  cache = {}
  cache_order = {}
end)

local function cid_of(bvid, supplied)
  if supplied ~= nil and util.text(supplied) ~= "" then return util.text(supplied) end
  local body = http.get("/x/web-interface/view", { bvid = bvid })
  local data = type(body.data) == "table" and body.data or {}
  local pages = util.list(data.pages)
  if #pages == 0 then errors.throw("notfound") end
  return util.text(pages[1].cid)
end

local function codec_ok(item)
  local codecs = util.text(item.codecs)
  if codecs == "" then return true end
  -- Audio only: an AAC or FLAC track. A video codec here would hand the player
  -- a stream it cannot decode as audio.
  if string.sub(codecs, 1, 4) == "mp4a" then return true end
  if string.sub(codecs, 1, 4) == "flac" then return true end
  return false
end

local function distance(a, b)
  local delta = a - b
  if delta < 0 then delta = -delta end
  return delta
end

-- Picks the audio track. When the requested tier is missing the closest
-- available AAC is returned instead of raising: the host has its own
-- fallbackChain (platform_catalog.dart:333) that retries every lower tier, so
-- raising costs up to four extra playurl requests for the same answer.
local function select_audio(dash, quality)
  local target = util.text(quality)
  if target == "" then target = "original" end
  local audios = util.list(dash.audio)
  local candidates = {}
  for index = 1, #audios do
    local item = audios[index]
    if type(item) == "table" and codec_ok(item) and util.text(util.field(item, "baseUrl", "base_url")) ~= "" then
      candidates[#candidates + 1] = item
    end
  end

  local flac = nil
  if type(dash.flac) == "table" and type(dash.flac.audio) == "table" then
    local item = dash.flac.audio
    if util.text(util.field(item, "baseUrl", "base_url")) ~= "" then flac = item end
  end

  if (target == "original" or target == "hires" or target == "flac") and flac ~= nil then
    return flac, true
  end

  if #candidates == 0 then
    if flac ~= nil then return flac, true end
    errors.throw("forbidden")
  end

  local wanted = QUALITY_ID[target]
  if wanted ~= nil then
    for index = 1, #candidates do
      if util.number(candidates[index].id, 0) == wanted then return candidates[index], false end
    end
  end

  -- Nothing at the requested tier: take the closest bandwidth, then the highest.
  local best = candidates[1]
  local best_score = nil
  for index = 1, #candidates do
    local item = candidates[index]
    local bandwidth = util.number(item.bandwidth, 0)
    local score
    if wanted ~= nil then
      score = distance(util.number(item.id, 0), wanted) * 1000000 + (0 - bandwidth)
    else
      score = 0 - bandwidth
    end
    if best_score == nil or score < best_score then
      best = item
      best_score = score
    end
  end
  return best, false
end

local function is_preview(data)
  -- Measured both shapes on the live service: `true` and `1`.
  local flag = data.is_preview
  if flag == true then return true end
  if type(flag) == "number" and flag ~= 0 then return true end
  if type(flag) == "string" and flag ~= "" and flag ~= "0" and flag ~= "false" then return true end
  return false
end

local function ttl_of(data)
  local ttl = CACHE_TTL_MS
  local dash = type(data.dash) == "table" and data.dash or {}
  local deadline = util.number(dash.deadline, 0)
  if deadline > 0 then
    local now = math.floor(host.now() / 1000)
    local left = (deadline - now - 30) * 1000
    if left < ttl then ttl = left end
  end
  if ttl < 1000 then ttl = 1000 end
  return ttl
end

function M.stream(id, quality, cid)
  local bvid, parsed_cid = ids.parse(id)
  local resolved_cid = parsed_cid
  if resolved_cid == "" then resolved_cid = cid_of(bvid, cid) end

  local key = bvid .. ":" .. resolved_cid
  local cached = cache_get(key)
  local data
  if cached ~= nil then
    data = cached
  else
    local body = http.get("/x/player/playurl", {
      bvid = bvid,
      cid = resolved_cid,
      qn = 120,
      fnval = 4048,
      fnver = 0,
      fourk = 1,
      voice_balance = 1,
    })
    data = type(body.data) == "table" and body.data or {}
    cache_put(key, data, ttl_of(data))
  end

  if is_preview(data) then errors.throw("forbidden") end

  local dash = type(data.dash) == "table" and data.dash or {}
  local has_dash_audio = #util.list(dash.audio) > 0 or
                          (type(dash.flac) == "table" and type(dash.flac.audio) == "table")
  local has_durl = #util.list(data.durl) > 0
  if not has_dash_audio and not has_durl then errors.throw("forbidden") end

  local best, is_flac = select_audio(dash, quality)
  local url = util.text(util.field(best, "baseUrl", "base_url"))
  if url == "" then errors.throw("forbidden") end
  local bandwidth = util.number(best.bandwidth, 0)

  return {
    url = util.https(url),
    -- The host MIME table only accepts audio/mp4 and audio/flac
    -- (remote_source.dart:475-491); anything else is treated as unplayable.
    contentType = is_flac and "audio/flac" or "audio/mp4",
    suffix = is_flac and "flac" or "m4a",
    -- Must be the real bandwidth: the host derives the actual tier from it
    -- (AudioQualityInfo.fromBitrate, thresholds 900k/256k/160k) and caches the
    -- track under that tier.
    bitRate = bandwidth,
    headers = { ["Referer"] = "https://www.bilibili.com/", ["User-Agent"] = http.UA },
  }
end

return M
