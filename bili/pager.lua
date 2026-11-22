-- Unified pagination for the Bilibili provider.
--
-- Two families, different semantics:
--
--   A) Remote paging (search / artistSongs / playlistSongs / favorites /
--      comments). The remote has pn/ps, but a page can be SHORTER than ps
--      because deleted or restricted rows are filtered server-side. Measured
--      live 2026-11-21: /x/v3/fav/resource/list?ps=20 returned 19 rows with
--      has_more=true. So neither `floor(offset/cap)+1` (guessing the page from
--      the offset) nor `#rows < ps -> last page` is usable. The only stable
--      anchor is the observed length of every page already fetched.
--
--   B) Whole-list paging (/x/v3/fav/folder/created/list-all). Measured live:
--      pn=1/2/3 and ps=5 all return the same 6 rows, so the endpoint ignores
--      paging entirely and must be sliced locally.
--
-- No pattern classes, no `#string`: every length goes through util.list/string.len.
local util = require("bili.util")

local M = {}

-- key -> { pages = { pn -> rows }, complete = bool, count = int, total = int|nil,
--          proven = int }
--
-- `total` is ONLY ever what the endpoint reported on a page that had rows.
-- `proven` is the number of rows this cursor has actually read (non-empty pages
-- only; a seek that skipped pages proves nothing about them). The two are kept
-- apart because collapsing them is what made an 88-song folder open empty:
-- /x/v3/fav/resource/list answers pn past the end with `medias: []` AND
-- `info.media_count: 0` (measured live, evidence/t8/R1_out_of_range.log), so the
-- out-of-range probe overwrote the real 88 with 0 and every later call on the
-- same key returned at `skip >= known` without sending one request.
local cursors = {}
local order = {}
local MAX_CURSORS = 24
-- Floor, not ceiling. `walk` raises the per-call page ceiling above this value
-- when the requested offset needs more pages (see page_ceiling), so a deep
-- window is reached instead of silently truncated at page 64.
local MIN_PAGES = 64
-- Ceiling on requests per invocation, PER FAMILY. Signing and plain requests
-- are not the same cost.
--
-- Both numbers below are deliberately conservative multipliers over a MEASURED
-- RANGE, not copies of a single measurement: the host's ceiling moves with the
-- payload (a longer row costs more instructions), so quoting one figure is how
-- the previous comment ended up citing a log that did not contain it.
--
--   plaintext (reply / fav_resource / popular / ranking / view / player):
--     the host kills the call somewhere between 153 and 232 requests depending
--     on row size (evidence/t8/R5_host_ceiling_offline.log — four offsets, each
--     reporting `callsThisRound` at the moment of the 408). 32 leaves a 4x
--     margin, which is what keeps a pathological cursor from exhausting the
--     host instead of returning.
--   signed (wbi: search / space/arc): the same file measures 22, 42, 62 and 75
--     requests before 408 as the payload grows, and every signed call may also
--     refresh the salt while `nav` shares the window. 12 keeps a margin under
--     the smallest observed value.
--
-- A single 32 for both was the T7/D4 defect: artistSongs(offset=800) needed 17
-- signed pages and killed the VM instead of answering.
--
-- Walking from page 1 is still not a strategy for deep offsets — one page per
-- request means page 66 is a 408, not a slow answer. `seek` below is what makes
-- deep offsets reachable where the family allows it. This budget is the backstop
-- that keeps a pathological cursor from exhausting the host instead of returning.
local PLAINTEXT_BUDGET = 32
local SIGNED_BUDGET = 12
-- Kept as the default so an existing caller that passes no budget keeps the
-- plaintext ceiling.
local REQUEST_BUDGET = PLAINTEXT_BUDGET
-- A jump shorter than this many pages is cheaper to walk than to seek: the
-- pages are probably already cached, and a seek would skip them.
local SEEK_MIN_PAGES = 3

local function drop_oldest()
  while #order > MAX_CURSORS do
    local oldest = table.remove(order, 1)
    cursors[oldest] = nil
  end
end

