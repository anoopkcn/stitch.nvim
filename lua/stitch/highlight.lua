-- Cross-file syntax highlighting, two tiers:
--
-- * Unedited blocks — the common case, and the entire view right after paint —
--   are highlighted by PROJECTION: each source file's full baseline content
--   (f.sync_lines, kept current by paint/rebase) is parsed once in a cached
--   string parser, and the captures covering a block's source range are
--   projected onto its view rows (one constant row offset per block). The
--   parser sees the *whole* file, so a block cut mid-function highlights
--   exactly like the file itself. Fragment parsing can't do that: a block
--   whose `function` never closes parses as an error and loses its structural
--   captures, making identical code render differently from block to block.
--
-- * Edited blocks fall back to real Treesitter parsing of the stitch buffer
--   text: every dirty block (a row whose text diverged from the baseline, or
--   an inserted row — known precisely from the reconcile hunks the display
--   already computes) becomes an included region of a per-language buffer
--   parser. The fallback is per-block, so editing one block never degrades
--   the highlighting of the others, and edits/inserts still highlight live
--   from the buffer's actual text.
--
-- A decoration provider applies both tiers as ephemeral marks on each redraw.
local config = require('stitch.config')
local render = require('stitch.render')
local reconcile = require('stitch.reconcile')
local intent = require('stitch.intent')
local srclang = require('stitch.lang')

local M = {}

local hl_ns = vim.api.nvim_create_namespace('stitch_highlight')

-- Language of buffer row `row` (0-based) for the fallback regions, and whether
-- it begins a new block. Existing rows take the language of their source file;
-- an inserted line takes the language of the file it is joining (its insert
-- intent).
local function row_lang(buf, map, bounds, row)
  local info = map[row + 1]
  if info and info.filename then
    local b = bounds[row + 1]
    return srclang.ts_lang(info.filename), b ~= nil and (b.first_in_file or b.block_divider) == true
  end
  local ref = intent.at(buf, row)
  return srclang.ts_lang(ref and ref.filename or nil), false
end

-- The per-(changedtick, baseline gen) layout: the live row→source map, its
-- bounds, and the contiguous same-file blocks with a `dirty` flag (some row of
-- the block was edited or sits next to an inserted row, per the reconcile
-- hunks — padded one row so boundary inserts dirty their neighbours). The
-- baseline's `gen` covers moves changedtick can't see (paint, rebase after a
-- save), so no manual invalidation is needed.
local function layout(buf, st)
  local b = st.baseline
  if not b then
    return nil
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if st.hl_layout and st.hl_layout.tick == tick and st.hl_layout.gen == b.gen then
    return st.hl_layout
  end
  local map, hunks
  if vim.bo[buf].modified then
    local R = b:reconcile()
    if not R then
      return nil
    end
    map, hunks = R.map, R.hunks
  else
    map, hunks = b.origin, {} -- clean buffer: rows are the baseline, no diff needed
  end
  if not map then
    return nil
  end
  local bounds = reconcile.layout_bounds(map)

  -- 1-based map indices of changed/inserted rows (±1 row of padding). Pure
  -- deletions (cb == 0) leave every remaining row's text intact, so they
  -- don't dirty anything — the split blocks still project correctly.
  local dirty = {}
  for _, h in ipairs(hunks) do
    local sb, cb = h[3], h[4]
    if cb > 0 then
      for i = sb - 1, sb + cb do
        dirty[i] = true
      end
    end
  end

  local blocks, cur = {}, nil
  for i = 1, #map do
    local info = map[i]
    if info and info.lnum then
      if cur and not bounds[i] and cur.filename == info.filename and info.lnum == cur.e_lnum + 1 then
        cur.e_row, cur.e_lnum = i, info.lnum
        cur.dirty = cur.dirty or dirty[i] or false
      else
        cur = {
          s_row = i, e_row = i, -- 1-based map indices (0-based view row + 1)
          filename = info.filename,
          s_lnum = info.lnum, e_lnum = info.lnum,
          lang = srclang.ts_lang(info.filename),
          dirty = dirty[i] or false,
        }
        blocks[#blocks + 1] = cur
      end
    else
      cur = nil -- spacer / inserted row: breaks the run (the row itself is in `dirty`)
    end
  end

  st.hl_layout = { tick = tick, gen = b.gen, map = map, bounds = bounds, blocks = blocks }
  return st.hl_layout
end

-- Cached full-source string parser for a file, keyed on the identity of
-- f.sync_lines (render replaces that table wholesale whenever the baseline
-- content moves, so identity doubles as a change marker). Built lazily, so
-- only files actually scrolled into view pay for a parse.
local function source_parser(st, filename, lang)
  local f = st.view.files_by_name[filename]
  if not (f and f.sync_lines) then
    return nil
  end
  st.hl_src = st.hl_src or {}
  local c = st.hl_src[filename]
  if not c or c.lines ~= f.sync_lines or c.lang ~= lang then
    local text = table.concat(f.sync_lines, '\n')
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
    c = { lines = f.sync_lines, lang = lang, text = text, parser = (ok and parser) or false }
    st.hl_src[filename] = c
  end
  return c.parser and c or nil
end

-- Run the highlights query of every tree of `parser` over source rows
-- [srow0, srow1) and emit each capture as an ephemeral mark, mapped through
-- `place` (which translates/clamps a node range, or rejects it with nil).
local function emit_captures(buf, parser, source, srow0, srow1, place)
  parser:for_each_tree(function(tstree, ltree)
    local lang = ltree:lang()
    local query = vim.treesitter.query.get(lang, 'highlights')
    if not query then
      return
    end
    for id, node, metadata in query:iter_captures(tstree:root(), source, srow0, srow1) do
      local name = query.captures[id]
      if name:sub(1, 1) ~= '_' then -- conventionally-hidden captures
        local sr, sc, er, ec = place(node:range())
        if sr then
          pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, sr, sc, {
            end_row = er,
            end_col = ec,
            hl_group = '@' .. name .. '.' .. lang,
            priority = tonumber(metadata.priority) or 100,
            ephemeral = true,
          })
        end
      end
    end
  end)
