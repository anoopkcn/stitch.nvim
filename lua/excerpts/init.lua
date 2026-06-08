-- excerpts.nvim — edit excerpts from many files in one view.
--
-- The quickfix list is the canonical index: every source funnels through
-- `present`, which sets the quickfix list (so `:cdo`/`:cfdo` work for bulk
-- edits) and then renders a grouped, editable excerpts view on top of it.
local M = {}

function M.setup(opts)
  require('excerpts.config').setup(opts)
end

-- Render a source model, or warn if it is empty.
local function show(model)
  if #model.files == 0 then
    vim.notify('excerpts: no results to show', vim.log.levels.WARN)
    return
  end
  require('excerpts.render').open(model)
end

-- Shared entry point for all sources.
local function present(items, title)
  -- Keep the quickfix list in sync so `:cdo`/`:cfdo` operate on the same set.
  vim.fn.setqflist({}, ' ', { items = items, title = title })
  show(require('excerpts.model').from_items(items, title))
end

--- Open an excerpts view from a project grep.
function M.grep(pattern)
  require('excerpts.sources.grep').run(pattern, present)
end

--- Open an excerpts view of all references to the symbol under the cursor.
function M.references()
  require('excerpts.sources.references').run(present)
end

--- Open an excerpts view of all project diagnostics.
function M.diagnostics()
  require('excerpts.sources.diagnostics').run(present)
end

--- Open an excerpts view from the current quickfix list.
function M.from_qflist()
  local qf = vim.fn.getqflist({ items = 1, title = 1 })
  if vim.tbl_isempty(qf.items) then
    vim.notify('excerpts: quickfix list is empty', vim.log.levels.WARN)
    return
  end
  show(require('excerpts.model').from_items(qf.items, qf.title))
end

return M
