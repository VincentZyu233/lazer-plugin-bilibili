-- Audio stream resolution via /x/player/playurl.
--
-- The client passes only the bvid, so resolve the first page's cid through view
-- when the caller did not supply one. Every stream answer carries Referer+UA;
-- a bare request is 403 (measured).
local http = require("bili.http")
local util = require("bili.util")

local M = {}

local function cid_of(id, supplied)
  if supplied ~= nil and util.text(supplied) ~= "" then return util.text(supplied) end
  local body = http.get("/x/web-interface/view", { bvid = util.text(id) })
  local data = type(body.data) == "table" and body.data or {}
  local pages = util.list(data.pages)
  if #pages == 0 then error("Gateway code -400", 0) end
  return util.text(pages[1].cid)
end

local function select_audio(dash, quality)
  local chosen = nil
  local target = util.text(quality)
  -- hires / original: the FLAC stream when the service exposes one.
  if (target == "original" or target == "hires" or target == "flac") and
     type(dash.flac) == "table" and type(dash.flac.audio) == "table" then
    chosen = dash.flac.audio
  end
  if chosen == nil then
    local audios = util.list(dash.audio)
    for index = 1, #audios do
      local item = audios[index]
      if type(item) == "table" then
        local id = util.number(item.id, 0)
        local wanted = false
        if target == "low" then wanted = id == 30216
        elseif target == "medium" then wanted = id == 30232
        elseif target == "high" then wanted = id == 30280
        else wanted = true end
        if wanted and (chosen == nil or util.number(item.bandwidth, 0) > util.number(chosen.bandwidth, 0)) then
          chosen = item
        end
      end
    end
  end
  if chosen == nil then error("Gateway code -400", 0) end
  return chosen
end

function M.stream(id, quality, cid)
  local bvid = util.text(id)
  local resolved_cid = cid_of(bvid, cid)
  local body = http.get("/x/player/playurl", {
    bvid = bvid,
    cid = resolved_cid,
    qn = 120,
    fnval = 4048,
    fnver = 0,
    fourk = 1,
    voice_balance = 1,
  })
  local data = type(body.data) == "table" and body.data or {}
  local dash = type(data.dash) == "table" and data.dash or {}
  local best = select_audio(dash, quality)
  local url = util.text(util.field(best, "baseUrl", "base_url"))
  if url == "" then error("Gateway code -400", 0) end
  return {
    url = util.https(url),
    contentType = "audio/mp4",
    suffix = "m4s",
    bitRate = util.number(best.bandwidth, 0),
    headers = { ["Referer"] = "https://www.bilibili.com/", ["User-Agent"] = http.UA },
  }
end

return M
