-- Thin host.http wrapper for api.bilibili.com.
--
-- Only this module touches the transport. It normalises UA/Referer/Cookie,
-- follows Bili's redirect forms with a hard hop limit, maps HTTP/B-site codes to
-- the fixed "HTTP <n>" / "Gateway code <n>" / "KIND <kind>" strings the
-- dispatcher parses, and absorbs Set-Cookie into store so a login response is
-- not dropped.
local util = require("bili.util")
local store = require("bili.store")
local errors = require("bili.errors")

local M = {}

local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ..
           "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

local API = "https://api.bilibili.com"
local PASSPORT = "https://passport.bilibili.com"
local WEB = "https://www.bilibili.com/"

-- Bili's short links (b23.tv) chain at most twice; three hops is already more
-- than the service produces, and a fixed ceiling is what stops a redirect loop
-- from becoming an infinite recursion that exhausts the instruction budget.
local MAX_REDIRECTS = 3

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

-- Host part of a URL, used to decide whether a redirect leaves the site.
local function host_of(url)
  local scheme = string.find(url, "://", 1, true)
  if scheme == nil then return "" end
  local start = scheme + 3
  local finish = string.len(url)
  local slash = string.find(url, "/", start, true)
  if slash ~= nil and slash < finish then finish = slash - 1 end
  return string.lower(string.sub(url, start, finish))
end

-- Absorbs a response's Set-Cookie into the store.
--
-- `base` is the cookie the request ACTUALLY carried, not `store.cookie()`.
-- Those differ the moment a request runs with an explicit cookie (a QR probe,
-- a redirect that already dropped the session): merging into the stored value
-- then resurrects a cookie the request never sent.
--
-- `options.offsite` is set once a redirect has left the origin and stays set
-- for the rest of that chain. A response from another host is not authorised
-- to rewrite the session, whether it answers 30x or 200.
local function absorb_set_cookie(response, options, base)
  if options.offsite then return end
  if type(response.headers) ~= "table" then return end
  local set_cookie = response.headers["set-cookie"] or response.headers["Set-Cookie"]
  if type(set_cookie) ~= "string" or set_cookie == "" then return end
  local merged = host.cookie_merge(base, set_cookie)
  if merged == nil or merged == "" then return end
  if options.qr then store.set_qr_cookie(merged) else store.set_cookie(merged) end
end

-- R2: Bili risk-control probabilities drop with a stable device id. The `spi`
-- endpoint returns b_3/b_4 as JSON without setting a cookie, so fold them into
-- a buvid3/buvid4 pair once and attach them to every request.
--
-- Persisted: a VM rebuild (which happens on every 408 and on every plugin
-- reload) used to mint a brand-new device id, which is exactly the signal the
-- risk control looks for. The value is device state, not a credential.
local BUV_KEY = "device_buvid"

local function ensure_buvid()
  local cached = store.device()
  if cached ~= nil then return cached end
  local ok, body = pcall(M.request, API .. "/x/frontend/finger/spi", { skip_buvid = true })
  local value = ""
  if ok and type(body) == "table" and type(body.data) == "table" then
    local b3 = util.text(body.data.b_3)
    local b4 = util.text(body.data.b_4)
    local parts = {}
    if b3 ~= "" then parts[#parts + 1] = "buvid3=" .. b3 end
    if b4 ~= "" then parts[#parts + 1] = "buvid4=" .. b4 end
    value = table.concat(parts, "; ")
  end
  -- A failed spi is cached as "no device id" only for this VM: retrying it on
  -- every request would double the request count for nothing.
  store.set_device(value)
  return value
end

-- Performs one raw request. Returns the decoded response object or throws.
--
-- There is no retry flag here. The only retry in the plugin lives in
-- `wbi.lua`, which re-signs and repeats a call once on `transient`/`forbidden`
-- (wbi.lua:119-126) and only signs read endpoints. Write paths go through
-- `post` straight to `perform`, so a failed write is never replayed — Bili's
-- write endpoints are not idempotent and a replay could add the same item twice.
local function perform(url, options, depth)
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
  if type(response) ~= "table" then errors.throw("transient") end

  local status = math.floor(util.number(response.status, 0))
  if status >= 300 and status < 400 then
    if depth >= MAX_REDIRECTS then errors.throw("transient") end
    local location = nil
    if type(response.headers) == "table" then
      location = response.headers.location or response.headers.Location
    end
    if type(location) ~= "string" or location == "" then errors.throw("transient") end
    local target
    if string.sub(location, 1, 4) == "http" then
      target = location
    elseif string.sub(location, 1, 2) == "//" then
      target = "https:" .. location
    elseif string.sub(location, 1, 1) == "/" then
      -- A relative Location is relative to the ORIGIN, not to the request URL.
      local scheme = string.find(url, "://", 1, true)
      local origin = scheme ~= nil and string.sub(url, 1, scheme + 2) .. host_of(url) or API
      target = origin .. location
    else
      local cut = string.find(url, "/", 8, true)
      target = (cut ~= nil and string.sub(url, 1, cut) or (url .. "/")) .. location
    end
    local next_options = {}
    for key, value in pairs(options) do next_options[key] = value end
    -- Trust boundary (T6 §3.1), decided HERE because only perform knows what
    -- this request actually carried:
    --
    --   same-host 30x -> absorb Set-Cookie, merging into the cookie we sent
    --   cross-host 30x -> absorb nothing, and stop absorbing for the rest of
    --                     the chain; the session cookie is dropped too
    --
    -- Deciding inside absorb_set_cookie cannot work: it would have to infer
    -- "did we leave the origin" from the store, which is exactly the state a
    -- redirect must not be allowed to write.
    if host_of(target) ~= host_of(url) then
      next_options.cookie = ""
      next_options.skip_buvid = true
      next_options.offsite = true
    else
      absorb_set_cookie(response, options, cookie)
    end
    return perform(target, next_options, depth + 1)
  end

  absorb_set_cookie(response, options, cookie)
  if status < 200 or status >= 300 then
    if status == 412 or status == 429 then errors.throw("ratelimit") end
    error("HTTP " .. tostring(status), 0)
  end

  local body = response.body or ""
  if options.raw then return body end
  local ok, decoded = pcall(host.json_decode, body)
  if not ok or type(decoded) ~= "table" then errors.throw("transient") end

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

function M.request(url, options)
  options = options or {}
  return perform(url, options, 0)
end

local function query_of(params)
  local parts = {}
  for key, value in pairs(params) do
    if value ~= nil then
      parts[#parts + 1] = host.url_encode(key) .. "=" .. host.url_encode(tostring(value))
    end
  end
  table.sort(parts)
  return table.concat(parts, "&")
end

function M.get(path, params, options)
  options = options or {}
  local query = params or ""
  if type(params) == "table" then query = query_of(params) end
  local url = join(options.base or API, path)
  if query ~= "" then url = url .. "?" .. query end
  return perform(url, options, 0)
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
  return perform(join(options.base or API, path), options, 0)
end

return M
