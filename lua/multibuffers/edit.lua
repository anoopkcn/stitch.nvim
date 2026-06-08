-- Write-back: on `:w`, diff each excerpt line against its cached original and
-- apply the changes to the real source files.
--
-- v0.2 contract is strict 1:1 line mapping:
--   * editing the text of an existing excerpt line is written back
--   * deleting an excerpt line (its anchor extmark invalidates) is ignored
--   * lines you insert (no anchor extmark) are ignored
-- A source line that changed underneath us since render is never clobbered: the
-- excerpt is flagged inline and skipped.
local render = require('multibuffers.render')

local M = {}

-- Inline warnings for skipped excerpts; cleared and rebuilt on every save.
local warn_ns = vim.api.nvim_create_namespace('multibuffers_warn')

vim.api.nvim_set_hl(0, 'MultibuffersDivergent', { link = 'WarningMsg', default = true })

-- Load (without focusing) the buffer backing `filename`. apply_text_edits needs
-- a loaded buffer; loading an unloaded file also reads its current on-disk state
-- so the divergence guard sees external changes.
local function ensure_loaded(filename, bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      vim.fn.bufload(bufnr)
    end
    return bufnr
  end
  local b = vim.fn.bufadd(filename)
  vim.fn.bufload(b)
  return b
end

local function flag(buf, row, message)
  vim.api.nvim_buf_set_extmark(buf, warn_ns, row, 0, {
    virt_text = { { '  ‹ ' .. message .. ' ›', 'MultibuffersDivergent' } },
    virt_text_pos = 'eol',
  })
end

--- Handle `:w` on a multibuffer view.
function M.save(buf)
  local st = render.state[buf]
  if not st then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, warn_ns, 0, -1)

  -- Collect edited excerpt lines, grouped by source file. Anchor extmarks are
  -- read with their *current* row, so edits are picked up wherever the line
  -- moved to.
  local changes = {} -- filename -> { bufnr, edits = { {lnum, original, newtext, row, rec} } }
  local order = {}
  local deleted = 0

  local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local id, row, details = m[1], m[2], m[4]
    local rec = st.marks[id]
    if rec then
      if details.invalid then
        deleted = deleted + 1
      else
        local cur = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        if cur ~= nil and cur ~= rec.source then
          local c = changes[rec.filename]
          if not c then
            c = { bufnr = rec.bufnr, edits = {} }
            changes[rec.filename] = c
            order[#order + 1] = rec.filename
          end
          c.edits[#c.edits + 1] =
            { lnum = rec.lnum, original = rec.source, newtext = cur, row = row, rec = rec }
        end
      end
    end
  end

  local files_written, lines_written, diverged = 0, 0, 0

  for _, filename in ipairs(order) do
    local c = changes[filename]
    local sbuf = ensure_loaded(filename, c.bufnr)
    local text_edits = {}
    local applied = {}

    for _, e in ipairs(c.edits) do
      local src = vim.api.nvim_buf_get_lines(sbuf, e.lnum - 1, e.lnum, false)[1]
      if src ~= nil and src == e.original then
        text_edits[#text_edits + 1] = {
          range = {
            ['start'] = { line = e.lnum - 1, character = 0 },
            ['end'] = { line = e.lnum - 1, character = #e.original },
          },
          newText = e.newtext,
        }
        applied[#applied + 1] = e
      else
        diverged = diverged + 1
        flag(buf, e.row, 'source changed — not written')
      end
    end

    if #text_edits > 0 then
      -- offset_encoding 'utf-8' => range.character is a byte index, matching our
      -- use of #original (byte length) for the line-end column.
      vim.lsp.util.apply_text_edits(text_edits, sbuf, 'utf-8')
      vim.api.nvim_buf_call(sbuf, function()
        vim.cmd('silent keepjumps update')
      end)
      files_written = files_written + 1
      lines_written = lines_written + #text_edits
      -- Cached originals now match disk, so a second `:w` is a no-op.
      for _, e in ipairs(applied) do
        e.rec.source = e.newtext
      end
    end
  end

  vim.bo[buf].modified = false

  local msg = string.format('multibuffers: wrote %d line(s) in %d file(s)', lines_written, files_written)
  local level = vim.log.levels.INFO
  local notes = {}
  if diverged > 0 then
    notes[#notes + 1] = diverged .. ' skipped (source changed)'
    level = vim.log.levels.WARN
  end
  if deleted > 0 then
    notes[#notes + 1] = deleted .. ' deleted excerpt(s) ignored'
    level = vim.log.levels.WARN
  end
  if #notes > 0 then
    msg = msg .. ' — ' .. table.concat(notes, ', ')
  end
  vim.notify(msg, level)
end

return M
