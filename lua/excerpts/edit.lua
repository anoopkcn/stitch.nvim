-- Write-back: on `:w`, diff the edited buffer against the snapshot taken at
-- paint time and apply the changes to the real source files.
--
-- The excerpts buffer is plain text edited with any native command — `gcc`,
-- `dd`, `J`, `o`, paste, multi-line changes. On save we diff `st.snapshot` (the
-- source text as painted) against the current buffer, map each diff hunk's
-- snapshot region back to a contiguous source range via `st.origin`, and rewrite
-- that range with `nvim_buf_set_lines`. There is no command-specific handling:
-- the diff reconciles whatever state the buffer ends up in.
--
-- A source line that changed underneath us since paint is never clobbered: the
-- hunk is flagged inline and skipped. A hunk that can't be mapped to a single
-- contiguous source range (it spans files or non-adjacent blocks) is likewise
-- skipped.
local render = require('excerpts.render')
local model = require('excerpts.model')

local M = {}

-- Inline warnings for skipped hunks; cleared and rebuilt on every save.
local warn_ns = vim.api.nvim_create_namespace('excerpts_warn')

vim.api.nvim_set_hl(0, 'ExcerptsDivergent', { link = 'WarningMsg', default = true })

-- Load (without focusing) the buffer backing `filename`. set_lines needs a
-- loaded buffer; loading also reads the current on-disk state so the divergence
-- guard sees external changes.
local function ensure_loaded(filename, bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
    return bufnr
  end
  local b = vim.fn.bufadd(filename)
  vim.fn.bufload(b)
  return b
end

local function flag(buf, row, message)
  if not row then
    return
  end
  row = math.max(0, math.min(row, vim.api.nvim_buf_line_count(buf) - 1))
  vim.api.nvim_buf_set_extmark(buf, warn_ns, row, 0, {
    virt_text = { { '  ‹ ' .. message .. ' ›', 'ExcerptsDivergent' } },
    virt_text_pos = 'eol',
  })
end

-- If snapshot rows [i0, i1] are one contiguous run of the same source file,
-- return its source range; otherwise nil. `sources` is the painted text, for
-- the divergence guard.
local function source_range(origin, i0, i1)
  local first = origin[i0]
  if not (first and first.lnum) then
    return nil
  end
  local sources = { first.source }
  for i = i0 + 1, i1 do
    local o, prev = origin[i], origin[i - 1]
    if not (o and o.lnum) or o.filename ~= first.filename or o.lnum ~= prev.lnum + 1 then
      return nil
    end
    sources[#sources + 1] = o.source
  end
  return {
    filename = first.filename,
    bufnr = first.bufnr,
    l0 = first.lnum,
    l1 = origin[i1].lnum,
    sources = sources,
  }
end

-- Map one diff hunk {start_a, count_a, start_b, count_b} to a list of planned
-- source changes (one per contiguous same-file run), or ({}, brow) when it can't
-- be mapped. A hunk can coalesce edits across file boundaries (e.g. commenting
-- adjacent lines from different files), so a single hunk may yield several plans.
--
-- Each plan replaces source lines [l0, l1] (1-based) of `filename` with
-- `newlines`; l1 == l0 - 1 means a pure insertion before l0.
local function plan_hunk(hunk, origin, current, buf)
  local sa, ca, sb, cb = hunk[1], hunk[2], hunk[3], hunk[4]
  local brow = math.max(0, sb - 1)

  if ca == 0 then
    -- Pure insertion after snapshot line `sa` (sa == 0 ⇒ before the first row).
    local newlines = {}
    for i = sb, sb + cb - 1 do
      newlines[#newlines + 1] = current[i]
    end
    local before = (sa >= 1) and origin[sa] or nil
    local after = origin[sa + 1]
    local ref, l0
    if before and before.lnum then
      if after and after.lnum and after.filename ~= before.filename then
        -- File boundary: join the file the line was created in (intent), else
        -- default to the following file. (`o` below the file above and `O` above
        -- the file below produce the same buffer; intent is the only signal.)
        if render.intent_at(buf, sb - 1) == before.filename then
          ref, l0 = before, before.lnum + 1 -- append to the file above
        else
          ref, l0 = after, after.lnum -- prepend to the file below
        end
      else
        ref, l0 = before, before.lnum + 1
      end
    elseif after and after.lnum then
      ref, l0 = after, after.lnum -- inserting above the very first source line
    else
      return {}, brow
    end
    return {
      {
        filename = ref.filename, bufnr = ref.bufnr,
        l0 = l0, l1 = l0 - 1, -- empty range ⇒ insert before l0
        newlines = newlines, sources = {}, brow = brow,
      },
    }
  end

  -- The whole region is one contiguous same-file range: a single plan covers
  -- replace / delete / multi-line. (The common case.)
  local whole = source_range(origin, sa, sa + ca - 1)
  if whole then
    whole.newlines = {}
    for i = sb, sb + cb - 1 do
      whole.newlines[#whole.newlines + 1] = current[i]
    end
    whole.brow = brow
    return { whole }
  end

  -- Region spans files / non-adjacent blocks. Splittable only when the old and
  -- new lines align 1:1 (count_a == count_b) or it is a pure deletion (cb == 0);
  -- otherwise the structural change can't be attributed to a single file.
  if ca ~= cb and cb ~= 0 then
    return {}, brow
  end
  local plans = {}
  local i = sa
  while i <= sa + ca - 1 do
    local j = i
    while j + 1 <= sa + ca - 1 and source_range(origin, i, j + 1) do
      j = j + 1
    end
    local run = source_range(origin, i, j)
    if not run then
      return {}, brow -- a non-source row sits in the region
    end
    if cb == 0 then
      run.newlines = {}
      run.brow = brow
    else
      run.newlines = {}
      for k = i, j do
        run.newlines[#run.newlines + 1] = current[sb + (k - sa)]
      end
      run.brow = math.max(0, sb + (i - sa) - 1)
    end
    plans[#plans + 1] = run
    i = j + 1
  end
  return plans
end

-- Current source [l0, l1] still matches the text we painted from?
local function source_intact(sbuf, plan)
  if plan.l1 < plan.l0 then
    return true -- insertion: nothing to clobber
  end
  local cur = vim.api.nvim_buf_get_lines(sbuf, plan.l0 - 1, plan.l1, false)
  if #cur ~= #plan.sources then
    return false
  end
  for i = 1, #cur do
    if cur[i] ~= plan.sources[i] then
      return false
    end
  end
  return true
end

--- Handle `:w` on an excerpts view.
function M.save(buf)
  local st = render.state[buf]
  if not st or not st.snapshot then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, warn_ns, 0, -1)

  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local hunks = vim.diff(
    table.concat(st.snapshot, '\n') .. '\n',
    table.concat(current, '\n') .. '\n',
    { result_type = 'indices' }
  )

  -- Group mappable hunks by source file; flag the rest.
  local by_file, order, unmappable = {}, {}, 0
  for _, h in ipairs(hunks) do
    local plans, brow = plan_hunk(h, st.origin, current, buf)
    if #plans == 0 then
      unmappable = unmappable + 1
      flag(buf, brow, 'cannot map edit (spans files/blocks) — not written')
    end
    for _, plan in ipairs(plans) do
      local f = by_file[plan.filename]
      if not f then
        f = { bufnr = plan.bufnr, plans = {} }
        by_file[plan.filename] = f
        order[#order + 1] = plan.filename
      end
      f.plans[#f.plans + 1] = plan
    end
  end

  local files_written, edits_applied, diverged = 0, 0, 0

  for _, filename in ipairs(order) do
    local f = by_file[filename]
    local sbuf = ensure_loaded(filename, f.bufnr)
    -- Apply bottom-up so earlier source line indices stay valid as we edit.
    table.sort(f.plans, function(a, b)
      return a.l0 > b.l0
    end)
    local applied = 0
    for _, p in ipairs(f.plans) do
      if source_intact(sbuf, p) then
        vim.api.nvim_buf_set_lines(sbuf, p.l0 - 1, p.l1, false, p.newlines)
        applied = applied + 1
        edits_applied = edits_applied + 1
      else
        p.diverged = true
        diverged = diverged + 1
        flag(buf, p.brow, 'source changed — not written')
      end
    end
    if applied > 0 then
      vim.api.nvim_buf_call(sbuf, function()
        vim.cmd('silent keepjumps update')
      end)
      files_written = files_written + 1
    end
  end

  -- Structural = some change added or removed source lines, so the displayed
  -- line numbers below it shifted and the view must be re-laid-out. A purely
  -- in-place save leaves the layout untouched.
  local structural = false
  for _, filename in ipairs(order) do
    for _, p in ipairs(by_file[filename].plans) do
      if p.l1 < p.l0 or #p.newlines ~= (p.l1 - p.l0 + 1) then
        structural = true
        break
      end
    end
  end

  local clean = (unmappable == 0 and diverged == 0)
  if clean and structural then
    -- Re-base the model for the lines we shifted, then re-render from the saved
    -- source: fresh line numbers and snapshot. (This relayout clears undo.)
    for _, filename in ipairs(order) do
      local vfile = st.view.files_by_name[filename]
      if vfile then
        local edits = {}
        for _, p in ipairs(by_file[filename].plans) do
          edits[#edits + 1] = {
            l0 = p.l0,
            oldcount = math.max(0, p.l1 - p.l0 + 1),
            newcount = #p.newlines,
          }
        end
        model.shift_file(vfile, edits)
      end
    end
    render.repaint(buf)
    vim.bo[buf].modified = false
  elseif clean then
    -- Pure in-place save: the buffer already shows the final text and line
    -- numbers are unchanged, so skip the relayout (and keep the undo history,
    -- like a normal `:w`). Just advance the diff baseline to what we wrote.
    for i, o in pairs(st.origin) do
      if o and o.lnum then
        o.source = current[i]
      end
    end
    st.snapshot = current
    vim.bo[buf].modified = false
  else
    -- Keep the user's edits (including un-written ones) and the inline flags so
    -- they can resolve the conflict and save again.
    vim.bo[buf].modified = true
  end

  local msg
  if edits_applied == 0 and clean then
    msg = 'excerpts: no changes to write'
  else
    msg = string.format('excerpts: wrote %d edit(s) in %d file(s)', edits_applied, files_written)
  end
  local level = vim.log.levels.INFO
  local notes = {}
  if diverged > 0 then
    notes[#notes + 1] = diverged .. ' skipped (source changed)'
    level = vim.log.levels.WARN
  end
  if unmappable > 0 then
    notes[#notes + 1] = unmappable .. ' skipped (unmappable)'
    level = vim.log.levels.WARN
  end
  if #notes > 0 then
    msg = msg .. ' — ' .. table.concat(notes, ', ')
  end
  vim.notify(msg, level)
end

return M