end

-- Tier 1: project a clean block's captures from its file's full-source parse
-- onto the view rows. `top`/`bot` bound the work to the visible rows.
local function project_block(buf, st, b, top, bot)
  local src = source_parser(st, b.filename, b.lang)
  if not src then
    return
  end
  local offset = (b.s_row - 1) - (b.s_lnum - 1) -- 0-based view row = source row + offset
  local s0 = math.max(b.s_lnum - 1, top - offset)
  local s1 = math.min(b.e_lnum - 1, bot - offset) + 1
  if s0 >= s1 then
    return
  end
  pcall(src.parser.parse, src.parser, { s0, s1 })
  emit_captures(buf, src.parser, src.text, s0, s1, function(sr, sc, er, ec)
    -- Clamp to the block: a node reaching outside it (a comment opened above,
    -- a function continuing below) must not paint the rows of other blocks.
    if sr < b.s_lnum - 1 then
      sr, sc = b.s_lnum - 1, 0
    end
    if er > b.e_lnum - 1 then
      er, ec = b.e_lnum - 1, #(src.lines[b.e_lnum] or '')
    end
    if er < sr or (er == sr and ec <= sc) then
      return nil
    end
    return sr + offset, sc, er + offset, ec
  end)
end

-- Tier 2's included regions: one per run of consecutive same-language rows
-- not covered by projection (dirty blocks and inserted rows). Applied to
-- per-language buffer parsers created on demand (st.ts_parsers); each
-- language's region set is diffed against the last applied one, so
-- per-keystroke redraws don't re-invalidate identical regions.
local function update_regions(buf, st, L)
  local projected = {}
  for _, b in ipairs(L.blocks) do
    if not b.dirty and b.lang then
      for i = b.s_row, b.e_row do
        projected[i] = true
      end
    end
  end

  local line_count = #L.map
  local by_lang = {}
  local cur_lang, cur_start
  local function flush(end_row)
    if cur_lang and cur_start then
      local regions = by_lang[cur_lang] or {}
      regions[#regions + 1] = { { cur_start, 0, end_row + 1, 0 } } -- one region, one range
      by_lang[cur_lang] = regions
    end
    cur_lang, cur_start = nil, nil
  end
  for row = 1, line_count - 1 do -- row 0 is the spacer
    if projected[row + 1] then
      flush(row - 1)
    else
      local lang, boundary = row_lang(buf, L.map, L.bounds, row)
      if lang ~= cur_lang or boundary then
        flush(row - 1)
        cur_lang, cur_start = lang, row
      end
    end
  end
  flush(line_count - 1)

  st.ts_parsers = st.ts_parsers or {}
  for lang in pairs(by_lang) do
    if st.ts_parsers[lang] == nil then
      local ok, p = pcall(vim.treesitter.get_parser, buf, lang, { error = false })
      st.ts_parsers[lang] = (ok and p) or false
    end
  end
  -- Apply regions to every known parser (empty for languages with no dirty
  -- rows right now), skipping parsers whose regions are unchanged.
  st.hl_region_keys = st.hl_region_keys or {}
  for lang, parser in pairs(st.ts_parsers) do
    if parser then
      local regions = by_lang[lang] or {}
      local key = {}
      for _, r in ipairs(regions) do
        key[#key + 1] = r[1][1] .. ':' .. r[1][3]
      end
      key = table.concat(key, ',')
      if st.hl_region_keys[lang] ~= key then
        st.hl_region_keys[lang] = key
        pcall(parser.set_included_regions, parser, regions)
      end
    end
  end
end

local function on_win(_, _, buf, top, bot)
  if not config.options.highlight then
    return false
  end
  local st = render.state[buf]
  if not st then
    return false
  end
  local L = layout(buf, st)
  if not L then
    return true
  end

  bot = math.min(bot, vim.api.nvim_buf_line_count(buf) - 1)

  -- Tier 1: clean blocks visible in this window, projected from full source.
  for _, b in ipairs(L.blocks) do
    if not b.dirty and b.lang and b.s_row - 1 <= bot and b.e_row - 1 >= top then
      project_block(buf, st, b, top, bot)
    end
  end

  -- Tier 2: buffer-parsed fallback for dirty blocks and inserted rows.
  local regions_key = L.tick .. ':' .. L.gen
  if st.hl_regions_key ~= regions_key then
    update_regions(buf, st, L)
    st.hl_regions_key = regions_key
  end
  if not st.ts_parsers then
    return true
  end
  for _, parser in pairs(st.ts_parsers) do
    if parser then
      pcall(parser.parse, parser, { top, bot + 1 })
      emit_captures(buf, parser, buf, top, bot + 1, function(sr, sc, er, ec)
        return sr, sc, er, ec
      end)
    end
  end
  return true
end

local registered = false

--- Register the (single, global) decoration provider. Idempotent.
function M.ensure()
  if registered then
    return
  end
  registered = true
  vim.api.nvim_set_decoration_provider(hl_ns, { on_win = on_win })
end

return M
