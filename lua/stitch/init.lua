-- stitch.nvim — edit stitches from many files in one view.
--
-- The quickfix list is the canonical index: every source funnels through
-- `present`, which sets the quickfix list (so `:cdo`/`:cfdo` work for bulk
-- edits) and then renders a grouped, editable stitch view on top of it.
local M = {}

function M.setup(opts)
  require('stitch.config').setup(opts)
end

-- Render a source model, or warn if it is empty.
local function show(model)
  if #model.files == 0 then
    vim.notify('stitches: no results to show', vim.log.levels.WARN)
    return
  end
  require('stitch.render').open(model)
end

-- Shared entry point for all sources.
local function present(items, title)
  -- Keep the quickfix list in sync so `:cdo`/`:cfdo` operate on the same set.
  vim.fn.setqflist({}, ' ', { items = items, title = title })
  show(require('stitch.model').from_items(items, title))
end

--- Open a stitch view from a project grep.
function M.grep(pattern)
  require('stitch.sources.grep').run(pattern, present)
end

--- Open a stitch view of all references to the symbol under the cursor.
function M.references()
  require('stitch.sources.references').run(present)
end

--- Open a stitch view of all project diagnostics.
function M.diagnostics()
  require('stitch.sources.diagnostics').run(present)
end

--- Open a stitch view of working-tree changes (git or jj). With `revspec`,
--- diff everything from that revision to the working copy.
function M.diff(revspec)
  require('stitch.sources.diff').run(revspec, present)
end

--- Jump to the next stitch in the visible view: load its source buffer and
--- land on the match's line/column. Wraps past the last stitch.
function M.next()
  require('stitch.nav').next()
end

--- Jump to the previous stitch in the visible view. Wraps past the first.
function M.prev()
  require('stitch.nav').prev()
end

--- Open a stitch view from the current quickfix list.
function M.from_qflist()
  local qf = vim.fn.getqflist({ items = 1, title = 1 })
  if vim.tbl_isempty(qf.items) then
    vim.notify('stitches: quickfix list is empty', vim.log.levels.WARN)
    return
  end
  show(require('stitch.model').from_items(qf.items, qf.title))
end

return M
