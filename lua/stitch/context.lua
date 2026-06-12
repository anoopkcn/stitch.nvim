-- Interactive expand/collapse of the block under the cursor.
--
-- Blocks are the file's persistent visible ranges (model.lua): expand widens
-- the range under the cursor by `step` lines on each end (merging into a
-- neighbouring range it reaches); collapse narrows it, stopping at the hull
-- of the block's matches — the match lines never vanish out from under the
-- cursor, and interior lines of a merged block stay until the view is closed.
-- A range whose matches were all deleted (its match lines were edited away)
-- has no hull and collapses away entirely. The view is then repainted from
-- the mutated ranges.
local config = require('stitch.config')
local render = require('stitch.render')
local model = require('stitch.model')

local M = {}

--- @param buf integer
--- @param count integer|nil explicit line count (overrides config.context_step)
--- @param sign integer +1 to expand, -1 to collapse
local function adjust(buf, count, sign)
  local st = render.state[buf]
  if not st then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end

  -- Pick up any source drift first, so the relayout below is computed from a
  -- model that matches the current source rather than mis-rendering against a
  -- stale one. (A no-op when nothing changed.)
  render.sync(buf)

  -- Expand/collapse re-lays-out the buffer, which can't preserve structural
  -- (multi-line / insert / delete) edits. Require a clean buffer first —
  -- render.dirty, not 'modified', because undoing past a save leaves unsaved
  -- reverse edits with the flag off.
  if render.dirty(buf) then
    vim.notify('stitches: write (:w) before expand/collapse', vim.log.levels.WARN)
    return
  end

  local rec = render.record_at(buf, vim.api.nvim_win_get_cursor(win)[1] - 1)
  if not rec then
    vim.notify('stitches: no stitch under the cursor', vim.log.levels.INFO)
    return
  end

  local file = st.view.files_by_name[rec.filename]
  if not file then
    return
  end

  -- The range currently containing the cursor's source line.
  local idx, range
  for i, r in ipairs(file.ranges) do
    if rec.lnum >= r.s and rec.lnum <= r.e then
      idx, range = i, r
      break
    end
  end
  if not range then
    return
  end

  local step = (count and count > 0) and count or (config.options.context_step or 1)
  local old_s, old_e, removed = range.s, range.e, false

  if sign > 0 then
    range.s = math.max(1, range.s - step)
    range.e = math.min(file.line_count, range.e + step)
    -- Growing can reach the neighbouring range; restore the merged invariant.
    file.ranges = model.merge_ranges(file.ranges)
  else
    -- The hull of the matches still inside this range: collapse stops there.
    local lo, hi
    for _, ml in ipairs(file.match_lnums) do -- sorted ascending
      if ml >= range.s and ml <= range.e then
        lo = lo or ml
        hi = ml
      end
    end
    if lo then
      range.s = math.min(range.s + step, lo)
      range.e = math.max(range.e - step, hi)
    else
      range.s = range.s + step
      range.e = range.e - step
      if range.s > range.e then
        table.remove(file.ranges, idx)
        removed = true
      end
    end
  end

  if removed or range.s ~= old_s or range.e ~= old_e then
    render.repaint(buf, { kind = 'model' })
  end
end

--- Show more context around the block under the cursor.
function M.expand(buf, count)
  adjust(buf, count, 1)
end

--- Show less context around the block under the cursor.
function M.collapse(buf, count)
  adjust(buf, count, -1)
end

return M
