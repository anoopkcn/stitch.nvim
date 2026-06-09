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
local intent = require('stitch.intent')
local srclang = require('stitch.lang')

local uv = vim.uv or vim.loop

local M = {}

local ns = vim.api.nvim_create_namespace('stitch')

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
local match_ns = vim.api.nvim_create_namespace('stitch_match')

-- Per-inserted-line attribution (which file an ambiguous boundary insert joins)
-- lives in the `stitch.intent` module; render only calls into it.

local function setup_highlights()
  local set = function(name, val)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', val, { default = true }))
  end
  -- The file-header groups carry a subtle background bar. They're *resolved* from
  -- the colorscheme (not linked) because a single link can't combine a foreground
  -- with a separate background; the ColorScheme autocmd below re-resolves them.
  local function attr(group, key)
    return (vim.api.nvim_get_hl(0, { name = group, link = false }) or {})[key]
  end
  local hbg = attr('CursorLine', 'bg') or attr('Visual', 'bg')
  set('StitchHeaderBg', { bg = hbg }) -- the bar fill past the text
  set('StitchHeaderDir', { fg = attr('Comment', 'fg'), bg = hbg }) -- dimmed path
  set('StitchHeaderName', { fg = attr('Normal', 'fg'), bg = hbg, bold = true }) -- file name

  set('StitchLnum', { link = 'LineNr' })
  set('StitchContextLnum', { link = 'NonText' })
  set('StitchAnnotation', { link = 'Comment' })
  set('StitchSeparator', { link = 'NonText' })
  set('StitchMatch', { underline = true, sp = '#61afef' })
end
setup_highlights()
-- :colorscheme clears user-added groups, so re-resolve the header colours after.
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_highlights })

