-- The baseline: the single owner of everything the stitch view is diffed
-- against. One instance per view, holding the consistency web that used to be
-- kept in lockstep by hand across render and edit:
--
--   * snapshot — the painted source text, one entry per buffer row
--   * origin   — origin[i] = source {filename,bufnr,lnum,col,source} of
--                snapshot row i, or false (e.g. origin[1], the row-0 spacer)
--   * live     — the cached reconciliation of the current buffer against the
--                snapshot (one vim.diff per changedtick, shared by the gutter,
--                the highlighter, and write-back)
--   * per-file drift markers on view.files — sync_lines (the file's full
--                source at baseline time) plus a cheap change marker
--                (changedtick for a loaded buffer, else mtime+size)
--
-- Invariants the module maintains so callers never have to:
--   * snapshot[i] == origin[i].source for every mapped row
--   * origin line numbers, the view model (matches, visible ranges,
--     line_count via model.shift_file), and sync_lines all use the same
--     source coordinates — every advance moves them together
--   * `gen` increments whenever the baseline moves without a buffer edit
--     (changedtick can't see those), so caches key on (changedtick, gen)
--
-- The reconciliation kernel itself stays in stitch.reconcile (pure); this
-- module owns the *state* and the operations that move it.
local model = require('stitch.model')
local reconcile = require('stitch.reconcile')

local uv = vim.uv or vim.loop

local M = {}

local B = {}
B.__index = B

--- A fresh, empty baseline for the view shown in `buf`. Populate with reset().
function M.new(buf, view)
  return setmetatable({ buf = buf, view = view, gen = 0 }, B)
end

-- ---------------------------------------------------------------------------
-- Drift markers

local function capture_sync_file(f, lines)
  f.sync_lines = lines or model.read_lines(f.filename, f.bufnr)
  f.sync_tick = (f.bufnr and vim.api.nvim_buf_is_loaded(f.bufnr))
      and vim.api.nvim_buf_get_changedtick(f.bufnr) or nil
  local stat = uv.fs_stat(f.filename)
  f.sync_mtime = stat and stat.mtime or nil
  f.sync_size = stat and stat.size or nil
end

-- Cheap pre-filter: has this file *possibly* changed since its marker was
-- captured? A loaded buffer's changedtick is exact; an unloaded/on-disk file
-- falls back to mtime+size (which misses a same-second, same-length edit —
-- acceptable, since query results are normally loaded buffers).
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

-- `lines_by_file` (optional) provides already-read source content keyed by
-- filename, so a paint that just read every file doesn't read them all again.
function B:capture_sync(lines_by_file)
  for _, f in ipairs(self.view.files) do
    capture_sync_file(f, lines_by_file and lines_by_file[f.filename])
  end
end

-- ---------------------------------------------------------------------------
-- Reset / reconcile

--- Reset to a freshly painted view: `lines` is the painted text (lines[1] is
--- the row-0 spacer), `infos` the per-row source records (carrying .row,
--- 0-based), `src_by_file` the full source read during the paint (reused for
--- the drift markers).
function B:reset(lines, infos, src_by_file)
  self.snapshot = lines
  self.origin = { [1] = false }
  for _, info in ipairs(infos) do
    self.origin[info.row + 1] = info
  end
  self.live = nil
  self.gen = self.gen + 1
  self:capture_sync(src_by_file)
end

-- The cached reconciliation entry: { tick, map, hunks, current }. Recomputed
-- on a changedtick miss, so a `:w` landing on the same tick a redraw already
-- filled reuses the one entry.
function B:entry()
  if not self.snapshot then
    return nil
  end
  local tick = vim.api.nvim_buf_get_changedtick(self.buf)
  if self.live and self.live.tick == tick then
    return self.live
  end
  local current = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local r = reconcile.compute(self.snapshot, current, self.origin)
  self.live = { tick = tick, map = r.map, hunks = r.hunks, current = current }
  return self.live
end

--- The full reconciliation of the current buffer against the baseline:
--- { map, hunks, current, origin }. `current` is the exact text the hunks
--- were diffed from, so write-back applies the same text the display shows.
function B:reconcile()
  local e = self:entry()
  if not e then
    return nil
  end
  return { map = e.map, hunks = e.hunks, current = e.current, origin = self.origin }
end

--- Per-row source info for the *current* buffer rows: map[r+1] is the info
--- for row r, or false. A clean buffer is the baseline itself, so this costs
--- nothing; a modified buffer pays one cached diff per changedtick.
function B:map()
  if not self.snapshot then
    return nil
  end
  if not vim.bo[self.buf].modified then
    return self.origin
  end
  local e = self:entry()
  return e and e.map or nil
end

-- ---------------------------------------------------------------------------
-- Advance after write-back

-- Shift the view model (matches, visible ranges, line_count) by the applied
-- plans, file by file, so the next materialize agrees with the source we just
-- wrote — inserted lines grow their range, deletions shrink it, and the next
-- repaint shows exactly what the user's edit implied.
function B:shift_model(applied)
  local by_file = {}
  for _, p in ipairs(applied) do
    local edits = by_file[p.filename]
    if not edits then
      edits = {}
      by_file[p.filename] = edits
    end
    edits[#edits + 1] = {
      l0 = p.l0,
      oldcount = math.max(0, p.l1 - p.l0 + 1),
      newcount = #p.newlines,
    }
  end
  for filename, edits in pairs(by_file) do
    local vfile = self.view.files_by_name[filename]
    if vfile then
      model.shift_file(vfile, edits)
    end
  end
end

-- Splice the applied plans of a partial save into snapshot/origin so the next
-- diff no longer reports them, shifting origin line numbers below each
-- structural edit by a running per-file delta (mutated in place: render's
-- st.marks shares these info tables). Then advance each written file's drift
-- markers by the same edits — if the result matches the file's actual content
-- our write was the only change and the markers move with it; otherwise the
-- file *also* drifted externally and the markers stay stale so drift() still
-- sees it.
function B:splice(applied)
  table.sort(applied, function(a, b)
    return a.s0 < b.s0
  end)

  local snap, origin, delta = {}, {}, {}
  local si = 1
  local function copy_to(last)
    while si <= last do
      local o = self.origin[si]
      if o and o.lnum and delta[o.filename] then
        o.lnum = o.lnum + delta[o.filename]
      end
      snap[#snap + 1] = self.snapshot[si]
      origin[#origin + 1] = o or false
      si = si + 1
    end
  end
  for _, p in ipairs(applied) do
    copy_to(p.s0 - 1)
    si = math.max(si, p.s1 + 1) -- drop the replaced rows (insertion: s1 < s0, no-op)
    local d = delta[p.filename] or 0
    -- A 1:1 in-place replacement keeps each row's identity (is_match drives
    -- the gutter brightness); spans/annotation are dropped — the text changed.
    local inplace = p.s1 >= p.s0 and #p.newlines == (p.s1 - p.s0 + 1)
    for k, line in ipairs(p.newlines) do
      local old = inplace and self.origin[p.s0 + k - 1] or nil
      snap[#snap + 1] = line
      origin[#origin + 1] = {
        filename = p.filename,
        relname = p.relname,
        bufnr = p.bufnr,
        lnum = p.l0 + d + k - 1,
        col = (old and old.col) or 1,
        is_match = (old and old.is_match) or nil,
        source = line,
      }
    end
    delta[p.filename] = d + #p.newlines - math.max(0, p.l1 - p.l0 + 1)
  end
  copy_to(#self.snapshot)
  self.snapshot = snap
  self.origin = origin
  self.live = nil -- changedtick didn't move; a stale cached diff would replay the old hunks
  self.gen = self.gen + 1

  local by_file = {}
  for _, p in ipairs(applied) do
    by_file[p.filename] = by_file[p.filename] or {}
    table.insert(by_file[p.filename], p)
  end
  for filename, fplans in pairs(by_file) do
    local f = self.view.files_by_name[filename]
    if f and f.sync_lines then
      table.sort(fplans, function(a, b)
        return a.l0 < b.l0
      end)
      local expected, i = {}, 1
      for _, p in ipairs(fplans) do
        while i < p.l0 do
          expected[#expected + 1] = f.sync_lines[i]
          i = i + 1
        end
        for _, line in ipairs(p.newlines) do
          expected[#expected + 1] = line
        end
        i = math.max(i, p.l1 + 1)
      end
      while i <= #f.sync_lines do
        expected[#expected + 1] = f.sync_lines[i]
        i = i + 1
      end
      local actual = model.read_lines(f.filename, f.bufnr)
      if lines_equal(actual, expected) then
        capture_sync_file(f, actual)
      else
        f.sync_lines = expected
      end
    end
  end
end

--- Advance the baseline after write-back. `plans` are every plan of the save,
--- each tagged `.applied`; `current` is the exact buffer text the hunks were
--- diffed from; `clean` means no hunk diverged or was unmappable. Picks the
--- advance internally and keeps the view model and drift markers in lockstep:
---
---   * clean + structural — the displayed line numbers shifted, so the view
---     needs a full re-layout: shifts the model and returns 'repaint' (the
---     caller's repaint resets this baseline from fresh source).
---   * clean + in-place — rows are unchanged 1:1: advances the rows in place
---     (so undo survives, like a normal :w) and refreshes the drift markers.
---   * partial — splices just the applied hunks into the baseline so the next
---     :w doesn't re-plan them (or read our own write as divergence) and the
---     next focus event doesn't mistake it for external drift. Returns
---     'redecorate' so the spliced rows get their anchors.
---
--- Returns 'repaint', 'redecorate', or nil (nothing further to do).
function B:advance(plans, current, clean)
  local applied = {}
  for _, p in ipairs(plans) do
    if p.applied then
      applied[#applied + 1] = p
    end
  end
  local structural = false
  for _, p in ipairs(applied) do
    if p.l1 < p.l0 or #p.newlines ~= (p.l1 - p.l0 + 1) then
      structural = true
      break
    end
  end

  if clean and structural then
    self:shift_model(applied)
    return 'repaint'
  elseif clean then
    -- Pure in-place: the buffer already shows the final text and line numbers
    -- are unchanged. Advance the rows without re-laying-out and refresh the
    -- drift markers so our own write doesn't read back as external change.
    for i, o in pairs(self.origin) do
      if o and o.lnum then
        o.source = current[i]
      end
    end
    self.snapshot = current
    self.live = nil
    self.gen = self.gen + 1
    self:capture_sync()
    return nil
  end

  if #applied == 0 then
    return nil -- nothing was applied; the baseline already matches reality
  end
  self:shift_model(applied)
  self:splice(applied)
  return 'redecorate'
end

-- ---------------------------------------------------------------------------
-- External drift

--- Which files changed underneath the view since the baseline was captured?
--- Confirms real content divergence (the cheap marker is only a pre-filter)
--- and computes each drifted file's rebase edits. A file whose marker moved
--- but whose content didn't (e.g. it was just loaded into a buffer) gets its
--- marker refreshed so it isn't re-checked every event.
--- @return table[] list of { file, edits } (edits as model.shift_file takes)
function B:drift()
  local diverged = {}
  for _, f in ipairs(self.view.files) do
    if maybe_changed(f) then
      local current = model.read_lines(f.filename, f.bufnr)
      if lines_equal(current, f.sync_lines) then
        capture_sync_file(f, current) -- marker moved but content didn't; re-baseline
      else
        diverged[#diverged + 1] = { file = f, edits = model.diff_to_edits(f.sync_lines, current) }
      end
    end
  end
  return diverged
end

--- Rebase the view model for externally drifted files (matches follow their
--- source; matches on deleted lines drop; ranges move content-anchored, but
--- foreign boundary insertions don't grow the view). The caller repaints
--- afterwards, which resets the baseline.
function B:absorb(diverged)
  for _, d in ipairs(diverged) do
    model.shift_file(d.file, d.edits, false)
  end
end

return M
