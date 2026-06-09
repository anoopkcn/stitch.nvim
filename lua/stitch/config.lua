-- User-facing configuration for stitch.nvim
local M = {}

M.defaults = {
  -- Where to open the stitch view.
  -- 'split' | 'vsplit' | 'tab' | 'current'
  window = 'split',

  -- Project Treesitter syntax highlighting from each source onto the stitches.
  highlight = true,

  -- Lines of surrounding source context to show above and below each match.
  -- 0 = just the match line. Context lines are editable like any stitch.
  context = 1,

  -- Lines added/removed per expand/collapse keypress (a count overrides it,
  -- e.g. `10+` adds 10 lines).
  context_step = 1,

  -- Buffer-local keymaps inside the stitch view.
  keys = {
    jump = '<CR>', -- open the source file at the line under the cursor
    close = 'q', -- close the stitch view
    expand = '+', -- show more context around the stitch under the cursor
    collapse = '-', -- show less context around the stitch under the cursor
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
