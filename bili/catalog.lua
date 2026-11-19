-- Catalog operations: search, song, playlists/favorites, discovery, comments.
--
-- Pagination is 1-based on Bili and 0-based in Lazer: page = floor(offset/limit)+1.
-- WBI-signed endpoints (search, artistSongs) go through bili.wbi.
local http = require("bili.http")
local wbi = require("bili.wbi")
local util = require("bili.util")
local store = require("bili.store")
local models = require("bili.models")
local auth = require("bili.auth")
local stream = require("bili.stream")
local lyrics = require("bili.lyrics")

local M = {}

local function data_of(body)
  if type(body) ~= "table" or type(body.data) ~= "table" then return {} end
  return body.data
end

-- 宿主每页要 limit 行（platform_catalog.dart 传 100），而 B 站单页硬顶
-- 因接口而异（50 / 40 / 20）。宿主 lua_music_gateway.dart:200 用
-- `hasMore = list.length >= limit` 自算"还有没有下一页"，插件传不进去，
-- 所以必须在"返回多少行"上补齐。少给一行，宿主就判定末页。
--
-- 页内偏移必须算：宿主的 offset 是 0/100/200…，B 站 cap 是 50/40，
-- 直接 offset/cap 会在 offset 不是 cap 倍数时错位。
local function collect(load, limit, offset, cap, max_hops)
  local out = {}
  local skip = offset
  local hops = 0
  while #out < limit and hops < max_hops do
    hops = hops + 1
    local page_size = cap
    local pn = math.floor(skip / page_size) + 1
    local in_page = skip - (pn - 1) * page_size
    local rows = util.list(load(pn, page_size))
    if #rows == 0 then break end
    local index = in_page + 1
    while index <= #rows and #out < limit do
      out[#out + 1] = rows[index]
      index = index + 1
    end
    skip = skip + (#rows - in_page)
    -- 短页即末页：收藏夹 ps=20 会返 19（稿件已删），靠 #rows==0 会多拉一页。
    if #rows < page_size then break end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Search and detail
-- ---------------------------------------------------------------------------

function M.search(query, limit, offset)
  local keyword = util.text(query)
  if keyword == "" then return { songs = {}, albums = {}, artists = {}, playlists = {} } end
  local take, page = util.page_of(limit, offset, 50)

  -- songs: 视频
  local video = wbi.get("/x/web-interface/wbi/search/type", {
    search_type = "video", keyword = keyword, page = page, page_size = take,
  })
  local songs = util.map_rows(util.list(data_of(video).result), models.song)

  -- artists: UP 主
  local user = wbi.get("/x/web-interface/wbi/search/type", {
    search_type = "bili_user", keyword = keyword, page = page, page_size = take,
  })
  local artists = util.map_rows(util.list(data_of(user).result), models.artist_row)

  -- albums / playlists 有意留空：B 站没有"歌手专辑"，番剧搜索不稳定
  -- （同一关键词两次结果 11 与 0），空桶比假桶诚实。
  return { songs = songs, albums = {}, artists = artists, playlists = {} }
end

function M.song(id)
  local body = http.get("/x/web-interface/view", { bvid = util.text(id) })
  local data = data_of(body)
  local song = models.song(data)
  local pages = util.list(data.pages)
  song.extra = {
    cid = #pages > 0 and util.text(pages[1].cid) or "",
    parts = #pages,
    desc = util.text(data.desc),
  }
  return song
end

function M.stream(id, quality, cid)
  return stream.stream(id, quality, cid)
end

function M.lyrics(id)
  -- 宿主传进来的是 bvid. B站字幕主源直接用它走三步链路, 标题/时长在
  -- lyrics 模块内部由 view 接口顺带取, 这里不再把 id 换成标题.
  return lyrics.lyrics(id)
end

-- ---------------------------------------------------------------------------
-- Favorites / playlists
-- ---------------------------------------------------------------------------

local function current_mid()
  if store.mid == nil or store.mid <= 0 then auth.require_user() end
  return store.mid
end

local function folder_is_default(folder)
  local title = util.text(util.field(folder, "title", "name"))
  return string.find(title, "默认收藏夹", 1, true) ~= nil or
         util.number(util.field(folder, "media_id", "id"), 0) == 0
end

-- 收藏夹 list-all 不返回封面，用第一页第一个视频的 cover 回填。
-- 单条 ps=1 请求，失败/空夹返回 nil，models.playlist 会退回 folder 自带字段。
local function folder_cover(folder)
  local id = util.field(folder, "media_id", "id")
  if id == nil then return nil end
  local ok, body = pcall(http.get, "/x/v3/fav/resource/list", {
    media_id = util.text(id), pn = 1, ps = 1, order = "mtime", type = 0,
  })
  if not ok then return nil end
  local medias = util.list(data_of(body).medias)
  if #medias == 0 then return nil end
  return util.image(util.field(medias[1], "cover", "pic"))
end

function M.playlists(limit, offset)
  if store.cookie() == "" then return {} end
  local mid = current_mid()
  local take, page = util.page_of(limit, offset, 50)
  local body = http.get("/x/v3/fav/folder/created/list-all", { up_mid = mid, ps = take, pn = page })
  local data = data_of(body)
  local rows = util.list(data.list)
  return util.map_rows(rows, function(item)
    return models.playlist(item, folder_is_default(item), folder_cover(item))
  end)
end

function M.playlist_songs(id, limit, offset)
  local need = util.number(limit, 50)
  if need < 1 then need = 50 end
  if need > 150 then need = 150 end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end
  local rows = collect(function(pn, ps)
    local body = http.get("/x/v3/fav/resource/list", {
      media_id = util.text(id), pn = pn, ps = ps, order = "mtime", type = 0,
    })
    return util.list(data_of(body).medias)
  end, need, skip, 40, 6)
  return util.map_rows(rows, function(item)
    local song = models.song(item)
    song.id = util.text(util.field(item, "bvid", "bv_id"))
    song.albumId = song.id
    if song.id == "" then return nil end
    return song
  end)
end

function M.favorites(limit, offset)
  if store.cookie() == "" then return {} end
  local mid = current_mid()
  -- 找默认夹子的 ps=50 保持不动（那是"找哪个夹子"）。
  local body = http.get("/x/v3/fav/folder/created/list-all", { up_mid = mid, ps = 50, pn = 1 })
  local data = data_of(body)
  local rows = util.list(data.list)
  local default_id = nil
  for index = 1, #rows do
    if folder_is_default(rows[index]) then
      default_id = util.text(util.field(rows[index], "media_id", "id"))
      break
    end
  end
  if default_id == nil then return {} end
  local need = util.number(limit, 50)
  if need < 1 then need = 50 end
  if need > 150 then need = 150 end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end
  local videos = collect(function(pn, ps)
    local page_body = http.get("/x/v3/fav/resource/list", {
      media_id = default_id, pn = pn, ps = ps, order = "mtime", type = 0,
    })
    return util.list(data_of(page_body).medias)
  end, need, skip, 40, 6)
  return util.map_rows(videos, function(item)
    local song = models.song(item)
    song.id = util.text(util.field(item, "bvid", "bv_id"))
    song.albumId = song.id
    if song.id == "" then return nil end
    return song
  end)
end

function M.set_favorite(id, favorite)
  auth.require_user()
  local bvid = util.text(id)
  local view = http.get("/x/web-interface/view", { bvid = bvid })
  local aid = util.number(data_of(view).aid, 0)
  if aid <= 0 then error("Gateway code -400", 0) end
  local folders = http.get("/x/v3/fav/folder/created/list-all",
                           { up_mid = store.mid, ps = 50, pn = 1 })
  local rows = util.list(data_of(folders).list)
  local default_id = nil
  for index = 1, #rows do
    if folder_is_default(rows[index]) then
      default_id = util.text(util.field(rows[index], "media_id", "id"))
      break
    end
  end
  if default_id == nil then error("Gateway code -400", 0) end
  local field = favorite and "add_media_ids" or "del_media_ids"
  http.post("/x/v3/fav/resource/deal", {
    rid = aid,
    type = 2,
    [field] = default_id,
    csrf = store.csrf(),
  })
  return true
end

function M.artist_songs(id, limit, offset)
  local need = util.number(limit, 50)
  if need < 1 then need = 50 end
  if need > 150 then need = 150 end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end
  local rows = collect(function(pn, ps)
    local body = wbi.get("/x/space/wbi/arc/search", {
      mid = util.text(id), ps = ps, pn = pn, order = "pubdate",
    })
    return util.list((data_of(body).list or {}).vlist)
  end, need, skip, 50, 6)
  return util.map_rows(rows, models.song)
end

-- UP 主详情：宿主进「歌手」页先调 artist 拿名字/头像。B站 UP 不是歌手，
-- 用匿名可用的 /x/web-interface/card 即可，失败时回退到 id 占位，不抛错。
function M.artist(id, limit, offset)
  local mid = util.text(id)
  local ok, body = pcall(http.get, "/x/web-interface/card", { mid = mid })
  local card = {}
  if ok and type(body.data) == "table" and type(body.data.card) == "table" then
    card = body.data.card
  end
  return models.artist_detail(mid, card)
end

-- B站没有"歌手专辑"这一层，UP 投稿全部由 artistSongs 提供。返回空页让宿主
-- 的 artistAlbumPageFor 正常结束，避免 unsupported operation 冒泡成"资料加载失败"。
function M.artist_albums(id, limit, offset)
  return {}
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

function M.home_feed()
  local body = http.get("/x/web-interface/popular", { ps = 20, pn = 1 })
  local data = data_of(body)
  local songs = util.map_rows(util.list(data.list), models.song)
  return { featuredSongs = songs }
end

function M.charts()
  local body = http.get("/x/web-interface/ranking/v2", { rid = 0, type = "all" })
  local data = data_of(body)
  local songs = util.map_rows(util.list(data.list), models.song)
  return {
    { id = "rank:all", name = "全站排行", songCount = #songs, songs = songs },
  }
end

function M.recommendations(limit, seed)
  local take = util.number(limit, 30)
  if take < 1 then take = 30 end
  if take > 100 then take = 100 end
  local id = util.text(seed)
  if id == "" then
    local popular = http.get("/x/web-interface/popular", { ps = 1, pn = 1 })
    local rows = util.list(data_of(popular).list)
    if #rows == 0 then return {} end
    id = util.text(rows[1].bvid)
  end
  local body = http.get("/x/web-interface/archive/related", { bvid = id })
  local rows = util.list(data_of(body))
  local out = {}
  for index = 1, #rows do
    if #out >= take then break end
    local song = models.song(rows[index])
    out[#out + 1] = song
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Comments
-- ---------------------------------------------------------------------------

function M.comments(id, limit, offset)
  local take, page = util.page_of(limit, offset, 20)
  local view = http.get("/x/web-interface/view", { bvid = util.text(id) })
  local aid = util.number(data_of(view).aid, 0)
  if aid <= 0 then error("Gateway code -400", 0) end
  local body = http.get("/x/v2/reply", {
    type = 1, oid = aid, pn = page, ps = take, sort = 2,
  })
  local data = data_of(body)
  local replies = util.map_rows(util.list(data.replies), models.comment)
  local page_info = type(data.page) == "table" and data.page or {}
  local count = util.number(page_info.count, 0)
  return {
    latest = replies,
    hot = {},
    total = count,
    hasMore = util.number(page_info.num, page) * util.number(page_info.size, take) < count,
  }
end

return M
