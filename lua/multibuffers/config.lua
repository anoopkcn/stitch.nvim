-- User-facing configuration for multibuffers.nvim
local M = {}

M.defaults = {
  -- Where to open the multibuffer view.
  -- 'split' | 'vsplit' | 'tab' | 'current'
  window = 'split',

  -- Buffer-local keymaps inside the multibuffer view.
  keys = {
    jump = '<CR>', -- open the source file at the line under the cursor
    close = 'q', -- close the multibuffer view
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
