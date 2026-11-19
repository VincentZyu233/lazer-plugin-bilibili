-- Pure helpers for the Bilibili provider.
--
-- The embedded Lua 5.3 subset has no `%d/%s/...` classes, no capture groups and
-- no `#string`. Everything here scans bytes with string.find(..., true) and
-- string.sub, and uses string.len.
local M = {}

function M.text(value)
  if value == nil then return "" end
  local kind = type(value)
  if kind == "string" then return value end
  if kind == "number" then
    if math.floor(value) == value then return tostring(math.floor(value)) end
    return tostring(value)
  end
  if kind == "boolean" then return value and "true" or "false" end
  return ""
end

function M.number(value, fallback)
  local result = fallback
  if result == nil then result = 0 end
  local kind = type(value)
  if kind == "number" then return math.floor(value) end
  if kind ~= "string" then return result end
  local parsed = tonumber(value)
  if parsed == nil then return result end
  return math.floor(parsed)
end

function M.list(value)
  if type(value) == "table" then return value end
  return {}
end

function M.field(value, ...)
  if type(value) ~= "table" then return nil end
  local count = select("#", ...)
  for index = 1, count do
    local key = select(index, ...)
    local item = value[key]
    if item ~= nil then return item end
  end
  return nil
end

function M.trim(value)
  local source = M.text(value)
  local first = 1
  local last = string.len(source)
  while first <= last and string.byte(source, first) <= 32 do first = first + 1 end
  while last >= first and string.byte(source, last) <= 32 do last = last - 1 end
  return string.sub(source, first, last)
end

-- `//i0.hdslb.com/x.jpg` and `http://...` -> `https://...`.
function M.https(value)
  if type(value) ~= "string" then return nil end
  local url = M.trim(value)
  if url == "" then return nil end
  if string.sub(url, 1, 2) == "//" then return "https:" .. url end
  if string.sub(url, 1, 7) == "http://" then return "https://" .. string.sub(url, 8) end
  return url
end

function M.image(value)
  return M.https(value)
end

-- Search titles embed `<em class="keyword">…</em>`. Strip everything between a
-- '<' and the next '>' with a plain-text scan; captures are unavailable.
function M.clean_title(value)
  local source = M.text(value)
  local out = {}
  local index = 1
  local length = string.len(source)
  local skip = false
  while index <= length do
    local ch = string.sub(source, index, index)
    if skip then
      if ch == ">" then skip = false end
    elseif ch == "<" then
      skip = true
    else
      out[#out + 1] = ch
    end
    index = index + 1
  end
  local cleaned = table.concat(out)
  -- Decode the common entities BiliMusic's clean_html handles.
  cleaned = M.replace(cleaned, "&amp;", "&")
  cleaned = M.replace(cleaned, "&lt;", "<")
  cleaned = M.replace(cleaned, "&gt;", ">")
  cleaned = M.replace(cleaned, "&quot;", "\"")
  cleaned = M.replace(cleaned, "&#39;", "'")
  return M.trim(cleaned)
end

-- Plain substring replacement (host gsub third arg cannot be a function).
function M.replace(source, needle, replacement)
  local text = M.text(source)
  if needle == "" then return text end
  local out = {}
  local at = 1
  while at <= string.len(text) do
    local found = string.find(text, needle, at, true)
    if found == nil then
      out[#out + 1] = string.sub(text, at)
      break
    end
    out[#out + 1] = string.sub(text, at, found - 1)
    out[#out + 1] = replacement
    at = found + string.len(needle)
  end
  return table.concat(out)
end

-- Search results carry "4:19"; view carries seconds (213).
function M.parse_duration(value)
  if type(value) == "number" then return math.floor(value * 1000) end
  if type(value) ~= "string" then return 0 end
  local colon = string.find(value, ":", 1, true)
  if colon == nil then return M.number(value, 0) * 1000 end
  local minutes = M.number(string.sub(value, 1, colon - 1), 0)
  local seconds = M.number(string.sub(value, colon + 1), 0)
  return (minutes * 60 + seconds) * 1000
end

function M.map_rows(values, mapper)
  local out = {}
  local source = M.list(values)
  for index = 1, #source do
    local mapped = mapper(source[index])
    if mapped ~= nil then out[#out + 1] = mapped end
  end
  return out
end

-- B site pages are 1-based; Lazer hands out 0-based offsets.
function M.page_of(limit, offset, max_page_size)
  local take = M.number(limit, 20)
  if take < 1 then take = 20 end
  local ceiling = max_page_size or take
  if take > ceiling then take = ceiling end
  local skip = M.number(offset, 0)
  if skip < 0 then skip = 0 end
  return take, math.floor(skip / take) + 1
end

function M.split_lines(value)
  local out = {}
  local source = M.text(value)
  local start = 1
  local length = string.len(source)
  for index = 1, length do
    local byte = string.byte(source, index)
    if byte == 10 or byte == 13 then
      local line = string.sub(source, start, index - 1)
      if line ~= "" then out[#out + 1] = line end
      start = index + 1
    end
  end
  if start <= length then
    local line = string.sub(source, start)
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

local function strip_header_name(line)
  local trimmed = M.trim(line)
  if string.lower(string.sub(trimmed, 1, 11)) == "set-cookie:" then
    return string.sub(trimmed, 12)
  end
  if string.lower(string.sub(trimmed, 1, 7)) == "cookie:" then
    return string.sub(trimmed, 8)
  end
  return trimmed
end

function M.cookie_header(value)
  local raw = M.text(value)
  if raw == "" then return "" end
  local lines = M.split_lines(raw)
  for index = 1, #lines do lines[index] = strip_header_name(lines[index]) end
  local compact = host.cookie_compact(table.concat(lines, "; "))
  if compact == nil then return "" end
  return compact
end

return M