-- Header as inline-virt-text chunks on the background bar: the directory dimmed
-- and the file name bold, so it reads as a label rather than blending into code.
local function header_chunks(relname)
  local dir, base = relname:match('^(.*/)([^/]+)$')
  if not dir then
    dir, base = '', relname
  end
  local chunks = { { ' ', 'StitchHeaderDir' } } -- small left margin on the bar
  if dir ~= '' then
    chunks[#chunks + 1] = { dir, 'StitchHeaderDir' }
  end
  chunks[#chunks + 1] = { base, 'StitchHeaderName' }
  return chunks
end

-- Header chunks plus a wide trailing pad so the background bar reaches the window
-- edge. The view is `nowrap` and the headers truncate the overflow, so the pad is
-- clipped to the window width.
local function header_bar(relname)
  local chunks = header_chunks(relname)
  chunks[#chunks + 1] = { string.rep(' ', 400), 'StitchHeaderBg' }
  return chunks
end

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

local function file_header(relname, is_first)
  local lines = {}
  if not is_first then
    lines[#lines + 1] = { { '', 'StitchSeparator' } }
  end
  lines[#lines + 1] = header_bar(relname)
  return lines
end

-- Divider shown between two non-adjacent blocks of the same file: a dim `⋮` in
-- the line-number gutter. The jump in line numbers already shows the gap's size.
local function block_divider()
  return { { { '   ⋮', 'StitchSeparator' } } }
end

local function open_window(buf)
  local mode = config.options.window
  -- Inherit the cursorline setting from the window we open from, rather than
  -- forcing it on: if the user keeps cursorline off, keep it off here too.
  local cursorline = vim.wo.cursorline
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
  vim.wo[win].cursorline = cursorline
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].list = false
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
  local rec = M.record_at(buf, vim.api.nvim_win_get_cursor(win)[1] - 1)
  if rec then
    vim.bo[buf].commentstring = srclang.commentstring(rec.filename)
    -- Remember the source line under the cursor so a line inserted next is
    -- attributed to its side of a boundary. Only updates on real stitch lines,
    -- so it survives the cursor landing on a freshly-inserted (unanchored) line.
    intent.note_cursor(buf, { filename = rec.filename, lnum = rec.lnum })
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

-- Flatten the live view (each file materialized for its current levels) into
-- buffer lines + per-row infos. Row 0 is a blank spacer: Neovim does not render
-- virt_lines *above* line 0, so reserving it keeps the first file header visible.
local function build_infos(st)
  local lines = { '' }
  local infos = {}
  for fi, f in ipairs(st.view.files) do
    local blocks = model.materialize(f, f.levels)
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

-- Paint st.view into the buffer: a clean re-render from the source model. The
-- buffer text is pure source; all metadata (line numbers, headers, dividers,
-- annotations, match highlights) is carried by extmarks. Anchors use
-- invalidate=false / right_gravity=false so they survive whole-line edits (e.g.
-- `gcc`); virt_lines use right_gravity=false so headers don't drift downward.
--
-- Records st.snapshot (the painted source text) and st.origin (the source
-- {filename,bufnr,lnum,col,source} of every buffer row) as the baseline that
-- write-back diffs the edited buffer against. Native edits — `gcc`, `dd`, `J`,
-- inserts, multi-line changes — need no special handling: the diff reconciles
-- whatever state the buffer ends up in.
-- Width of the inline line-number gutter ('%5d ' is 5 digits + a space).
local GUTTER = string.rep(' ', 6)

-- Place every per-row decoration for the current buffer from `rows`: rows[r+1] is
-- the source info for buffer row r, or false for a row with no source (the row-0
-- spacer, or a line the user inserted). Mapped rows get their line number, the
-- record backing record_at, annotation, header/divider, and match highlight;
-- inserted rows get a blank gutter so they stay aligned instead of shifting to
-- column 0. This only sets extmarks — it never touches buffer text or undo — so
-- it is safe to re-run on every structural edit.
local function decorate(buf, st, rows)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, match_ns, 0, -1)
  st.marks = {}

  -- Header/divider placement is derived from the *live* row adjacency, not from
  -- flags baked at paint: deleting a file's or block's first displayed line must
  -- promote the new top row to carry the header/divider instead of losing it.
  local bounds = reconcile.layout_bounds(rows)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row = 0, #lines - 1 do
    local info = rows[row + 1]
    local b = bounds[row + 1]
    if row == 0 then -- the spacer: no decoration
    elseif not info then
      -- Inserted line (no source yet): tag it with the file being edited (so a
      -- boundary insert knows which file it joins) and give it a blank gutter so
      -- it stays aligned instead of shifting to column 0.
      intent.tag(buf, row)
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        right_gravity = false,
        virt_text = { { GUTTER, 'StitchContextLnum' } },
        virt_text_pos = 'inline',
      })
    else
      -- Anchor extmark + inline source line number. Backs record_at (nav /
      -- expand / highlight). Match lines get a brighter number than context.
      local lnum_hl = info.is_match and 'StitchLnum' or 'StitchContextLnum'
      local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        right_gravity = false,
        invalidate = false,
        virt_text = { { string.format('%5d ', info.lnum), lnum_hl } },
        virt_text_pos = 'inline',
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
        -- on the row-0 spacer itself rather than leaving that line blank.
        vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
          virt_text = header_bar(info.relname),
          virt_text_pos = 'overlay',
          line_hl_group = 'StitchHeaderBg', -- belt-and-suspenders full-width fill
        })
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
        vim.api.nvim_buf_set_extmark(buf, ns, hrow, 0, {
          right_gravity = false,
          virt_lines = file_header(info.relname, b.is_first_file),
          virt_lines_above = true,
          virt_lines_overflow = 'trunc', -- clip the bar's pad to the window width
        })
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
          virt_lines = block_divider(),
          virt_lines_above = true,
        })
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

