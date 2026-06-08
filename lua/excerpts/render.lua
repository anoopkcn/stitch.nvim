-- Paints a source model into a dedicated, editable `acwrite` buffer:
--   * one real line per excerpt/context line (the source line text)
--   * file headers and block dividers as virt_lines (zero bytes, not editable)
--   * source line number shown inline (virt_text), match span underlined
--   * quickfix annotation (e.g. diagnostic message) at end of line
--
-- Each line carries an "anchor" extmark whose id maps back to its source
-- {filename, bufnr, lnum}. That stable line address is what write-back,
-- jump-to-source, and expand/collapse all rely on.
local config = require('excerpts.config')
local model = require('excerpts.model')

local M = {}

local ns = vim.api.nvim_create_namespace('excerpts')

-- bufnr -> {
--   marks = { [extmark_id] = { filename, bufnr, lnum, col, source } },
--   view  = { title, files = { source-model file + .levels }, files_by_name },
-- }
M.state = {}

-- Namespace holding the anchor extmarks; the editor reads it to map edited
-- lines back to their source location.
M.ns = ns

-- Separate namespace for static match-span highlights (kept out of the anchor
-- namespace so record_at/the editor never see them).
local match_ns = vim.api.nvim_create_namespace('excerpts_match')

local function setup_highlights()
  local set = function(name, val)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', val, { default = true }))
  end
  set('ExcerptsHeader', { link = 'Directory' })
  set('ExcerptsLnum', { link = 'LineNr' })
  set('ExcerptsContextLnum', { link = 'NonText' })
  set('ExcerptsAnnotation', { link = 'Comment' })
  set('ExcerptsSeparator', { link = 'NonText' })
  set('ExcerptsMatch', { underline = true, sp = '#61afef' })
end
setup_highlights()

local function unique_name(title)
  local base = '[Excerpts] ' .. title
  local name = base
  local n = 1
  while vim.fn.bufexists(name) == 1 do
    n = n + 1
    name = base .. ' (' .. n .. ')'
  end
  return name
end

local function file_header(relname, is_first)
  local lines = {}
  if not is_first then
    lines[#lines + 1] = { { '', 'ExcerptsSeparator' } }
  end
  lines[#lines + 1] = { { '▌ ' .. relname, 'ExcerptsHeader' } }
  return lines
end

-- Divider shown between two non-adjacent blocks of the same file (a gap of
-- `gap` hidden source lines).
local function block_divider(gap)
  local label = gap > 0 and string.format('   ⋮ %d lines', gap) or '   ⋮'
  return { { { label, 'ExcerptsSeparator' } } }
end

local function open_window(buf)
  local mode = config.options.window
  if mode == 'current' then
    vim.api.nvim_set_current_buf(buf)
  elseif mode == 'vsplit' then
    vim.cmd('botright vsplit')
    vim.api.nvim_win_set_buf(0, buf)
  elseif mode == 'tab' then
    vim.cmd('tabnew')
    vim.api.nvim_win_set_buf(0, buf)
  else -- 'split'
    vim.cmd('botright split')
    vim.api.nvim_win_set_buf(0, buf)
  end
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].list = false
  return win
end

local function set_keymaps(buf)
  local keys = config.options.keys
  local opts = { buffer = buf, nowait = true, silent = true }
  if keys.jump then
    vim.keymap.set('n', keys.jump, function()
      require('excerpts.nav').jump(buf)
    end, opts)
  end
  if keys.close then
    vim.keymap.set('n', keys.close, function()
      M.close(buf)
    end, opts)
  end
  if keys.expand then
    vim.keymap.set('n', keys.expand, function()
      local n = vim.v.count
      require('excerpts.context').expand(buf, n > 0 and n or nil)
    end, opts)
  end
  if keys.collapse then
    vim.keymap.set('n', keys.collapse, function()
      local n = vim.v.count
      require('excerpts.context').collapse(buf, n > 0 and n or nil)
    end, opts)
  end
end

--- Look up the source record for a buffer row (0-indexed).
function M.record_at(buf, row)
  local st = M.state[buf]
  if not st then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})
  for _, m in ipairs(marks) do
    local rec = st.marks[m[1]]
    if rec then
      return rec
    end
  end
  return nil
end

function M.close(buf)
  if vim.api.nvim_win_get_buf(0) == buf and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.cmd('close')
  else
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

-- Stable map key for a (filename, lnum) pair.
local function key(filename, lnum)
  return filename .. '\0' .. lnum
