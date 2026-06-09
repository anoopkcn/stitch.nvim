-- Paints a source model into a dedicated, editable `acwrite` buffer:
--   * one real line per stitch/context line (the source line text)
--   * file headers and block dividers as virt_lines (zero bytes, not editable)
--   * source line number shown inline (virt_text), match span underlined
--   * quickfix annotation (e.g. diagnostic message) at end of line
--
-- Each line carries an "anchor" extmark whose id maps back to its source
-- {filename, bufnr, lnum}. That stable line address is what write-back,
-- jump-to-source, and expand/collapse all rely on.
local config = require('stitch.config')
local model = require('stitch.model')
local reconcile = require('stitch.reconcile')
local baseline = require('stitch.baseline')
local chrome = require('stitch.chrome')
local viewwin = require('stitch.viewwin')
local intent = require('stitch.intent')
local srclang = require('stitch.lang')

local M = {}

local ns = vim.api.nvim_create_namespace('stitch')

-- bufnr -> {
--   marks    = { [extmark_id] = { filename, bufnr, lnum, col, source } },
--   view     = { title, files = { source-model file + .ranges }, files_by_name },
--   baseline = stitch.baseline object: snapshot/origin/live diff/drift markers
-- }
M.state = {}

-- Namespace holding the anchor extmarks; the editor reads it to map edited
-- lines back to their source location.
M.ns = ns

-- Separate namespace for static match-span highlights (kept out of the anchor
-- namespace so record_at/the editor never see them).
local match_ns = vim.api.nvim_create_namespace('stitch_match')

-- Per-inserted-line attribution (which file an ambiguous boundary insert joins)
-- lives in the `stitch.intent` module; render only calls into it.

local function setup_highlights()
  local set = function(name, val)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', val, { default = true }))
  end
  -- File headers carry a subtle full-width background bar with the path dimmed
  -- onto it. The directory and file name are *resolved* against the bar background
  -- (not linked, since a link can't combine a fg with a separate bg) and
  -- re-resolved by the ColorScheme autocmd below.
  local function attr(group, key)
    return (vim.api.nvim_get_hl(0, { name = group, link = false }) or {})[key]
  end
  local hbg = attr('CursorLine', 'bg') or attr('Visual', 'bg')
  set('StitchHeaderBg', { bg = hbg }) -- the bar fill past the text
  set('StitchHeaderDir', { fg = attr('Comment', 'fg'), bg = hbg }) -- dimmed directory
  set('StitchHeaderName', { fg = attr('Comment', 'fg'), bg = hbg }) -- file name (also dimmed)

  set('StitchLnum', { link = 'LineNr' })
  set('StitchContextLnum', { link = 'NonText' })
  set('StitchAnnotation', { link = 'Comment' })
  set('StitchSeparator', { link = 'NonText' })
  set('StitchDivergent', { link = 'WarningMsg' }) -- edit.lua's skipped-hunk flags
  -- Buffer-text highlights have no real alpha, so a "transparent" blue is faked
  -- by blending the blue into the editor background at a low weight.
  local function blend(fg, bg, alpha)
    local function split(c)
      return math.floor(c / 0x10000) % 0x100, math.floor(c / 0x100) % 0x100, c % 0x100
    end
    local fr, fg_, fb = split(fg)
    local br, bg_, bb = split(bg)
    local function mix(a, b) return math.floor(a * alpha + b * (1 - alpha) + 0.5) end
    return string.format('#%02x%02x%02x', mix(fr, br), mix(fg_, bg_), mix(fb, bb))
  end
  local nbg = attr('Normal', 'bg') or (vim.o.background == 'light' and 0xffffff or 0x000000)
  set('StitchMatch', { bg = blend(0x61afef, nbg, 0.40) })
end
setup_highlights()
-- :colorscheme clears user-added groups, so re-resolve the header colours after.
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_highlights })

local function unique_name(title)
  local base = '[Stitch] ' .. title
  local name = base
  local n = 1
  while vim.fn.bufexists(name) == 1 do
    n = n + 1
    name = base .. ' (' .. n .. ')'
  end
  return name
end


-- Open the view's window per config and hand the window-option lifecycle to
-- stitch.viewwin: adopt() snapshots the user's real settings from the window
-- we open *from* (before any split or buffer swap) and wires the
-- reassert/restore autocmds; claim() forces the view options on the window
-- that ends up showing it.
local function open_window(buf)
  local mode = config.options.window
  viewwin.adopt(buf)
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
  viewwin.claim(win, buf)
  return win
end