-- Source-drift tracking. The view is painted from a snapshot of each source
-- file; if a file changes underneath us (edited in another window, or on disk)
-- the view goes stale and a naive repaint would mis-render (gutter line numbers
-- and content disagree). For each file we keep `sync_lines` (its full source at
-- snapshot time, what a rebase diffs against) plus a cheap change-marker
-- (`changedtick` for a loaded buffer, else `mtime`+`size`) so the common
-- no-change check is O(1). These must be refreshed in lockstep with st.snapshot:
-- both paint and rebase_inplace call capture_sync, so our own writes never read
-- back as external drift.
local function capture_sync_file(f, lines)
  f.sync_lines = lines or model.read_lines(f.filename, f.bufnr)
  f.sync_tick = (f.bufnr and vim.api.nvim_buf_is_loaded(f.bufnr))
      and vim.api.nvim_buf_get_changedtick(f.bufnr) or nil
  local stat = uv.fs_stat(f.filename)
  f.sync_mtime = stat and stat.mtime or nil
  f.sync_size = stat and stat.size or nil
end

local function capture_sync(st)
  for _, f in ipairs(st.view.files) do
    capture_sync_file(f)
  end
end

-- Cheap pre-filter: has this file *possibly* changed since capture_sync? A loaded
-- buffer's changedtick is exact; an unloaded/on-disk file falls back to mtime+size
-- (which misses a same-second, same-length on-disk edit — acceptable, since query
-- results are normally loaded buffers where the tick is exact).
local function maybe_changed(f)
  if f.bufnr and vim.api.nvim_buf_is_loaded(f.bufnr) then
    return vim.api.nvim_buf_get_changedtick(f.bufnr) ~= f.sync_tick
  end
  local stat = uv.fs_stat(f.filename)
  if not stat then
    return false -- gone/unreadable: leave the view as-is; the save guard handles writes
  end
  if not f.sync_mtime or not f.sync_size then
    return true
  end
  return stat.size ~= f.sync_size
      or stat.mtime.sec ~= f.sync_mtime.sec
      or stat.mtime.nsec ~= f.sync_mtime.nsec
end

local function lines_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- Paint st.view into the buffer: a clean re-render from the source model. The
-- buffer text is pure source; all metadata is carried by extmarks (see decorate).
-- Records st.snapshot (painted text) and st.origin (per-row source info) as the
-- baseline that write-back and the live row→source map diff against.
local function paint(buf, st)
  local lines, infos = build_infos(st)

  -- Disable undo across the (re)layout: anchors are placed manually and can't
  -- survive an undo, so this view op is intentionally non-undoable.
  vim.bo[buf].modifiable = true
  local save_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- origin[row+1] is the source info for buffer row r; origin[1] (the row-0
  -- spacer) is false. The full info is kept so decorate can re-run from it.
  st.snapshot = lines
  st.origin = { [1] = false }
  for _, info in ipairs(infos) do
    st.origin[info.row + 1] = info
  end
  st.live = nil
  -- Fresh baseline: every line now maps to source, so there are no pending
  -- insertions to attribute.
  intent.reset(buf)
  -- The layout changed wholesale; have the highlighter recompute its block
  -- regions on the next redraw.
  st.ts_regions_count = nil

  decorate(buf, st, st.origin)
  st.decorated_count = #lines
  st.decorated_tick = vim.api.nvim_buf_get_changedtick(buf)

  -- The view now matches current source: reset the drift baseline so a later
  -- focus event doesn't read this paint as external change.
  capture_sync(st)

  vim.bo[buf].undolevels = save_undolevels
  vim.bo[buf].modified = false
end

--- Build (or reuse) the complete cached reconciliation of `buf` against the
--- painted baseline: { tick, map, hunks, current }. Both M.live_map and
--- M.reconcile go through this, so the cached entry is never partial and a `:w`
--- landing on the same changedtick a redraw already filled reuses the one entry.
--- Recomputed on a changedtick miss; cleared by paint and rebase_inplace.
--- Returns nil before the first paint.
local function live_entry(buf)
  local st = M.state[buf]
  if not st or not st.snapshot then
    return nil
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if st.live and st.live.tick == tick then
    return st.live
  end
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local r = reconcile.compute(st.snapshot, current, st.origin)
  st.live = { tick = tick, map = r.map, hunks = r.hunks, current = current }
  return st.live
