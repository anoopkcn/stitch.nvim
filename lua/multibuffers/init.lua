-- multibuffers.nvim — edit excerpts from many files in one view (v0.1: read-only)
--
-- The quickfix list is the canonical index: every source funnels through
-- `present`, which sets the quickfix list (so `:cdo`/`:cfdo` work for bulk
-- edits) and then renders a grouped, read-only multibuffer view on top of it.
local M = {}

function M.setup(opts)
  require('multibuffers.config').setup(opts)
end

-- Shared entry point for all sources.
local function present(items, title)
  -- Keep the quickfix list in sync so `:cdo`/`:cfdo` operate on the same set.
  vim.fn.setqflist({}, ' ', { items = items, title = title })
  local model = require('multibuffers.model').from_items(items, title)
  if #model.files == 0 then
    vim.notify('multibuffers: no results to show', vim.log.levels.WARN)
    return
  end
  require('multibuffers.render').open(model)
end

--- Open a multibuffer from a project grep.
function M.grep(pattern)
  require('multibuffers.sources.grep').run(pattern, present)
end

--- Open a multibuffer of all references to the symbol under the cursor.
function M.references()
  require('multibuffers.sources.references').run(present)
end

--- Open a multibuffer of all project diagnostics.
function M.diagnostics()
  require('multibuffers.sources.diagnostics').run(present)
end

--- Open a multibuffer from the current quickfix list.
function M.from_qflist()
  local qf = vim.fn.getqflist({ items = 1, title = 1 })
  if vim.tbl_isempty(qf.items) then
    vim.notify('multibuffers: quickfix list is empty', vim.log.levels.WARN)
    return
  end
  local model = require('multibuffers.model').from_items(qf.items, qf.title)
  require('multibuffers.render').open(model)
end

return M
