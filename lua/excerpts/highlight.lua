-- Cross-file syntax highlighting.
--
-- A single decoration provider projects each visible excerpt line's Treesitter
-- highlights from its *source* buffer onto the excerpts buffer as ephemeral marks.
-- The language is derived from the filename, so source buffers are loaded but
-- never filetype-detected (no LSP is started just to colour an excerpt).
--
-- compute_line_highlights() is a pure function (no ephemeral marks, no redraw
-- dependency) so the capture-extraction logic can be unit-tested headlessly;
-- the decoration-provider shell around it is deliberately thin.
local config = require('excerpts.config')
local render = require('excerpts.render')

local M = {}

local hl_ns = vim.api.nvim_create_namespace('excerpts_highlight')

-- filename -> lang string, or false when the file has no Treesitter grammar.
local lang_cache = {}

--- Resolve the Treesitter language for a file from its name (pure, cached).
local function lang_for(filename)
  local cached = lang_cache[filename]
  if cached ~= nil then
    return cached or nil
  end
  local lang = false
  local ft = vim.filetype.match({ filename = filename })
  if ft and ft ~= '' then
    local l = vim.treesitter.language.get_lang(ft)
    if l and pcall(vim.treesitter.language.add, l) then
      lang = l
    end
  end
  lang_cache[filename] = lang
  return lang or nil
end

--- Compute Treesitter highlight spans for one source line. Pure: returns a list
--- of { col, end_col, hl_group, priority } (0-based byte columns, end-exclusive)
--- and sets no extmarks. Columns are clamped to `max_col` (the display line's
--- byte length) so an edited excerpt can't push a span past the rendered text.
--- @param source_buf integer loaded source buffer
--- @param lnum0 integer 0-based source line
--- @param lang string|nil nil => no spans (grammarless file)
--- @param max_col integer
--- @return table[]
function M.compute_line_highlights(source_buf, lnum0, lang, max_col)
  local spans = {}
  if not lang or not vim.api.nvim_buf_is_loaded(source_buf) then
    return spans
  end
  if lnum0 < 0 or lnum0 >= vim.api.nvim_buf_line_count(source_buf) then
    return spans
  end
  local ok, parser = pcall(vim.treesitter.get_parser, source_buf, lang, { error = false })
  if not ok or not parser then
    return spans
  end
  pcall(function()
    parser:parse({ lnum0, lnum0 + 1 })
  end)
  parser:for_each_tree(function(tstree, tree)
    local tlang = tree:lang()
    local query = vim.treesitter.query.get(tlang, 'highlights')
    if not query then
      return
    end
    for id, node, metadata in query:iter_captures(tstree:root(), source_buf, lnum0, lnum0 + 1) do
      local name = query.captures[id]
      if name:sub(1, 1) ~= '_' then -- conventionally-hidden captures
        local sr, sc, er, ec = node:range()
        if sr <= lnum0 and er >= lnum0 then
          -- Clamp a multi-line node to this line's portion.
          local start_col = (sr == lnum0) and sc or 0
          local end_col = (er == lnum0) and ec or max_col
          start_col = math.min(start_col, max_col)
          end_col = math.min(end_col, max_col)
          if end_col > start_col then
            spans[#spans + 1] = {
              col = start_col,
              end_col = end_col,
              hl_group = '@' .. name .. '.' .. tlang,
              priority = tonumber(metadata.priority) or 100,
            }
          end
        end
      end
    end
  end)
  return spans
end

-- Source files awaiting a (scheduled, off-redraw) load.
local pending = {}

local function schedule_load(mbbuf, recs)
  local fresh = {}
  for _, rec in ipairs(recs) do
    if not pending[rec.filename] then
      pending[rec.filename] = true
      fresh[#fresh + 1] = rec
    end
  end
  if #fresh == 0 then
    return
  end
  vim.schedule(function()
    for _, rec in ipairs(fresh) do
      pending[rec.filename] = nil
      local b = (rec.bufnr and vim.api.nvim_buf_is_valid(rec.bufnr)) and rec.bufnr
        or vim.fn.bufadd(rec.filename)
      if not vim.api.nvim_buf_is_loaded(b) then
        pcall(vim.fn.bufload, b)
      end
      rec.bufnr = b -- cache the resolved handle for next redraw
    end
    pcall(vim.api.nvim__redraw, { buf = mbbuf, valid = false })
  end)
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
  bot = math.min(bot, line_count - 1)
  local to_load

  local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, { top, 0 }, { bot, -1 }, {})
  for _, m in ipairs(marks) do
    local id, row = m[1], m[2]
    local rec = st.marks[id]
    if rec then
      local lang = lang_for(rec.filename)
      if lang then -- grammarless files: terminal skip (no load, no highlight)
        local sbuf = rec.bufnr
        if sbuf and vim.api.nvim_buf_is_valid(sbuf) and vim.api.nvim_buf_is_loaded(sbuf) then
          local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
          local spans = M.compute_line_highlights(sbuf, rec.lnum - 1, lang, #line)
          for _, s in ipairs(spans) do
            pcall(vim.api.nvim_buf_set_extmark, buf, hl_ns, row, s.col, {
              end_row = row,
              end_col = s.end_col,
              hl_group = s.hl_group,
              priority = s.priority,
              ephemeral = true,
            })
          end
        else
          to_load = to_load or {}
          to_load[#to_load + 1] = rec
        end
      end
    end
  end

  if to_load then
    schedule_load(buf, to_load)
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