end

--- Map current buffer rows to their painted source info: an array where
--- map[r+1] is the info for buffer row r, or false for the spacer / a line the
--- user inserted. Cached per changedtick. This is what keeps numbers + syntax
--- correct mid-edit: an inserted line reads as an insertion, so the lines around
--- it keep their source identity.
function M.live_map(buf)
  local e = live_entry(buf)
  return e and e.map or nil
end

--- The full reconciliation of the current buffer against the painted baseline,
--- for write-back: { map, hunks, current, origin }. `current` is the exact text
--- the hunks were diffed from (cached, not re-read), so the editor applies the
--- same text the display is showing.
function M.reconcile(buf)
  local e = live_entry(buf)
  if not e then
    return nil
  end
  return { map = e.map, hunks = e.hunks, current = e.current, origin = M.state[buf].origin }
end

--- Advance the diff baseline to `current` after a pure in-place clean save,
--- without re-laying-out (so undo survives, like a normal :w). `current` is the
--- exact text written back. Must drop st.live: no buffer edit happened, so
--- changedtick is unchanged and a stale cached diff would otherwise re-apply the
--- same edits on the next :w.
function M.rebase_inplace(buf, current)
  local st = M.state[buf]
  if not st then
    return
  end
  for i, o in pairs(st.origin) do
    if o and o.lnum then
      o.source = current[i]
    end
  end
  st.snapshot = current
  st.live = nil
  -- We just wrote these source files (their changedtick/mtime advanced); refresh
  -- the drift baseline so the next focus event doesn't mistake our own in-place
  -- write for external change and force a repaint (which would clear undo — the
  -- very thing this in-place path exists to preserve).
  capture_sync(st)
end

--- Re-place the gutter and decorations for the current (edited) buffer so
--- inserted/split lines don't lose their numbers, shift, or break highlighting.
--- Only sets extmarks — never touches buffer text or undo.
function M.redecorate(buf)
  local st = M.state[buf]
  if not st or not st.snapshot then
    return
  end
  local map = M.live_map(buf)
  if map then
    decorate(buf, st, map)
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
  if not st or not st.snapshot or st.syncing then
    return
  end

  -- Confirm real content divergence (the cheap marker is only a pre-filter) and
  -- compute each drifted file's rebase edits. A file whose marker moved but whose
  -- content is unchanged (e.g. it was just loaded into a buffer, or its mtime was
  -- touched) gets its marker refreshed so we don't re-check it every event.
  local diverged = {}
  for _, f in ipairs(st.view.files) do
    if maybe_changed(f) then
      local current = model.read_lines(f.filename, f.bufnr)
      if lines_equal(current, f.sync_lines) then
        capture_sync_file(f, current) -- marker moved but content didn't; re-baseline
      else
        diverged[#diverged + 1] = { file = f, edits = model.diff_to_edits(f.sync_lines, current) }
      end
    end
  end
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
    for _, d in ipairs(diverged) do
      model.shift_file(d.file, d.edits, false) -- false: don't pin foreign edits into the view
    end
    paint(buf, st) -- repaints and re-captures the drift baseline for every file
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

  -- Live view state, mutated by expand/collapse and re-read on repaint.
  local files, by_name = {}, {}
  for _, f in ipairs(source.files) do
    f.levels = {}
    for _, ml in ipairs(f.match_lnums) do
      f.levels[ml] = config.options.context or 0
    end
    f.pinned = {} -- lnums the user inserted/edited, kept visible at any context
    files[#files + 1] = f
    by_name[f.filename] = f
  end
  st.view = { title = source.title, files = files, files_by_name = by_name }

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
