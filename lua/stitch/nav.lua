-- Jump from a stitch line in the stitch view to its source location.
local M = {}

function M.jump(buf)
  local mbwin = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(mbwin)[1] - 1
  local rec = require('stitch.render').record_at(buf, row)
  if not rec then
    vim.notify('stitches: no source for this line', vim.log.levels.WARN)
    return
  end

  local viewwin = require('stitch.viewwin')
  local target, created = viewwin.pick_source_win(mbwin)
  vim.api.nvim_set_current_win(target)
  if rec.bufnr and vim.api.nvim_buf_is_valid(rec.bufnr) then
    vim.api.nvim_set_current_buf(rec.bufnr)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(rec.filename))
  end
  -- Release after the source is shown: a window split off the stitch window
  -- inherited its forced options (no number, stitch gutter, …), and showing
  -- the stitch buffer in that split even re-triggers the reassert autocmd —
  -- so the release has to be the last word, returning the user's normal
  -- window.
  if created then
    viewwin.release(target, buf)
  end
  pcall(vim.api.nvim_win_set_cursor, target, { rec.lnum, math.max((rec.col or 1) - 1, 0) })
  vim.cmd('normal! zz')
end

return M
