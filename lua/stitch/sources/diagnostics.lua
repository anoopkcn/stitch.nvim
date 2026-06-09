-- Diagnostics source: collects all project diagnostics into quickfix items.
local M = {}

--- @param present fun(items: table[], title: string)
function M.run(present)
  local items = vim.diagnostic.toqflist(vim.diagnostic.get(nil))
  if vim.tbl_isempty(items) then
    vim.notify('stitches: no diagnostics', vim.log.levels.WARN)
    return
  end
  present(items, 'Diagnostics')
end

return M
