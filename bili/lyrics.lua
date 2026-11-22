-- Lyrics: B站站内字幕为主源, lrclib 为标题清洗后的增强兜底.
--
-- 宿主契约: 返回 [{ synced, lines[] }] 或 [{ synced, lrc }], 由宿主自己合成
-- 时间轴. 不在 Lua 里拼 lrc 字符串: 250k 指令预算下, 拼 lrc 在 2400 行就 408.
-- 字符串在本运行时是 UTF-16 码元序列, 所以清洗用整段 gsub 去音符, 不做字节切片.
--
-- Three states, and they are NOT interchangeable:
--   成功        -> lines[] 或 lrc
--   暂不可用    -> error("KIND transient") -> code 70, 宿主可重试
--   确认无内容  -> error("KIND transient") as well on this host, see below
--
-- The third state cannot be expressed as an empty table here: Lazer 2.0.210
-- persists an empty lyrics answer as a 121-byte `pureMusic:true` shell and then
-- stops asking the plugin for that track entirely (11 such shells are archived
-- in evidence/puremusic_backup/). "We could not find lyrics" would be frozen
-- into "this track has no lyrics" forever. Reporting 70 keeps it retryable and
-- the client shows a retryable error instead of a wrong claim.
local http = require("bili.http")
local util = require("bili.util")
local ids = require("bili.ids")
local errors = require("bili.errors")

local M = {}

local NOTE = "♪"               -- 必须是字面量: string.char(9834) 会让 VM 启动失败
local SUB_LINE_CAP = 1200       -- 3 次 gsub 清洗在 1200 行 612ms, 离 408 有 3 倍余量
local LRCLIB = "https://lrclib.net/api/search?q="

local function clean(t)
  local s = string.gsub(t, NOTE, "")
  s = string.gsub(s, "^ ", "")
  s = string.gsub(s, " $", "")
  return s
end

-- 找 needle 在 s 中恰好出现一次的位置; 出现 0 次或 >=2 次返回 nil.
local function exactly_once(s, needle)
  local first = string.find(s, needle, 1, true)
  if first == nil then return nil end
  local second = string.find(s, needle, first + string.len(needle), true)
  if second ~= nil then return nil end
  return first
end

-- 从营销标题里取曲名: 唯一书名号 > 唯一方头括号 > 整条标题.
local function search_name(title)
  local s = util.trim(title)
  local a = exactly_once(s, "《")
  local b = exactly_once(s, "》")
  if a ~= nil and b ~= nil and b > a then return util.trim(string.sub(s, a + 1, b - 1)) end
  a = exactly_once(s, "【")
  b = exactly_once(s, "】")
  if a ~= nil and b ~= nil and b > a then return util.trim(string.sub(s, a + 1, b - 1)) end
  return s
end

-- Language priority. Bili exposes human subtitles (lan like "zh-CN") and
-- machine ones ("ai-zh"). A human Chinese track beats an AI one, and an AI
-- Chinese track beats any other AI language.
local function rank_of(lan)
  local value = util.text(lan)
  if value == "" then return nil end
  if value == "ai-zh" then return 2 end
  if string.sub(value, 1, 3) == "ai-" then return 3 end
  if value == "zh-Hans" or value == "zh-CN" or value == "zh" or
     value == "zh-Hant" or value == "zh-TW" then
    return 1
  end
  return nil
end

local function pick_subtitle(subs)
  local best = nil
  local best_rank = nil
  -- Re-normalise the parameter: a function argument's type is not visible to
  -- the call site, and `#` on a string throws in this runtime.
  local items = util.list(subs)
  for index = 1, #items do
    local item = items[index]
    if type(item) == "table" then
      local rank = rank_of(item.lan)
      if rank ~= nil and (best_rank == nil or rank < best_rank) then
        best = item
        best_rank = rank
      end
    end
  end
  return best
end