local function set_keymaps(buf)
  local keys = config.options.keys
  local opts = { buffer = buf, nowait = true, silent = true }
  if keys.jump then
    vim.keymap.set('n', keys.jump, function()
      require('stitch.nav').jump(buf)
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
      require('stitch.context').expand(buf, n > 0 and n or nil)
    end, opts)
  end
  if keys.collapse then
    vim.keymap.set('n', keys.collapse, function()
      local n = vim.v.count
      require('stitch.context').collapse(buf, n > 0 and n or nil)
    end, opts)
  end
  -- `gg` lands on the first stitch, not the row-0 spacer — which is blank and
  -- only carries the first file's header (virt_lines can't render above line 0,
  -- so the header rides that spacer). A count behaves like the native motion, so
  -- `1gg` still reaches the header line.
  vim.keymap.set('n', 'gg', function()
    local last = vim.api.nvim_buf_line_count(buf)
    local count = vim.v.count
    local target = count > 0 and math.min(count, last) or math.min(2, last)
    vim.cmd('normal! ' .. target .. 'G')
  end, opts)
end

-- Native `gc`/`gcc` reads 'commentstring' to choose the comment syntax — pure
-- source text doesn't tell it the language. Keep it matching the source file
-- under the cursor so commenting uses each stitch's own syntax. (Single-line
-- and single-file selections are correct; a mixed-language multi-line selection
-- uses the cursor line's syntax — native commenting has one commentstring per
-- invocation.)
local function update_commentstring(buf)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  -- CursorMoved is hot: skip the extmark lookup when the cursor is still on
  -- the same row of the same buffer state (most motions are within a line).
  local st = M.state[buf]
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if st and st.cs_row == row and st.cs_tick == tick then
    return
  end
  local rec = M.record_at(buf, row)
  if rec then
    local cs = srclang.commentstring(rec.filename)
    if vim.bo[buf].commentstring ~= cs then
      vim.bo[buf].commentstring = cs
    end
    -- Remember the source line under the cursor so a line inserted next is
    -- attributed to its side of a boundary. Only updates on real stitch lines,
    -- so it survives the cursor landing on a freshly-inserted (unanchored) line.
    intent.note_cursor(buf, { filename = rec.filename, lnum = rec.lnum })
    if st then
      st.cs_row, st.cs_tick = row, tick
    end
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

-- Flatten the live view (each file materialized for its visible ranges) into
-- buffer lines + per-row infos. Row 0 is a blank spacer: Neovim does not render
-- virt_lines *above* line 0, so reserving it keeps the first file header visible.
local function build_infos(st)
  local lines = { '' }
  local infos = {}
  -- Each file's full source, read once here and reused to seed the baseline's
  -- drift markers — otherwise every (re)paint reads every file twice.
  local src_by_file = {}
  for fi, f in ipairs(st.view.files) do
    local src_lines = model.read_lines(f.filename, f.bufnr)
    src_by_file[f.filename] = src_lines
    local blocks = model.materialize(f, src_lines)
    for bi, block in ipairs(blocks) do
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
        }
      end
    end
  end
  return lines, infos, src_by_file
end

-- Find the buffer row currently showing (filename, lnum); falls back to the
-- nearest displayed line of the same file. Returns a 0-based row or nil.
local function row_for(buf, st, filename, lnum)
  local nearest, nearest_d
  -- One bulk extmark query instead of a per-mark API call; marks that aren't
  -- anchors (annotations, headers) have no st.marks record and are skipped.
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
    local rec = st.marks[m[1]]
    if rec and rec.filename == filename then
      if rec.lnum == lnum then
        return m[2]
      end
      local d = math.abs(rec.lnum - lnum)
      if not nearest_d or d < nearest_d then
        nearest_d, nearest = d, m[2]
      end
    end
  end
  return nearest
end

-- Paint st.view into the buffer: a clean re-render from the source model. The
-- buffer text is pure source; all metadata (line numbers, headers, dividers,
-- annotations, match highlights) is carried by extmarks. Anchors use
-- invalidate=false / right_gravity=false so they survive whole-line edits (e.g.
-- `gcc`); virt_lines use right_gravity=false so headers don't drift downward.
--
-- Resets st.baseline (the painted text + per-row source origin) as what
-- write-back diffs the edited buffer against. Native edits — `gcc`, `dd`, `J`,
-- inserts, multi-line changes — need no special handling: the diff reconciles
-- whatever state the buffer ends up in.

