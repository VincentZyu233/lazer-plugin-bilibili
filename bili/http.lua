-- Thin host.http wrapper for api.bilibili.com.
--
-- Only this module touches the transport. It normalises UA/Referer/Cookie,
-- follows the one redirect form Bili uses, maps HTTP/B-site codes to the fixed
-- "HTTP <n>" / "Gateway code <n>" strings the dispatcher parses, and absorbs
-- Set-Cookie into store so a login response is not dropped.
local util = require("bili.util")
local store = require("bili.store")

local M = {}

local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ..
           "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

local API = "https://api.bilibili.com"
local PASSPORT = "https://passport.bilibili.com"
local WEB = "https://www.bilibili.com/"

M.UA = UA
M.API = API
M.PASSPORT = PASSPORT
M.WEB = WEB

local function header_of(headers)
  local out = {
    ["User-Agent"] = UA,
    ["Referer"] = WEB,
    Accept = "application/json",
  }
  if type(headers) == "table" then
    for key, value in pairs(headers) do out[key] = value end
  end
  return out
end

local function join(base, path)
  if string.sub(path, 1, 4) == "http" then return path end
  return base .. path
end

local function absorb_set_cookie(response, options)
  if type(response.headers) ~= "table" then return end
  local set_cookie = response.headers["set-cookie"] or response.headers["Set-Cookie"]
  if type(set_cookie) ~= "string" or set_cookie == "" then return end
  local base = options.qr and store.qr_cookie() or store.cookie()
  local merged = host.cookie_merge(base, set_cookie)
  if merged == nil or merged == "" then return end
  if options.qr then store.set_qr_cookie(merged) else store.set_cookie(merged) end
end

-- R2: Bili risk-control probabilities drop with a stable device id. The `spi`
-- endpoint returns b_3/b_4 as JSON without setting a cookie, so fold them into
-- a buvid3/buvid4 pair once and attach them to every request. Fetch is lazy so
-- startup stays offline, and a failure degrades silently.
local buvid = nil
local function ensure_buvid()
  if buvid ~= nil then return buvid end
  local ok, body = pcall(M.request, API .. "/x/frontend/finger/spi", { skip_buvid = true })
  buvid = ""
  if ok and type(body) == "table" and type(body.data) == "table" then
    local b3 = util.text(body.data.b_3)
    local b4 = util.text(body.data.b_4)
    local parts = {}
    if b3 ~= "" then parts[#parts + 1] = "buvid3=" .. b3 end
    if b4 ~= "" then parts[#parts + 1] = "buvid4=" .. b4 end
    buvid = table.concat(parts, "; ")
  end
  return buvid
end

-- Performs one raw request. Returns the decoded response object or throws.
function M.request(url, options)
  options = options or {}
  local headers = header_of(options.headers)
  local cookie = options.cookie
  if cookie == nil then
    cookie = options.qr and store.qr_cookie() or store.cookie()
  end
  if not options.skip_buvid then
    local device = ensure_buvid()
    if device ~= "" then
      cookie = cookie == "" and device or (cookie .. "; " .. device)
    end
  end
  if cookie ~= "" then headers.Cookie = cookie end

  local response = host.http({
    url = url,
    method = options.method or "GET",
    headers = headers,
    body = options.body,
  })
  if type(response) ~= "table" then error("INVALID_RESPONSE", 0) end

  -- b23.tv style 302: host.http does not follow by default.
  local status = math.floor(util.number(response.status, 0))
  if status >= 300 and status < 400 then
    local location = nil
    if type(response.headers) == "table" then
      location = response.headers.location or response.headers.Location
    end
    if type(location) == "string" and location ~= "" then
      if string.sub(location, 1, 4) ~= "http" then
        location = "https:" .. location
      end
      local next_options = {}
      for key, value in pairs(options) do next_options[key] = value end
      return M.request(location, next_options)
    end
  end

  absorb_set_cookie(response, options)
  if status < 200 or status >= 300 then error("HTTP " .. tostring(status), 0) end

  local body = response.body or ""
  if options.raw then return body end
  local ok, decoded = pcall(host.json_decode, body)
  if not ok or type(decoded) ~= "table" then error("INVALID_JSON", 0) end

  local allowed = options.allow
  if type(allowed) == "table" then
    local accepted = false
    for index = 1, #allowed do
      if tonumber(decoded.code) == allowed[index] then accepted = true end
    end
    if not accepted and tonumber(decoded.code) ~= 0 then
      error("Gateway code " .. tostring(decoded.code), 0)
    end
  elseif decoded.code ~= nil and tonumber(decoded.code) ~= 0 then
    error("Gateway code " .. tostring(decoded.code), 0)
  end
  return decoded
end

function M.get(path, params, options)
  options = options or {}
  local query = params or ""
  if type(params) == "table" then
    local parts = {}
    for key, value in pairs(params) do
      if value ~= nil then
        parts[#parts + 1] = host.url_encode(key) .. "=" .. host.url_encode(tostring(value))
      end
    end
    table.sort(parts)
    query = table.concat(parts, "&")
  end
  local url = join(options.base or API, path)
  if query ~= "" then url = url .. "?" .. query end
  return M.request(url, options)
end

function M.post(path, form, options)
  options = options or {}
  local parts = {}
  if type(form) == "table" then
    for key, value in pairs(form) do
      parts[#parts + 1] = host.url_encode(key) .. "=" .. host.url_encode(tostring(value))
    end
    table.sort(parts)
  end
  options.method = "POST"
  options.body = table.concat(parts, "&")
  options.headers = options.headers or {}
  options.headers["Content-Type"] = "application/x-www-form-urlencoded"
  return M.request(join(options.base or API, path), options)
end

return M
