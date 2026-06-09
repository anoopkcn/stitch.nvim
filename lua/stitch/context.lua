-- Interactive expand/collapse of the context around the stitch under the cursor.
--
-- Each match carries a per-match context level (lines shown above/below). Expand
-- raises the level of every match in the block under the cursor; collapse lowers
-- it (floor 0). The view is then repainted from the mutated levels.
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
  -- (multi-line / insert / delete) edits. Require a clean buffer first.
  if vim.bo[buf].modified then
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

  -- Find the block currently containing the cursor's source line.
  local blocks = model.blocks_from_levels(file.match_lnums, file.levels, file.line_count, file.pinned)
  local block
  for _, b in ipairs(blocks) do
    if rec.lnum >= b.s and rec.lnum <= b.e then
      block = b
      break
    end
  end
  if not block then
    return
  end

  local step = (count and count > 0) and count or (config.options.context_step or 4)
  local changed = false
  for _, ml in ipairs(file.match_lnums) do
    if ml >= block.s and ml <= block.e then
      local cur = file.levels[ml] or 0
      local new = sign > 0 and (cur + step) or math.max(0, cur - step)
      if new ~= cur then
        file.levels[ml] = new
        changed = true
      end
    end
  end

  if changed then
    render.repaint(buf)
  end
end

--- Show more context around the stitch under the cursor.
function M.expand(buf, count)
  adjust(buf, count, 1)
end

--- Show less context around the stitch under the cursor.
function M.collapse(buf, count)
  adjust(buf, count, -1)
end

return M