--- The source line-number gutter, rendered as a real `statuscolumn` (forced
--- window-locally by stitch.viewwin). For a real buffer line it maps the
--- drawn row back to its
--- source line — via the paint baseline when the buffer is clean, or the live
--- row→source map mid-edit (so inserted/split lines keep correct numbers); the
--- diff only runs when the buffer is modified, so a clean redraw never pays for
--- a reconcile. Match lines get a brighter number than context lines; the
--- spacer and inserted lines get a blank pad.
---
--- The file header and block divider are virtual lines drawn above their anchor
--- row, so the gutter is drawn for them too (v:virtnum < 0). Only the line closest
--- to the anchor (-1) carries content — a header's blank separator (-2) and
--- wrapped rows (>0) stay blank. st.gutter (rebuilt each decorate) maps an anchor
--- line to { k, s }: k is 'header'/'divider' (drawn at v:virtnum == -1) or
--- 'header0' (the first file's header, overlaid on the row-0 spacer at v:virtnum
--- == 0). s is the ready statuscolumn string — for a header, the first GUTTER
--- columns of the path, so the path reads from the left edge.
function M.statuscol()
  local win = vim.g.statusline_winid
  local buf = win and win >= 0 and vim.api.nvim_win_get_buf(win)
  local st = buf and M.state[buf]
  if not st then
    return chrome.GUTTER
  end
  local g = st.gutter and st.gutter[vim.v.lnum]
  if vim.v.virtnum ~= 0 then
    if vim.v.virtnum == -1 and g and (g.k == 'header' or g.k == 'divider') then
      return g.s
    end
    return chrome.GUTTER
  end
  if g and g.k == 'header0' then
    return g.s -- first file's header overlaid on the row-0 spacer
  end
  local map = st.baseline and st.baseline:map()
  local info = map and map[vim.v.lnum]
  if not info then
    return chrome.GUTTER -- the row-0 spacer, or a line the user inserted (no source yet)
  end
  return chrome.lnum_cell(info.lnum, info.is_match)
end

-- Place every per-row decoration for the current buffer from `rows`: rows[r+1] is
-- the source info for buffer row r, or false for a row with no source (the row-0
-- spacer, or a line the user inserted). Mapped rows get their line number, the
-- record backing record_at, annotation, header/divider, and match highlight;
-- inserted rows get a blank gutter so they stay aligned instead of shifting to
-- column 0. This only sets extmarks — it never touches buffer text or undo — so
-- it is safe to re-run on every structural edit.
local function decorate(buf, st, rows, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, match_ns, 0, -1)
  st.marks = {}
  -- Maps a 1-based line to { k, s } describing the gutter statuscol should paint
  -- for the virt_line (header / divider) above it, or the row-0 header overlay
  -- ('header0'). `s` is the ready statuscolumn string (a header spills its leading
  -- path columns here). Rebuilt here so it tracks live header/divider placement.
  st.gutter = {}

  -- Header/divider placement is derived from the *live* row adjacency, not from
  -- flags baked at paint: deleting a file's or block's first displayed line must
  -- promote the new top row to carry the header/divider instead of losing it.
  local bounds = reconcile.layout_bounds(rows)

  -- Both callers already hold the buffer text (paint just set it; redecorate
  -- diffed it), so a fresh full read is only a fallback.
  lines = lines or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row = 0, #lines - 1 do
    local info = rows[row + 1]
    local b = bounds[row + 1]
    if row == 0 then -- the spacer: no decoration
    elseif not info then
      -- Inserted line (no source yet): tag it with the file being edited so a
      -- boundary insert knows which file it joins. Its blank gutter is handled
      -- by statuscol (no source line → blank pad), so no anchor mark is placed.
      intent.tag(buf, row)
    else
      -- Anchor extmark backing record_at (nav / expand / highlight) and the
      -- statuscol number lookup. The line number itself is drawn by the
      -- statuscolumn, not an inline virt_text, so the cursor never sits in it.
      local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        right_gravity = false,
        invalidate = false,
      })
      st.marks[id] = info

      if info.annotation then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          right_gravity = false,
          virt_text = { { '  ┊ ' .. info.annotation, 'StitchAnnotation' } },
          virt_text_pos = 'eol',
        })
      end

      if b and b.first_in_file and b.is_first_file then
        -- virt_lines don't render *above* line 0, so show the first file's header
        -- on the row-0 spacer itself rather than leaving that line blank. `gut` is
        -- the path's leading columns, drawn in the row-0 gutter (see statuscol).
        local gut, body = chrome.header_parts(info.relname)
        vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
          virt_text = body,
          virt_text_pos = 'overlay',
          line_hl_group = 'StitchHeaderBg', -- belt-and-suspenders full-width fill
        })
        st.gutter[1] = { k = 'header0', s = gut }
      elseif b and b.first_in_file then
        -- New lines inserted directly above this file's first line join this file
        -- (and prepend on save) only if they were created while editing it, so
        -- anchor the header above those. A line created while editing the file
        -- above stays under that file (header stays put).
        local hrow = row
        while hrow - 1 >= 1 and not rows[hrow] do
          local tagged = intent.tag(buf, hrow - 1)
          if tagged and tagged.filename and tagged.filename ~= info.filename then
            break
          end
          hrow = hrow - 1
        end
        -- A blank separator line (-2) above the bar (-1); the bar's leading path
        -- columns ride its gutter (statuscol reads st.gutter at v:virtnum == -1).
        local gut, body = chrome.header_parts(info.relname)
        vim.api.nvim_buf_set_extmark(buf, ns, hrow, 0, {
          right_gravity = false,
          virt_lines = { { { '', 'StitchSeparator' } }, body },
          virt_lines_above = true,
          virt_lines_overflow = 'trunc', -- clip the bar's pad to the window width
        })
        st.gutter[hrow + 1] = { k = 'header', s = gut }
      elseif b and b.block_divider then
        -- A line opened directly above this block's first line joins this block
        -- (and is written into it) only when its insertion intent points here —
        -- the cursor was on this block when the line was opened. Anchor the
        -- divider above such lines so they read as part of this block, mirroring
        -- edit.plan_hunk's lower-block branch (intent == this row's source). A
        -- line opened while on the block above keeps the divider below it, so it
        -- stays grouped with — and writes back into — that block.
        local drow = row
        while drow - 1 >= 1 and not rows[drow] do
          local tagged = intent.tag(buf, drow - 1)
          if not (tagged and tagged.filename == info.filename and tagged.lnum == info.lnum) then
            break
          end
          drow = drow - 1
        end
        vim.api.nvim_buf_set_extmark(buf, ns, drow, 0, {
          right_gravity = false,
          virt_lines = chrome.divider_lines(),
          virt_lines_above = true,
        })
        st.gutter[drow + 1] = { k = 'divider', s = chrome.DIVIDER_GUTTER } -- ⋮ in this row's gutter
      end

      -- Highlight the matched span(s), clamped to the row's current text.
      if info.spans then
        local len = #(lines[row + 1] or '')
        for _, span in ipairs(info.spans) do
          local scol = math.max(0, math.min(span[1], len))
          local ecol = math.max(scol, math.min(span[2], len))
          if ecol > scol then
            vim.api.nvim_buf_set_extmark(buf, match_ns, row, scol, {
              end_row = row,
              end_col = ecol,
              hl_group = 'StitchMatch',
              priority = 200,
            })
          end
        end
      end
    end
  end