local function subtitle_url_of(item)
  local url = util.trim(util.text(item.subtitle_url))
  if url == "" then return nil end
  if string.sub(url, 1, 2) == "//" then url = "https:" .. url end
  -- The subtitle document is fetched from a CDN without any cookie, so the
  -- protocol and host must be checked: an upstream field is not a reason to
  -- send a request to an arbitrary origin.
  if string.sub(url, 1, 6) ~= "https:" then return nil end
  local tail = string.sub(url, 9)
  local cut = string.find(tail, "/", 1, true)
  local host = cut ~= nil and string.sub(tail, 1, cut - 1) or tail
  local suffix = ".hdslb.com"
  local at = string.len(host) - string.len(suffix) + 1
  if at < 1 or string.sub(host, at) ~= suffix then return nil end
  return url
end

-- view 数据 -> 主源 lines[]. 网络/JSON 异常一律抛 transient: 宿主按"请求失败"
-- 处理, 不会把空结果落盘成 pureMusic. 确实无字幕返回 nil 让调用方转兜底.
local function subtitle_lines(bvid, cid, view)
  local data = view.data
  local part_cid = cid
  if part_cid == "" then
    local pages = util.list(data.pages)
    if #pages == 0 then return nil end
    part_cid = util.text(pages[1].cid)
  end

  -- 用 /x/player/wbi/v2 而不是 /x/player/v2: 实测同一 bvid 前者返回
  -- ai-zh,ai-en,ai-es,ai-ar,ai-pt 五路, 后者只回 ai-zh 一路.
  local ok, player = pcall(http.get, "/x/player/wbi/v2", { bvid = bvid, cid = part_cid })
  if not ok then error(player, 0) end
  -- Normalise at the boundary: `subtitles` is a remote field, so its type is
  -- only trusted after util.list has coerced it.
  local subtitle = type(player.data) == "table" and player.data.subtitle or nil
  local subs = util.list(type(subtitle) == "table" and subtitle.subtitles or nil)
  if #subs == 0 then return nil end

  local pick = pick_subtitle(subs)
  if pick == nil then return nil end
  local url = subtitle_url_of(pick)
  if url == nil then return nil end

  -- CDN 字幕文档: 不带 Cookie (第三方 CDN, 登录态不外泄), 也不带 buvid.
  local ok2, raw = pcall(http.request, url, { cookie = "", skip_buvid = true, raw = true })
  if not ok2 then error(raw, 0) end
  local ok3, doc = pcall(host.json_decode, raw)
  if not ok3 or type(doc) ~= "table" then errors.throw("transient") end
  local body = util.list(doc.body)
  if #body == 0 then return nil end

  local lines = {}
  local skipped = 0
  local last = #body
  local truncated = false
  if last > SUB_LINE_CAP then
    last = SUB_LINE_CAP
    truncated = true
  end
  for i = 1, last do
    local row = body[i]
    if type(row) == "table" then
      -- Cue validation: a line without a numeric start would land at 0 ms and
      -- stack every later line on top of it.
      local from = tonumber(row["from"])
      local to = tonumber(row["to"])
      local content = row.content
      if from == nil or to == nil or type(content) ~= "string" then
        skipped = skipped + 1
      else
        local text = clean(content)
        if string.len(text) > 0 then
          lines[#lines + 1] = { text = text, startMs = math.floor(from * 1000) }
        end
      end
    else
      skipped = skipped + 1
    end
  end
  if #lines == 0 then return nil end
  return lines, truncated, skipped
end

-- LRCLIB match scoring. The old code accepted the first result inside a
-- duration window, which happily returns a live version or a cover: the title
-- and the artist are the only fields that can tell them apart.
local function score_of(item, name, artist, duration)
  local score = 0
  local track = util.text(item.trackName)
  if string.len(track) > 0 and string.len(name) > 0 then
    if track == name then
      score = score + 6
    elseif string.find(string.lower(track), string.lower(name), 1, true) ~= nil then
      score = score + 3
    end
  end
  local by = util.text(item.artistName)
  if string.len(by) > 0 and string.len(artist) > 0 then
    if string.find(string.lower(by), string.lower(artist), 1, true) ~= nil then
      score = score + 4
    end
  end
  local album = util.text(item.albumName)
  if string.len(album) > 0 and string.len(artist) > 0 then
    if string.find(string.lower(album), string.lower(artist), 1, true) ~= nil then
      score = score + 1
    end
  end
  local seconds = tonumber(item.duration) or 0
  local delta = seconds - duration
  if delta < 0 then delta = -delta end
  local tol = duration * 0.02
  if tol < 5 then tol = 5 end
  if duration > 0 and delta > tol then return nil end
  if delta <= 2 then
    score = score + 5
  elseif delta <= 5 then
    score = score + 3
  else
    score = score + 1
  end
  return score
end

-- 增强兜底: 清洗标题查 lrclib, 用时长偏差对齐视频; 最多一次请求, 不重试.
-- 返回 lrc 原文交给宿主解析; 这条路只在主源彻底无字幕时走到.
local function lrclib_entry(title, artist, duration)
  local name = search_name(title)
  if name == "" then return nil end
  local ok, payload = pcall(http.request, LRCLIB .. host.url_encode(name) .. "&limit=5", {})
  if not ok then errors.throw("transient") end
  local results = util.list(payload)
  if #results == 0 then return nil end

  local best = nil
  local best_score = nil
  for i = 1, #results do
    local item = results[i]
    if type(item) == "table" and item.instrumental ~= true then
      local score = score_of(item, name, artist, duration)
      if score ~= nil and (best_score == nil or score > best_score) then
        best = item
        best_score = score
      end
    end
  end
  if best == nil then return nil end

  local synced = util.text(best.syncedLyrics)
  if synced ~= "" then return { synced = true, lrc = synced } end
  -- Plain text is NOT synced. The old code marked `syncedLyrics=""` as
  -- synced=true while returning plainLyrics, so the client drew a time axis
  -- over lines that have no timestamps.
  local plain = util.text(best.plainLyrics)
  if plain ~= "" then return { synced = false, lrc = plain } end
  return nil
end

-- bvid 或 bvid:cid 由宿主以 MusicId.value 传入.
function M.lyrics(id)
  local bvid, cid = ids.parse(id)

  local ok, view = pcall(http.get, "/x/web-interface/view", { bvid = bvid })
  if not ok then error(view, 0) end
  if type(view.data) ~= "table" then errors.throw("transient") end
  local data = view.data

  local lines = subtitle_lines(bvid, cid, view)
  if lines ~= nil then return { { synced = true, lines = lines } } end

  -- 兜底用"这一 P 的标题"而不是合集标题, 否则多 P 视频会拿第一 P 的歌名去搜.
  local title = util.text(data.title)
  if cid ~= "" then
    local pages = util.list(data.pages)
    for index = 1, #pages do
      if util.text(pages[index].cid) == cid then
        local part = util.text(pages[index].part)
        if part ~= "" then title = part end
        break
      end
    end
  end
  local owner = type(data.owner) == "table" and data.owner or {}
  local entry = lrclib_entry(title, util.text(owner.name), util.number(data.duration, 0))
  if entry ~= nil then return { entry } end

  -- Both sources answered and neither has lyrics. See the header: an empty
  -- answer is persisted as pureMusic on 2.0.210, so this is reported as a
  -- retryable failure rather than as "no lyrics".
  --
  -- Re-verified for T6 (evidence/t6/E12_puremusic_matrix.md): the two hosts
  -- disagree, so the conservative branch stays. 2.0.300 does not persist an
  -- empty answer at all (cached_lyrics_store.dart:87 returns early when the
  -- payload has neither timed lyrics nor pureMusic), but 2.0.210 does, and the
  -- shell it writes carries no `savedAt` field — so 2.0.300's 24 h TTL can
  -- never expire it, and the track is stuck on "instrumental" for good.
  -- minAppVersion is 2.0.210, so that is the behaviour that decides.
  errors.throw("transient")
end

return M
