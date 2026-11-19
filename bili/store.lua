-- Persisted session state for the Bilibili provider.
--
-- Only the Cookie header is written to plugin storage; the verified account and
-- QR candidate are rebuilt at most once per VM. Caches register here so a login
-- or logout starts from a clean slate.
local M = {}

local COOKIE_KEY = "session_cookie"
local cookie = host.storage_get(COOKIE_KEY)
if type(cookie) ~= "string" then cookie = "" end
local qr_cookie = ""
local qr_url = ""
local resets = {}

M.user = nil
M.mid = 0

function M.cookie() return cookie end

function M.set_cookie(value)
  local next_value = type(value) == "string" and value or ""
  if next_value == cookie then return end
  cookie = next_value
  if next_value == "" then
    host.storage_set(COOKIE_KEY, nil)
  else
    host.storage_set(COOKIE_KEY, next_value)
  end
end

function M.qr_cookie() return qr_cookie end
function M.set_qr_cookie(value) qr_cookie = type(value) == "string" and value or "" end
function M.qr_url() return qr_url end
function M.set_qr_url(value) qr_url = type(value) == "string" and value or "" end

function M.field(name)
  if cookie == "" then return nil end
  local value = host.cookie_field(cookie, name)
  if value == nil or value == "" then return nil end
  return value
end

function M.csrf()
  return M.field("bili_jct") or M.field("csrf") or ""
end

function M.on_reset(callback) resets[#resets + 1] = callback end

function M.reset()
  M.user = nil
  M.mid = 0
  qr_url = ""
  for index = 1, #resets do pcall(resets[index]) end
end

return M