local function cursor_for(key)
  local cursor = cursors[key]
  if cursor == nil then
    cursor = { pages = {}, complete = false, count = 0, total = nil, proven = 0 }
    cursors[key] = cursor
    order[#order + 1] = key
    drop_oldest()
  end
  return cursor
end

-- Login change, logout, favorite write and folder-list change must drop every
-- cursor, otherwise paging keeps serving rows the user already removed.
function M.reset(key)
  if key == nil then
    cursors = {}
    order = {}
    return
  end
  cursors[key] = nil
  for index = #order, 1, -1 do
    if order[index] == key then table.remove(order, index) end
  end
end

local function ceil_div(a, b)
  if b < 1 then return 0 end
  local q = math.floor(a / b)
  if q * b < a then q = q + 1 end
  return q
end

-- Signature of one row's leading scalar fields. Rows are re-decoded on every
-- request, so identity comparison cannot detect a repeated page; comparing a
-- stable scalar signature can.
local function signature(row)
  if type(row) ~= "table" then return "" end
  local keys = {}
  for key, value in pairs(row) do
    local kind = type(value)
    if kind == "string" or kind == "number" then keys[#keys + 1] = tostring(key) end
  end
  table.sort(keys)
  local parts = {}
  for index = 1, #keys do
    if index > 8 then break end
    parts[#parts + 1] = keys[index] .. "=" .. util.text(row[keys[index]])
  end
  return table.concat(parts, "&")
end

-- Hops needed to reach `offset` and fill `limit` at remote page size `cap`.
-- A fixed ceiling truncates deep offsets: at offset=600/limit=100/cap=50 the
-- first eleven pages must be walked just to locate the window.
function M.hops(offset, limit, cap)
  local span = ceil_div(util.number(offset, 0), cap) + ceil_div(util.number(limit, 20), cap) + 1
  if span < 2 then span = 2 end
  return span
end

-- Page ceiling for one call. MAX_PAGES used to be a constant 64 while hops()
-- grew with the offset, so comments(offset=1300, cap=20) needed 67 pages and
-- hit the ceiling first: `walk` returned an empty list and the client read
-- that as "no more comments". MIN_PAGES still bounds a normal shallow call.
local function page_ceiling(hops)
  local value = util.number(hops, 0) + 2
  if value < MIN_PAGES then return MIN_PAGES end
  return value
end

-- A family. `load(pn)` returns the remote page rows and, optionally, the total
-- row count the endpoint reports. Returns rows, hops, truncated.
--
-- `opts.cap` is the remote page size and `opts.strict_seek` says the endpoint
-- really slices by position: every page is exactly `cap` rows, adjacent pages
-- never overlap. Only /x/v2/reply qualifies (measured live 2026-11-21:
-- pn=1/2/3/4/5/10/20/33/66 all returned exactly 20 rows with zero duplicate
-- rpids across pages, evidence/t6/probe_reply_pages.txt). A folder page is NOT
-- strict — ps=40 returned 38 rows and ps=20 returned 19 — so seeking there
-- would land on the wrong row.
--
-- `opts.budget` is the per-family request ceiling (see PLAINTEXT_BUDGET /
-- SIGNED_BUDGET). Omitting it keeps the plaintext ceiling, so a caller that
-- forgets to name its family degrades to the permissive value instead of
-- silently capping every search at 12 pages.
function M.walk(key, load, limit, offset, max_hops, total, opts)
  local out = {}
  local cursor = cursor_for(key)
  local want = util.number(limit, 20)
  if want < 1 then want = 20 end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end
  if total ~= nil then cursor.total = util.opt_number(total) end

  -- Two independent stop conditions (task book §3.2):
  --   * `total` is an upstream statement about the whole list — trusted only
  --     because it is now written from non-empty pages alone;
  --   * `proven` is how many rows this cursor has actually read. Reaching it
  --     with no upstream total means "keep asking": the end was never observed,
  --     so an offset at the boundary must still cost a request. The old single
  --     `cursor.count` conflated the two and turned one out-of-range probe into
  --     a permanent empty answer for the key.
  if cursor.total ~= nil and skip >= cursor.total then return out, 0, false end
  if cursor.complete and skip >= cursor.proven then return out, 0, false end

  local cap = util.number((opts or {}).cap, 0)
  local strict = (opts or {}).strict_seek == true
  local budget = util.number((opts or {}).budget, REQUEST_BUDGET)
  if budget < 1 then budget = REQUEST_BUDGET end

  local hops = 0
  local truncated = false
  local pn = 1
  local consumed = 0

  -- Seeking. Walking to page N costs N requests, and every family is bounded by
  -- PLAINTEXT_BUDGET / SIGNED_BUDGET requests per invocation — so a deep offset
  -- reached page by page runs out of budget before it reaches its window (the
  -- pre-T7 code died exactly that way on comments(offset=1300) and
  -- comments(offset=3000); evidence/t6/G0_old_code_red.log).
  -- With a strict family the page that holds `skip` is known outright: page N
  -- covers rows (N-1)*cap+1 .. N*cap, so it can be requested directly and the
  -- skipped pages never cost a request. The starting page is the LOWEST page
  -- that can hold the target row, so nothing before the window is lost.
  if strict and cap > 0 and skip > 0 then
    local target = math.floor(skip / cap) + 1
    if target > SEEK_MIN_PAGES and cursor.pages[target] == nil then
      pn = target
      consumed = (target - 1) * cap
    end
  end

  local ceiling = page_ceiling(max_hops)

  while #out < want do
    local located = false
    while true do
      local rows = cursor.pages[pn]
      local page_total = nil
      if rows == nil then
        if hops >= max_hops or hops >= budget or pn > ceiling then
          truncated = true
          break
        end
        local loaded, reported = load(pn)
        rows = util.list(loaded)
        page_total = reported
        cursor.pages[pn] = rows
        hops = hops + 1
      end
      local n = #rows
      if n == 0 then
        -- An empty page proves the END, not the SIZE. /x/v3/fav/resource/list
        -- answers pn past the last row with `medias: []` and `info.media_count: 0`
        -- (evidence/t8/R1_out_of_range.log), so any total this page reports is
        -- discarded — it carries no information about how many rows exist, and
        -- writing it back made a 88-song folder answer "empty" forever.
        cursor.complete = true
        cursor.count = consumed
        break
      end
      -- A total is only accepted from a page that had rows. The last non-empty
      -- page is the last one that can say anything true about the size.
      --
      -- And only when it is a POSITIVE number: a page carrying rows while
      -- reporting `count: 0` is contradictory, and writing that 0 makes
      -- `skip >= cursor.total` true on every later call — one count-less
      -- response froze a thread at its first page forever
      -- (evidence/t9/R3_comments_latch.log). Loaders may pass nil themselves;
      -- this is the second line so a new caller cannot reintroduce it.
      if page_total ~= nil then
        local reported = util.opt_number(page_total)
        if reported ~= nil and reported > 0 then
          cursor.total = reported
          cursor.count = reported
        end
      end
      -- Rows below this point demonstrably exist: either read here, or covered
      -- by a strict seek that landed on this exact page.
      if consumed + n > cursor.proven then cursor.proven = consumed + n end
      -- A server that ignores `pn` answers every page with the same rows. That
      -- used to append the same rows forever (the host only sees a longer list)
      -- so the repetition is detected here and the cursor is closed.
      if pn > 1 then
        local previous = cursor.pages[pn - 1]
        if previous ~= nil and #previous == n and signature(previous[1]) == signature(rows[1]) then
          cursor.complete = true
          cursor.count = consumed
          break
        end
      end
      if consumed + n > skip then located = true break end
      consumed = consumed + n
      pn = pn + 1
    end
    if not located then break end

    local rows = cursor.pages[pn]
    local n = #rows
    local index = skip - consumed + 1
    while index <= n and #out < want do
      out[#out + 1] = rows[index]
      index = index + 1
    end
    consumed = consumed + n
    skip = consumed
    pn = pn + 1
    if cursor.total ~= nil and skip >= cursor.total then break end
  end

  return out, hops, truncated
end

-- B family: `rows` is already the whole list; slice by offset/limit.
function M.slice(rows, limit, offset)
  local out = {}
  local source = util.list(rows)
  local count = #source
  local want = util.number(limit, 20)
  if want < 1 then want = 20 end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end
  local index = skip + 1
  local last = skip + want
  if last > count then last = count end
  while index <= last do
    out[#out + 1] = source[index]
    index = index + 1
  end
  return out
end

-- Budgets are exported so catalog.lua names the family it is calling instead of
-- repeating the number at each call site — a copy drifts the first time one of
-- them is re-measured against the wire.
M.PLAINTEXT_BUDGET = PLAINTEXT_BUDGET
M.SIGNED_BUDGET = SIGNED_BUDGET

return M
