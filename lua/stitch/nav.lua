-- Jump from a stitch line in the stitch view to its source location.
local M = {}

-- Pick a window to open the source file in: any non-floating window in the
-- current tab that isn't showing a stitch view — neither this one nor another
-- (a stitch window carries the forced winopts, and a reused window is *not*
-- reset, so the source would render with the stitch gutter and no numbers).
-- If none, split off one. Returns the window and whether we created it (a
-- created window inherited the stitch window's options and must be reset; a
-- reused one already has the user's).
local function pick_target(mbwin)
  local render = require('stitch.render')
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= mbwin
        and vim.api.nvim_win_get_config(w).relative == ''
        and not render.state[vim.api.nvim_win_get_buf(w)] then
      return w, false
    end
  end
  vim.cmd('aboveleft vsplit')
  return vim.api.nvim_get_current_win(), true
end

function M.jump(buf)
  local mbwin = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(mbwin)[1] - 1
  local rec = require('stitch.render').record_at(buf, row)
  if not rec then
    vim.notify('stitches: no source for this line', vim.log.levels.WARN)
    return
  end

  local target, created = pick_target(mbwin)
  vim.api.nvim_set_current_win(target)
  if rec.bufnr and vim.api.nvim_buf_is_valid(rec.bufnr) then
    vim.api.nvim_set_current_buf(rec.bufnr)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(rec.filename))
  end
  -- Restore after the source is shown: a window we split off the stitch window
  -- inherited its forced options (no number, stitch gutter, …), and displaying
  -- the stitch buffer in that split even re-triggers render's winopts autocmd —
  -- so the restore has to be the last word, returning the user's normal window.
  if created then
    local render = require('stitch.render')
    render.restore_winopts(target, render.state[buf] and render.state[buf].normal_winopts)
  end
  pcall(vim.api.nvim_win_set_cursor, target, { rec.lnum, math.max((rec.col or 1) - 1, 0) })
  vim.cmd('normal! zz')
end

return M
