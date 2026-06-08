-- Jump from an excerpt line in the multibuffer view to its source location.
local M = {}

-- Pick a window to open the source file in: any non-floating window in the
-- current tab that isn't the multibuffer window. If none, split off one.
local function pick_target(mbwin)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= mbwin and vim.api.nvim_win_get_config(w).relative == '' then
      return w
    end
  end
  vim.cmd('aboveleft vsplit')
  return vim.api.nvim_get_current_win()
end

function M.jump(buf)
  local mbwin = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(mbwin)[1] - 1
  local rec = require('multibuffers.render').record_at(buf, row)
  if not rec then
    vim.notify('multibuffers: no source for this line', vim.log.levels.WARN)
    return
  end

  local target = pick_target(mbwin)
  vim.api.nvim_set_current_win(target)
  if rec.bufnr and vim.api.nvim_buf_is_valid(rec.bufnr) then
    vim.api.nvim_set_current_buf(rec.bufnr)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(rec.filename))
  end
  pcall(vim.api.nvim_win_set_cursor, target, { rec.lnum, math.max((rec.col or 1) - 1, 0) })
  vim.cmd('normal! zz')
end

return M
