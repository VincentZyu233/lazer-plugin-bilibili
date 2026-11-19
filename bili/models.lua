-- B-site response -> Lazer model mapping. One normaliser per entity keeps every
-- operation consistent.
local util = require("bili.util")

local M = {}

function M.artist(mid, name)
  return { id = util.text(mid), name = util.clean_title(name) }
end

-- 搜索结果里的 UP 主行。字段名与 bili_user 对齐；albumCount 必须是 0，
-- 否则 artist_page 会渲染出一个空的"专辑"区。
function M.artist_row(row)
  if type(row) ~= "table" then row = {} end
  return {
    id = util.text(row.mid),
    name = util.clean_title(row.uname),
    coverUrl = util.image(row.upic),
    description = util.text(row.usign),
    albumCount = 0,
  }
end

-- UP 主详情（宿主的 artist op）。B站没有"歌手专辑"概念，UP 投稿走 artistSongs，
-- 这里只回填名字/头像，albumCount 保持 0，避免歌手页渲染出不存在的专辑条目。
function M.artist_detail(mid, card)
  card = type(card) == "table" and card or {}
  local name = util.clean_title(util.field(card, "name", "uname"))
  if name == "" then name = "B站用户" end
  return {
    id = util.text(mid),
    name = name,
    coverUrl = util.image(util.field(card, "face")),
    description = util.text(util.field(card, "sign")),
    albumCount = 0,
  }
end

-- Every song-returning op uses this shape (task book §4.5).
function M.song(item, overrides)
  if type(item) ~= "table" then item = {} end
  overrides = overrides or {}
  local bvid = util.text(util.field(item, "bvid", "bvid"))
  if bvid == "" then bvid = util.text(overrides.bvid) end
  local mid = util.field(item, "mid")
  if mid == nil then
    local owner = item.owner
    if type(owner) == "table" then mid = owner.mid end
  end
  local author = util.field(item, "author")
  if author == nil then
    local owner = item.owner
    if type(owner) == "table" then author = owner.name end
  end
  local cover = util.image(util.field(item, "pic", "cover"))
  if cover == nil then cover = util.image(overrides.cover) end
  -- 各接口时长字段不统一：search/view 用 duration，UP 投稿 vlist 用
  -- length（"MM:SS"），部分接口给 duration_seconds（秒）。统一按字符串/秒
  -- 交给 parse_duration，避免把秒再乘一次 1000。
  local duration = util.field(item, "duration", "length")
  if duration == nil then duration = util.field(item, "duration_seconds") end
  local duration_ms = util.parse_duration(duration)
  if duration_ms == 0 then duration_ms = util.number(overrides.durationMs, 0) end
  return {
    id = bvid,
    title = util.clean_title(util.field(item, "title")),
    artists = { M.artist(mid, author) },
    albumId = bvid,
    albumName = "B站视频",
    coverUrl = cover,
    durationMs = duration_ms,
    contentType = "video/mp4",
  }
end

-- B站收藏夹 list-all 不返回封面；封面由 catalog 用第一个视频的 cover 回填。
-- 传入 cover_override 时优先用它，否则退回 folder 自带的 cover/pic。
function M.playlist(folder, is_favorites, cover_override)
  if type(folder) ~= "table" then folder = {} end
  local id = util.field(folder, "media_id", "id")
  local cover = util.image(cover_override)
  if cover == nil then cover = util.image(util.field(folder, "cover", "pic")) end
  return {
    id = tostring(util.number(id, 0)),
    name = util.text(util.field(folder, "title", "name")),
    coverUrl = cover,
    songCount = util.number(util.field(folder, "media_count", "songCount"), 0),
    isFavorites = is_favorites == true,
  }
end

function M.comment(item)
  if type(item) ~= "table" then item = {} end
  local member = type(item.member) == "table" and item.member or {}
  -- /x/v2/reply 的 content 是对象，正文在 content.message；部分接口和旧
  -- fixture 直接给字符串。util.text(table) 只会得到空串，所以先按类型取。
  local content = item.content
  local message
  if type(content) == "table" then
    message = util.text(content.message)
  else
    message = util.text(content)
  end
  if message == "" then message = util.text(item.message) end
  return {
    id = util.text(util.field(item, "rpid", "id")),
    content = message,
    author = util.text(member.uname),
    authorId = tostring(util.number(member.mid, 0)),
    avatarUrl = util.image(member.avatar),
    time = util.number(item.ctime, 0),
    liked = item.liked == true,
    likedCount = util.number(item.like, 0),
    replies = {},
  }
end

return M
