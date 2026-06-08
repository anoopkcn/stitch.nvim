-- Cross-file syntax highlighting via real Treesitter parsing of the excerpts
-- buffer itself.
--
-- Each maximal run of consecutive same-language rows (split at file headers and
-- `⋮` block dividers) is an "included region" of a per-language parser, so the
-- buffer is parsed as if each block were a slice of its own file. A decoration
-- provider projects those parsers' captures onto the visible rows as ephemeral
-- marks. This highlights existing, edited, newly-inserted, and multi-line content
-- uniformly from the buffer's *actual* text — no projection from source buffers,
-- no standalone single-line parsing.
--
-- The parsers track buffer edits themselves (incremental re-parse on `parse()`),
-- so in-place edits need no work here; only a structural change (line count
-- changed, or a repaint) shifts the block ranges and re-applies the regions.
local config = require('excerpts.config')
local render = require('excerpts.render')
local intent = require('excerpts.intent')
local srclang = require('excerpts.lang')

local M = {}

local hl_ns = vim.api.nvim_create_namespace('excerpts_highlight')

-- Language of buffer row `row` (0-based) and whether it begins a new block.
-- Existing rows take the language of their source file; an inserted line takes
-- the language of the file it is joining (its insert intent).
local function row_lang(buf, map, row)
  local info = map[row + 1]
  if info and info.filename then
    return srclang.ts_lang(info.filename), (info.first_in_file or info.block_divider) == true
  end
  return srclang.ts_lang(intent.at(buf, row)), false
end

-- Recompute each language's included regions (one region per contiguous
-- same-language block) from the live row→source map and apply them to
-- per-language parsers (created on demand, cached in st.ts_parsers).
local function update_regions(buf, st)
  local map = render.live_map(buf)
  if not map then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)

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
    local lang, boundary = row_lang(buf, map, row)
    if lang ~= cur_lang or boundary then
      flush(row - 1)
      cur_lang, cur_start = lang, row
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
  -- Apply regions to every known parser (empty for languages not currently shown).
  for lang, parser in pairs(st.ts_parsers) do
    if parser then
      pcall(parser.set_included_regions, parser, by_lang[lang] or {})
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

  local line_count = vim.api.nvim_buf_line_count(buf)
  -- Block ranges only shift on a structural change; in-place edits keep them, and
  -- the parsers re-parse those incrementally on parse() below.
  if st.ts_regions_count ~= line_count then
    update_regions(buf, st)
    st.ts_regions_count = line_count
  end
  if not st.ts_parsers then
    return true
  end

  bot = math.min(bot, line_count - 1)
  for _, parser in pairs(st.ts_parsers) do
    if parser then
      pcall(parser.parse, parser, { top, bot + 1 })
      parser:for_each_tree(function(tstree, ltree)
        local lang = ltree:lang()
        local query = vim.treesitter.query.get(lang, 'highlights')
        if not query then
          return
        end
        for id, node, metadata in query:iter_captures(tstree:root(), buf, top, bot + 1) do
          local name = query.captures[id]
          if name:sub(1, 1) ~= '_' then -- conventionally-hidden captures
            local sr, sc, er, ec = node:range()
            pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, sr, sc, {
              end_row = er,
              end_col = ec,
              hl_group = '@' .. name .. '.' .. lang,
              priority = tonumber(metadata.priority) or 100,
              ephemeral = true,
            })
          end
        end
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