end

-- Flatten the live view (each file materialized for its current levels) into
-- buffer lines + per-row infos. Row 0 is a blank spacer: Neovim does not render
-- virt_lines *above* line 0, so reserving it keeps the first file header visible.
local function build_infos(st)
  local lines = { '' }
  local infos = {}
  for fi, f in ipairs(st.view.files) do
    local blocks = model.materialize(f, f.levels)
    for bi, block in ipairs(blocks) do
      local prev = blocks[bi - 1]
      local gap = prev and (block.lines[1].lnum - prev.lines[#prev.lines].lnum - 1) or 0
      for li, line in ipairs(block.lines) do
        local row = #lines
        lines[#lines + 1] = line.source
        infos[#infos + 1] = {
          row = row,
          filename = f.filename,
          relname = f.relname,
          bufnr = f.bufnr,
          lnum = line.lnum,
          col = line.col,
          source = line.source,
          annotation = line.annotation,
          is_match = line.is_match,
          spans = line.spans,
          first_in_file = (bi == 1 and li == 1),
          is_first_file = (fi == 1),
          block_divider = (bi > 1 and li == 1),
          gap = gap,
        }
      end
    end
  end
  return lines, infos
end

-- Find the buffer row currently showing (filename, lnum); falls back to the
-- nearest displayed line of the same file. Returns a 0-based row or nil.
local function row_for(buf, st, filename, lnum)
  local nearest, nearest_d
  for id, rec in pairs(st.marks) do
    if rec.filename == filename then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
      if pos and pos[1] then
        if rec.lnum == lnum then
          return pos[1]
        end
        local d = math.abs(rec.lnum - lnum)
        if not nearest_d or d < nearest_d then
          nearest_d, nearest = d, pos[1]
        end
      end
    end
  end
  return nearest
end

-- Paint st.view into the buffer. With preserve=true (a repaint), pending edits
-- to existing excerpt lines are carried over as buffer text while each anchor's
-- recorded `source` stays the true original, so write-back still diffs correctly.
local function paint(buf, st, preserve)
  -- Capture pending edits, and carry the original divergence baseline forward,
  -- before the old anchors are cleared. Re-snapshotting `source` from the current
  -- file on every repaint would let an external change quietly become the new
  -- baseline and mask divergence; existing lines keep their open-time original.
  local pending, pending_n, old_source = {}, 0, {}
  if preserve then
    for id, rec in pairs(st.marks) do
      old_source[key(rec.filename, rec.lnum)] = rec.source
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
      if pos and pos[1] then
        local cur = vim.api.nvim_buf_get_lines(buf, pos[1], pos[1] + 1, false)[1]
        if cur ~= nil and cur ~= rec.source then
          pending[key(rec.filename, rec.lnum)] = cur
          pending_n = pending_n + 1
        end
      end
    end
  end

  local lines, infos = build_infos(st)

  -- Overlay surviving edits onto the new line list.
  local kept = 0
  if pending_n > 0 then
    for _, info in ipairs(infos) do
      local edited = pending[key(info.filename, info.lnum)]
      if edited ~= nil then
        lines[info.row + 1] = edited
        info.edited = edited
        kept = kept + 1
      end
    end
  end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, match_ns, 0, -1)
  st.marks = {}

  -- Disable undo across the (re)layout: anchors are placed manually and can't
  -- survive an undo, so this view op is intentionally non-undoable.
  vim.bo[buf].modifiable = true
  local save_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for _, info in ipairs(infos) do
    local linetext = info.edited or info.source
    -- Anchor extmark + inline source line number. Doubles as the line address.
    -- Match lines get a brighter number than surrounding context lines.
    local lnum_hl = info.is_match and 'ExcerptsLnum' or 'ExcerptsContextLnum'
    local id = vim.api.nvim_buf_set_extmark(buf, ns, info.row, 0, {
      right_gravity = false,
      invalidate = true,
      virt_text = { { string.format('%5d ', info.lnum), lnum_hl } },
      virt_text_pos = 'inline',
    })
    st.marks[id] = {
      filename = info.filename,
      bufnr = info.bufnr,
      lnum = info.lnum,
      col = info.col,
      -- true original (open-time for existing lines, fresh for newly-revealed),
      -- even when the buffer shows an edit
      source = old_source[key(info.filename, info.lnum)] or info.source,
    }

    if info.annotation then
      vim.api.nvim_buf_set_extmark(buf, ns, info.row, 0, {
        virt_text = { { '  ┊ ' .. info.annotation, 'ExcerptsAnnotation' } },
        virt_text_pos = 'eol',
      })
    end

    if info.first_in_file then
      vim.api.nvim_buf_set_extmark(buf, ns, info.row, 0, {
        virt_lines = file_header(info.relname, info.is_first_file),
        virt_lines_above = true,
      })
    elseif info.block_divider then
      vim.api.nvim_buf_set_extmark(buf, ns, info.row, 0, {
        virt_lines = block_divider(info.gap),
        virt_lines_above = true,
      })
    end

    -- Highlight the matched span(s) on the line, above syntax highlighting.
    if info.spans then
      local len = #linetext
      for _, span in ipairs(info.spans) do
        local scol = math.max(0, math.min(span[1], len))
        local ecol = math.max(scol, math.min(span[2], len))
        if ecol > scol then
          vim.api.nvim_buf_set_extmark(buf, match_ns, info.row, scol, {
            end_row = info.row,
            end_col = ecol,
            hl_group = 'ExcerptsMatch',
            priority = 200,
          })
        end
      end
    end
  end

  vim.bo[buf].undolevels = save_undolevels
  vim.bo[buf].modified = kept > 0

  if pending_n > kept then
    vim.notify(
      string.format('excerpts: %d edit(s) on now-hidden lines discarded', pending_n - kept),
      vim.log.levels.WARN
    )
  end
end

-- 'commentstring' for a file, derived from its name and cached per filetype.
-- (Empty unless filetype plugins are enabled, which they are in normal sessions.)
local cs_cache = {}
local function commentstring_for(filename)
  local ft = vim.filetype.match({ filename = filename })
  if not ft or ft == '' then
    return ''
  end
  local cs = cs_cache[ft]
  if cs == nil then
    local ok, val = pcall(vim.filetype.get_option, ft, 'commentstring')
    cs = (ok and val) or ''
    cs_cache[ft] = cs
  end
  return cs
end

-- Keep 'commentstring' matching the source file under the cursor so `gcc` (and
-- any comment plugin) uses each excerpt's own language syntax.
local function update_commentstring(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local rec = M.record_at(buf, vim.api.nvim_win_get_cursor(win)[1] - 1)
  if rec then
    vim.bo[buf].commentstring = commentstring_for(rec.filename)
  end
end

--- Render a source model into a new excerpts view. Returns (buf, win).
function M.open(source)
  local buf = vim.api.nvim_create_buf(true, true)
  local st = { marks = {} }
  M.state[buf] = st

  -- Live view state, mutated by expand/collapse and re-read on repaint.
  local files, by_name = {}, {}
  for _, f in ipairs(source.files) do
    f.levels = {}
    for _, ml in ipairs(f.match_lnums) do
      f.levels[ml] = config.options.context or 0
    end
    files[#files + 1] = f
    by_name[f.filename] = f
  end
  st.view = { title = source.title, files = files, files_by_name = by_name }

  paint(buf, st, false)

  -- 'acwrite' makes `:w` fire BufWriteCmd instead of writing a file named after
  -- the buffer; the editor module turns that into per-source-file writes.
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'excerpts'
  pcall(vim.api.nvim_buf_set_name, buf, unique_name(source.title or 'list'))
  vim.bo[buf].modified = false

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function(args)
      require('excerpts.edit').save(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      M.state[buf] = nil
    end,
  })

  require('excerpts.highlight').ensure()

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      update_commentstring(buf)
    end,
  })

  local win = open_window(buf)
  set_keymaps(buf)
  -- Land on the first excerpt, not the blank spacer at row 0.
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(2, vim.api.nvim_buf_line_count(buf)), 0 })
  update_commentstring(buf) -- initial, before the cursor first moves
  return buf, win
end

--- Re-lay-out the view after a level change, preserving edits and the cursor's
--- source line.
function M.repaint(buf)
  local st = M.state[buf]
  if not st then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local cursor_rec
  if vim.api.nvim_win_get_buf(win) == buf then
    cursor_rec = M.record_at(buf, vim.api.nvim_win_get_cursor(win)[1] - 1)
  end

  paint(buf, st, true)

  if cursor_rec and vim.api.nvim_win_get_buf(win) == buf then
    local target = row_for(buf, st, cursor_rec.filename, cursor_rec.lnum)
    if target then
      pcall(vim.api.nvim_win_set_cursor, win, { target + 1, 0 })
    end
  end
end

return M