end

-- Paint st.view into the buffer: a clean re-render from the source model. The
-- buffer text is pure source; all metadata is carried by extmarks (see
-- decorate). Resets st.baseline — snapshot, per-row origin, drift markers —
-- which is what write-back and the live row→source map diff against.
local function paint(buf, st)
  local lines, infos, src_by_file = build_infos(st)

  -- Disable undo across the (re)layout: anchors are placed manually and can't
  -- survive an undo, so this view op is intentionally non-undoable.
  vim.bo[buf].modifiable = true
  local save_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Fresh baseline (the lines read by build_infos seed the drift markers, so
  -- nothing is read twice). Every line now maps to source, so there are no
  -- pending insertions to attribute either.
  st.baseline:reset(lines, infos, src_by_file)
  intent.reset(buf)

  decorate(buf, st, st.baseline.origin, lines)
  st.decorated_count = #lines
  st.decorated_tick = vim.api.nvim_buf_get_changedtick(buf)

  vim.bo[buf].undolevels = save_undolevels
  vim.bo[buf].modified = false
end

--- Re-place the gutter and decorations for the current (edited) buffer so
--- inserted/split lines don't lose their numbers, shift, or break highlighting.
--- Only sets extmarks — never touches buffer text or undo.
function M.redecorate(buf)
  local st = M.state[buf]
  if not st or not st.baseline.snapshot then
    return
  end
  local e = st.baseline:reconcile()
  if e and e.map then
    decorate(buf, st, e.map, e.current) -- e.current: the exact text e.map was diffed from
    st.decorated_count = vim.api.nvim_buf_line_count(buf)
    st.decorated_tick = vim.api.nvim_buf_get_changedtick(buf)
  end
end

