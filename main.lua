-- 哔哩哔哩 provider for Lazer's isolated Lua plugin runtime (v2.0.210).
--
-- Layout:
--   main.lua           operation table, error mapping, media rules
--   bili/util.lua      pure text/table helpers (no pattern classes, no string length operator)
--   bili/store.lua     persisted cookie + in-memory session and QR state
--   bili/http.lua      host.http wrapper: UA/Referer, cookies, code mapping
--   bili/wbi.lua       WBI salt cache and request signing
--   bili/models.lua    response -> client model mapping
--   bili/auth.lua      session, QR / Cookie login, logout
--   bili/catalog.lua   search, detail, playlists, discovery, comments
--   bili/stream.lua    playurl -> audio choice + Referer headers
--   bili/lyrics.lua    B站 ai-zh 字幕主源 -> lines[], lrclib 增强兜底
--
-- Only the 14 host APIs present in v2.0.210 are used.
local auth = require("bili.auth")
local catalog = require("bili.catalog")

local CAPABILITIES = {
  "search", "playlists", "favorites", "lyrics",
  "homeFeed", "charts", "recommendations", "comments",
}

local MEDIA = {
  { host = "*.hdslb.com", fallbackHosts = { "i0.hdslb.com", "i1.hdslb.com", "i2.hdslb.com" } },
}

local function describe()
  return {
    media = MEDIA,
    providers = {
      {
        id = "bilibili",
        name = "哔哩哔哩",
        auth = { "qr", "cookie" },
        loginHint = "用哔哩哔哩 App 扫码，或粘贴网页版 Cookie",
        cookieHint = "粘贴含 SESSDATA 与 bili_jct 的完整 Cookie",
        capabilities = CAPABILITIES,
      },
    },
  }
end

local operations = {
  describe = describe,
  session = function() return auth.session() end,
  loginCookie = function(args) return auth.login_cookie(args.cookie) end,
  qrKey = function() return auth.qr_key() end,
  qrUrl = function(args) return auth.qr_url(args.key) end,
  qrCheck = function(args) return auth.qr_check(args.key) end,
  logout = function() return auth.logout() end,

  search = function(args) return catalog.search(args.query, args.limit, args.offset) end,
  song = function(args) return catalog.song(args.id) end,
  stream = function(args) return catalog.stream(args.id, args.quality, args.cid) end,
  lyrics = function(args) return catalog.lyrics(args.id) end,

  playlists = function(args) return catalog.playlists(args.limit, args.offset) end,
  playlistSongs = function(args) return catalog.playlist_songs(args.id, args.limit, args.offset) end,
  favorites = function(args) return catalog.favorites(args.limit, args.offset) end,
  setFavorite = function(args) return catalog.set_favorite(args.id, args.favorite) end,
  artist = function(args) return catalog.artist(args.id) end,
  artistSongs = function(args) return catalog.artist_songs(args.id, args.limit, args.offset) end,
  artistAlbums = function(args) return catalog.artist_albums(args.id, args.limit, args.offset) end,

  homeFeed = function() return catalog.home_feed() end,
  charts = function() return catalog.charts() end,
  recommendations = function(args) return catalog.recommendations(args.limit, args.seed) end,
  comments = function(args) return catalog.comments(args.id, args.limit, args.offset) end,
}

local function dispatch(operation, args)
  local handler = operations[operation]
  if handler == nil then error("unsupported operation: " .. tostring(operation), 0) end
  if type(args) ~= "table" then args = {} end
  return handler(args)
end

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

-- The host only ever receives a status pair: no upstream body, signed URL or
-- cookie text. B-site auth codes map to Lazer's 40/401 prompt.
local function failure(message)
  local reason = tostring(message)
  local code = number_after(reason, "Gateway code ")
  local status = number_after(reason, "HTTP ")
  if code == -101 or code == -400 or code == 401 or code == 301 or code == 302 then
    code = 40
    status = 401
  elseif code == -352 then
    -- -352 是"风控校验失败"，匿名访问 UP 投稿的主因（实测 3/3）。
    -- 归到 429 会让宿主显示"操作过于频繁"，用户永远想不到要登录。
    code = 40
    status = 401
  elseif code == -412 or status == 412 then
    -- -412 是真频率封禁，保留限流语义。
    status = 429
  end
  return { error = { code = code, httpStatus = status, reason = "Request failed" } }
end

return {
  call = function(operation, args)
    local ok, value = pcall(dispatch, operation, args)
    if ok then return value end
    return failure(value)
  end,
}
