-- Bili login: QR generate/poll, Cookie login, session and logout.
--
-- R1 RESOLVED (2026-11-18, real phone scan): a successful qrcode/poll (data.code
-- == 0) DOES return the full login cookie set in Set-Cookie (SESSDATA, bili_jct,
-- DedeUserID, sid). http.absorb_set_cookie folds it into store.qr_cookie(), and
-- qr_check promotes it to the persisted session and returns 803. QR login is a
-- real first-class path now. The empty-cookie -> 800 branch below is kept only
-- as a defensive guard, not as the expected flow.
local http = require("bili.http")
local store = require("bili.store")
local util = require("bili.util")

local M = {}

local function profile_of(body)
  if type(body) ~= "table" then return nil end
  local data = type(body.data) == "table" and body.data or {}
  if data.isLogin == false or data.is_login == false then return nil end
  local mid = util.field(data, "mid", "uid")
  if mid == nil then return nil end
  local numeric = util.number(mid, 0)
  if numeric <= 0 then return nil end
  local name = util.text(util.field(data, "uname", "name", "nickname"))
  if name == "" then name = "B站用户" end
  local user = {
    id = tostring(numeric),
    name = name,
    avatarUrl = util.image(data.face),
    level = util.number(util.field(data.level_info, "current_level"), 0),
    vip = util.number(data.vipStatus, 0) == 1 or data.vip_status == 1,
  }
  return user, numeric
end

function M.session()
  if store.cookie() == "" then
    store.user = nil
    store.mid = 0
    return nil
  end
  local ok, body = pcall(http.get, "/x/web-interface/nav")
  if not ok then
    -- A transport failure is not a sign-out: keep the last known account.
    error(body, 0)
  end
  local user, mid = profile_of(body)
  store.user = user
  store.mid = mid or 0
  return user
end

function M.require_user()
  if store.user == nil then M.session() end
  if store.user == nil then error("Gateway code 301", 0) end
  return store.user
end

function M.login_cookie(value)
  local candidate = util.cookie_header(value)
  if candidate == "" then return nil end
  local previous_cookie = store.cookie()
  local previous_user = store.user
  local previous_mid = store.mid
  store.set_cookie(candidate)
  store.user = nil
  local ok, user = pcall(M.session)
  if not ok or user == nil then
    store.set_cookie(previous_cookie)
    store.user = previous_user
    store.mid = previous_mid
    return nil
  end
  store.reset()
  return user
end

function M.qr_key()
  store.set_qr_cookie("")
  store.set_qr_url("")
  local body = http.get("/x/passport-login/web/qrcode/generate", nil, { base = http.PASSPORT, qr = true })
  local data = type(body.data) == "table" and body.data or {}
  local key = util.text(data.qrcode_key)
  if key == "" then error("Gateway code -400", 0) end
  -- The generate endpoint also returns the URL the app scans; the gateway asks
  -- qrKey for the key and qrUrl for the URL, so keep both from one request.
  store.set_qr_url(util.text(data.url))
  return key
end

function M.qr_url(key)
  local value = util.text(key)
  if value == "" then return "" end
  -- B站 App 扫一扫校验 scan-web URL 的 from 参数。qrcode/generate 接口回传的
  -- data.url 是 "...&from="（值为空），手机端会判「不支持的二维码」；官方 web
  -- 登录页在渲染二维码前把 from 补成 main_web。这里用 key 直接重建同款规范
  -- URL：既补上 from=main_web，又不依赖宿主 VM 重启后可能丢失的内存态 qr_url。
  local url = "https://account.bilibili.com/h5/account-h5/auth/scan-web?navhide=1&callback=close&qrcode_key=" ..
              host.url_encode(value) .. "&from=main_web"
  -- Return the BARE URL, not a table. Lazer 2.0.210 bridges a returned Lua table
  -- to a non-Map Dart object, so qrDetails() falls through to raw.toString() and
  -- QrImageView encodes "{hint: ..., url: ...}" -> "unsupported QR" on the phone.
  -- A plain string survives as the bare URL in BOTH 2.0.210 and 2.0.300 runtimes.
  return url
end

-- Returns the Lazer status code: 800 expired / 801 waiting / 802 confirmed /
-- 803 signed in. Bili codes: 86038 expired / 86101 waiting / 86090 confirmed /
-- 0 success.
function M.qr_check(key)
  local value = util.text(key)
  if value == "" then return 801 end
  local body = http.get("/x/passport-login/web/qrcode/poll",
                        { qrcode_key = value },
                        { base = http.PASSPORT, qr = true, allow = { 0, 86038, 86090, 86101 } })
  local data = type(body.data) == "table" and body.data or {}
  local code = util.number(data.code, 86101)
  if code == 86038 then
    store.set_qr_cookie("")
    return 800
  elseif code == 86101 then return 801
  elseif code == 86090 then return 802
  end
  -- code == 0: a cookie must have been captured during the poll response.
  local qr = store.qr_cookie()
  if qr == "" or host.cookie_field(qr, "SESSDATA") == nil then
    -- R1 fallback: no SESSDATA came back with the scan.
    store.set_qr_cookie("")
    return 800
  end
  store.set_cookie(qr)
  store.set_qr_cookie("")
  store.reset()
  local ok = pcall(M.session)
  if not ok then return 800 end
  return 803
end

function M.logout()
  pcall(http.post, "/x/web-interface/nav", {}, {})
  store.set_cookie("")
  store.set_qr_cookie("")
  store.reset()
  return true
end

return M