--- Reconcile the view with its source files when they changed underneath it
--- (edited in another window, or on disk). Autoread-style: if the stitch buffer
--- has no unsaved edits, rebase each drifted file's model (line numbers follow
--- their source; matches on deleted lines drop) and repaint from fresh source —
--- which also keeps the gutter and content in agreement. If the buffer *does*
--- have unsaved edits, leave it untouched and warn once: clobbering the user's
--- in-progress work to chase the source is never worth it, and `:w` already
--- skips drifted hunks via the divergence guard.
---
--- This rebases *existing* stitches; it does not re-run the grep/diagnostics/diff
--- query, so a source edit that creates a brand-new match won't surface here.
function M.sync(buf)
  local st = M.state[buf]
  if not st or not st.baseline or not st.baseline.snapshot or st.syncing then
    return
  end

  local diverged = st.baseline:drift()
  if #diverged == 0 then
    return
  end

  if vim.bo[buf].modified then
    if not st.stale then
      st.stale = true
      vim.notify(
        'stitches: source changed underneath — your edits are kept; :w writes them (drifted lines are skipped), undo to refresh',
        vim.log.levels.WARN
      )
    end
    return
  end

  st.syncing = true
  local win = vim.api.nvim_get_current_win()
  local saved = (vim.api.nvim_win_get_buf(win) == buf) and vim.fn.winsaveview() or nil
  local ok, err = pcall(function()
    st.baseline:absorb(diverged) -- rebase the model (foreign boundary inserts stay hidden)
    paint(buf, st) -- repaints and resets the baseline (drift markers included)
  end)
  -- Always clear the guard: a paint that threw must not wedge sync off for the
  -- buffer's whole life.
  st.syncing = false
  if saved then
    pcall(vim.fn.winrestview, saved)
  end
  if ok then
    st.stale = false
  else
    vim.notify('stitches: source refresh failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Render a source model into a new stitch view. Returns (buf, win).
function M.open(source)
  local buf = vim.api.nvim_create_buf(true, true)
  local st = { marks = {} }
  M.state[buf] = st

  -- Live view state, mutated by expand/collapse and re-read on repaint. The
  -- visible ranges are derived from the matches exactly once, here; from then
  -- on they only ever *move* (with source edits, or via expand/collapse), so
  -- content never slides in or out of view when line numbers shift.
  local files, by_name = {}, {}
  for _, f in ipairs(source.files) do
    f.ranges = model.ranges_from_matches(f.match_lnums, config.options.context or 1, f.line_count)
    files[#files + 1] = f
    by_name[f.filename] = f
  end
  st.view = { title = source.title, files = files, files_by_name = by_name }
  st.baseline = baseline.new(buf, st.view)

  paint(buf, st)

  -- 'acwrite' makes `:w` fire BufWriteCmd instead of writing a file named after
  -- the buffer; the editor module turns that into per-source-file writes.
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'stitch'
  pcall(vim.api.nvim_buf_set_name, buf, unique_name(source.title or 'list'))
  vim.bo[buf].modified = false

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function(args)
      require('stitch.edit').save(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      intent.discard(buf)
      M.state[buf] = nil
    end,
  })

  require('stitch.highlight').ensure()

  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buf,
    callback = function()
      update_commentstring(buf)
    end,
  })

  -- Keep the gutter/decorations in sync with edits. Whole-line operations
  -- (`gcc`, `cc`, `dd`, `J`) disturb anchors and adjacent headers even without a
  -- line-count change, so re-place on any real change in normal mode (gated by
  -- changedtick to skip our own repaint). In insert mode the change is
  -- per-keystroke and only a line split/join (a count change) disturbs layout, so
  -- gate that on the line count to avoid re-decorating on every character.
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function(a)
      local st = M.state[buf]
      if not st then
        return
      end
      if a.event == 'TextChangedI' then
        if st.decorated_count ~= vim.api.nvim_buf_line_count(buf) then
          M.redecorate(buf)
        end
      elseif st.decorated_tick ~= vim.api.nvim_buf_get_changedtick(buf) then
        M.redecorate(buf)
      end
    end,
  })

  -- Refresh from source when the view regains focus after the source was edited
  -- elsewhere (BufEnter/WinEnter), or while dwelling on it as a file changes on
  -- disk (CursorHold). M.sync is a cheap no-op when nothing drifted.
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'CursorHold' }, {
    buffer = buf,
    callback = function()
      M.sync(buf)
    end,
  })

  local win = open_window(buf)
  set_keymaps(buf)
  -- Land on the first stitch, not the blank spacer at row 0.
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

  paint(buf, st)

  if cursor_rec and vim.api.nvim_win_get_buf(win) == buf then
    local target = row_for(buf, st, cursor_rec.filename, cursor_rec.lnum)
    if target then
      pcall(vim.api.nvim_win_set_cursor, win, { target + 1, 0 })
    end
  end
end

return M
