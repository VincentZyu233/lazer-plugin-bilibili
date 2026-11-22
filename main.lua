-- 哔哩哔哩 provider for Lazer's isolated Lua plugin runtime (v2.0.210).
--
-- Layout:
--   main.lua           operation table, error mapping, media rules
--   bili/util.lua      pure text/table helpers (no pattern classes, no string length operator)
--   bili/errors.lua    kind -> host status mapping
--   bili/store.lua     persisted cookie + in-memory session, QR state, cache resets
--   bili/http.lua      host.http wrapper: UA/Referer, cookies, redirects, code mapping
--   bili/wbi.lua       WBI salt cache (TTL) and request signing
--   bili/pager.lua     remote paging + local slicing
--   bili/models.lua    response -> client model mapping
--   bili/auth.lua      session, QR / Cookie login, logout
--   bili/catalog.lua   search, detail, playlists, discovery, comments
--   bili/stream.lua    playurl -> audio choice + Referer headers
--   bili/lyrics.lua    B站 ai-zh 字幕主源 -> lines[], lrclib 增强兜底
--
-- Only the 14 host APIs present in v2.0.210 are used.
local auth = require("bili.auth")
local catalog = require("bili.catalog")
local errors = require("bili.errors")

local CAPABILITIES = {
  "search", "playlists", "favorites", "lyrics",
  "homeFeed", "charts", "recommendations", "comments",
  "album", "albumSongs",
  -- Declared only because `albums` is implemented below. platform_catalog.dart
  -- calls gateway.albums() inside a Future.wait when this is set, so a
  -- declaration without the op empties the entire home page.
  "browseAlbums",
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
  album = function(args) return catalog.album(args.id) end,
  albumSongs = function(args) return catalog.album_songs(args.id, args.limit, args.offset) end,
  stream = function(args) return catalog.stream(args.id, args.quality, args.cid) end,
  lyrics = function(args) return catalog.lyrics(args.id) end,

  playlists = function(args) return catalog.playlists(args.limit, args.offset) end,
  playlistSongs = function(args) return catalog.playlist_songs(args.id, args.limit, args.offset) end,
  favorites = function(args) return catalog.favorites(args.limit, args.offset) end,
  setFavorite = function(args) return catalog.set_favorite(args.id, args.favorite) end,
  -- Playlist writes. removeFromPlaylist is deliberately absent: the host sends
  -- POSITIONS (lua_music_gateway.dart:468-474) while fav/resource/deal wants
  -- aids, and the position only matches our paging cursor by coincidence —
  -- mapping them wrongly deletes the wrong track. The 501 is the honest answer.
  addToPlaylist = function(args) return catalog.add_to_playlist(args.playlist, args.songs) end,
  createPlaylist = function(args) return catalog.create_playlist(args.name, args.isPublic) end,
  artist = function(args) return catalog.artist(args.id) end,
  artistSongs = function(args) return catalog.artist_songs(args.id, args.limit, args.offset) end,
  artistAlbums = function(args) return catalog.artist_albums(args.id, args.limit, args.offset) end,

  homeFeed = function() return catalog.home_feed() end,
  albums = function(args) return catalog.albums(args.limit, args.offset) end,
  charts = function() return catalog.charts() end,
  recommendations = function(args) return catalog.recommendations(args.limit, args.seed) end,
  comments = function(args) return catalog.comments(args.id, args.limit, args.offset) end,
}

local function dispatch(operation, args)
  local handler = operations[operation]
  if handler == nil then
    -- A bare `unsupported operation` used to be normalised into an uncoded
    -- error, which the client showed as a generic failure. 501 says exactly
    -- what happened and is not in the authentication-failure set.
    errors.throw("unsupported")
  end
  if type(args) ~= "table" then args = {} end
  return handler(args)
end

-- The host only ever receives a status pair: no upstream body, signed URL or
-- cookie text. Classification lives in bili/errors so the table has one home.
-- wbi.lua calls errors.kind_from directly for the same reason: two copies of
-- this parse would drift the first time a code is reclassified.
local function failure(message)
  local kind = errors.kind_from(message)
  if kind == nil then
    -- Network failure, invalid JSON, a subtitle CDN timeout: all retryable.
    kind = "transient"
  end
  local code, status = errors.describe(kind)
  return { error = { code = code, httpStatus = status, reason = "Request failed" } }
end

return {
  call = function(operation, args)
    local ok, value = pcall(dispatch, operation, args)
    if ok then return value end
    return failure(value)
  end,
}
