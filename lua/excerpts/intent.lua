-- Insertion intent: which source file an ambiguous boundary-inserted line joins.
--
-- A line inserted exactly at a file boundary is ambiguous — `o` below file A's
-- last line and `O` above file B's first line produce the IDENTICAL buffer — so
-- the file the cursor was last on (`cursor_file`) is the only signal for which
-- file the new line joins. That decision feeds both the header layout (render's
-- decorate) and write-back (edit's plan_hunk), and the inserted line's syntax
-- (highlight's row_lang).
--
-- Each inserted row carries a tracking extmark in this module's namespace; the
-- mark's id maps (in per-buffer state) to the file it was tagged with. The mark
-- survives later edits; the whole baseline is cleared on (re)paint via reset().
local M = {}

local ns = vim.api.nvim_create_namespace('excerpts_intent')

-- buf -> { cursor_file = filename|nil, marks = { [extmark_id] = filename|false } }.
-- A mark tagged `false` means "inserted while cursor_file was unknown" — recorded
-- so the get-or-create below can find it again rather than re-tagging each pass.
M.state = {}

local function state_of(buf)
  local s = M.state[buf]
  if not s then
    s = { marks = {} }
    M.state[buf] = s
  end
  return s
end

--- Record the file under the cursor — the file an inserted line will join next.
--- Called only on real excerpt lines (see render.update_commentstring) so it
--- survives the cursor landing on a freshly-inserted (unanchored) line.
function M.note_cursor(buf, filename)
  state_of(buf).cursor_file = filename
end

--- The intent of an inserted row (0-based), get-or-create: reads the row's mark,
--- or creates one tagged with the current `cursor_file` (or `false` if unknown).
--- Returns the tagged file (string), `false`, or the freshly-recorded cursor_file
--- (which may be nil). The `~= nil` check is load-bearing: it finds a row already
--- tagged `false` and reuses it instead of creating a duplicate mark each pass.
function M.tag(buf, row)
  local s = state_of(buf)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})) do
    if s.marks[m[1]] ~= nil then
      return s.marks[m[1]]
    end
  end
  local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { right_gravity = false })
  s.marks[id] = s.cursor_file or false
  return s.cursor_file
end

--- Read-only intent of a row (0-based): the file it was tagged with, or nil. A
--- `false` tag (unknown file) reads as nil here — readers only want a usable
--- filename.
function M.at(buf, row)
  local s = M.state[buf]
  if not s then
    return nil
  end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})) do
    if s.marks[m[1]] then
      return s.marks[m[1]]
    end
  end
  return nil
end

--- Clear all pending insertion marks for a fresh baseline (called from paint:
--- every line now maps to source, so there's nothing to attribute). Preserves
--- `cursor_file` — paint doesn't move the cursor's file, only the marks.
function M.reset(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local s = M.state[buf]
  if s then
    s.marks = {}
  else
    M.state[buf] = { marks = {} }
  end
end

--- Drop a buffer's intent state entirely (called on BufWipeout).
function M.discard(buf)
  M.state[buf] = nil
end

return M
