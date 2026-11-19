-- Lyrics: B站站内 ai-zh 字幕为主源, lrclib 为标题清洗后的增强兜底.
--
-- 宿主契约: 只返回 lines[] (逐行 {text,startMs}), 由宿主自己合成时间轴.
-- 不在 Lua 里拼 lrc 字符串: 250k 指令预算下, 拼 lrc 在 2400 行就 408.
-- 字符串在本运行时是 UTF-16 码元序列, 所以清洗用整段 gsub 去音符, 不做字节切片.
local http = require("bili.http")
local util = require("bili.util")
local store = require("bili.store")

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

-- view 数据 -> 主源 lines[]. 网络/JSON 异常一律 error: 宿主按"请求失败"
-- 处理, 不会把空结果落盘成 pureMusic. 确实无字幕返回 nil 让调用方转兜底.
local function subtitle_lines(bvid, view)
  local data = view.data
  local pages = util.list(data.pages)
  if #pages == 0 then return nil end
  local cid = util.text(pages[1].cid)

  -- 用 /x/player/wbi/v2 而不是 /x/player/v2: 实测同一 bvid 前者返回
  -- ai-zh,ai-en,ai-es,ai-ar,ai-pt 五路, 后者只回 ai-zh 一路.
  local ok, player = pcall(http.get, "/x/player/wbi/v2", { bvid = bvid, cid = cid })
  if not ok then error(player, 0) end
  local subs = {}
  if type(player.data) == "table" and type(player.data.subtitle) == "table" then
    subs = util.list(player.data.subtitle.subtitles)
  end
  if #subs == 0 then return nil end

  local pick = subs[1]
  for i = 1, #subs do
    if util.text(subs[i].lan) == "ai-zh" then pick = subs[i]; break end
  end
  local url = util.text(pick.subtitle_url)
  if string.sub(url, 1, 2) == "//" then url = "https:" .. url end
  if url == "" then return nil end

  -- CDN 字幕文档: 不带 Cookie (第三方 CDN, 登录态不外泄), 也不带 buvid.
  local ok2, raw = pcall(http.request, url, { cookie = "", skip_buvid = true, raw = true })
  if not ok2 then error(raw, 0) end
  local ok3, doc = pcall(host.json_decode, raw)
  if not ok3 or type(doc) ~= "table" then error("INVALID_SUBTITLE_JSON", 0) end
  local body = util.list(doc.body)
  if #body == 0 then return nil end

  local last = #body
  if last > SUB_LINE_CAP then last = SUB_LINE_CAP end
  local lines = {}
  for i = 1, last do
    local row = body[i]
    local text = clean(util.text(row.content))
    if string.len(text) > 0 then
      lines[#lines + 1] = {
        text = text,
        startMs = math.floor((tonumber(row["from"]) or 0) * 1000),
      }
    end
  end
  if #lines == 0 then return nil end
  return lines
end

-- 增强兜底: 清洗标题查 lrclib, 用时长偏差对齐视频; 最多一次请求, 不重试.
-- 返回 lrc 原文交给宿主解析; 这条路只在主源彻底无字幕时走到.
local function lrclib_entry(title, duration)
  local name = search_name(title)
  if name == "" then return nil end
  local ok, results = pcall(http.request, LRCLIB .. host.url_encode(name) .. "&limit=5", {})
  if not ok or type(results) ~= "table" or #results == 0 then return nil end

  local tol = duration * 0.02
  if tol < 5 then tol = 5 end
  for i = 1, #results do
    local item = results[i]
    if type(item) == "table" then
      local delta = (tonumber(item.duration) or 0) - duration
      if delta < 0 then delta = -delta end
      if delta <= tol then
        local lrc = util.text(item.syncedLyrics)
        if lrc == "" then lrc = util.text(item.plainLyrics) end
        if lrc ~= "" then
          return { synced = item.syncedLyrics ~= nil, lrc = lrc }
        end
      end
    end
  end
  return nil
end

-- bvid 由宿主以 MusicId 传入. view 只请求一次: 主源拿 cid/时长, 兜底拿标题.
function M.lyrics(bvid)
  bvid = util.text(bvid)
  if bvid == "" then return {} end

  local ok, view = pcall(http.get, "/x/web-interface/view", { bvid = bvid })
  if not ok then error(view, 0) end
  if type(view.data) ~= "table" then error("INVALID_VIEW", 0) end

  local lines = subtitle_lines(bvid, view)
  if lines ~= nil then return { { synced = true, lines = lines } } end

  local data = view.data
  local entry = lrclib_entry(util.text(data.title), util.number(data.duration, 0))
  if entry ~= nil then return { entry } end

  -- 到此都没歌词：区分"没登录"与"真没字幕"。
  -- 匿名态 /x/player/v2 返回 code=0 + 空 subtitles（实测 2/2），
  -- 宿主会把空结果落盘成 pureMusic，用户以为这歌真没歌词。
  -- 报 401 让宿主进错误态（viewport.dart:1153 显示 lyricsError），
  -- 而不是"这首歌暂未提供歌词"。
  if store.cookie() == "" then error("Gateway code -101", 0) end
  return {}
end

return M
