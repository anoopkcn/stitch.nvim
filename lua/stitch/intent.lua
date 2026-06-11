-- Insertion intent: which source line an ambiguous boundary-inserted line joins.
--
-- A line inserted where its two neighbours are not contiguous source lines is
-- ambiguous: `o` below the line above and `O` above the line below produce the
-- IDENTICAL buffer. This happens at a file boundary (end of file A, start of
-- file B) and — with context 0 — at every block boundary inside one file (a
-- match on line 10 and a match on line 20 render as adjacent rows). The source
-- line the cursor was on when the line was opened (`cursor_ref`) is the only
-- signal for which side the new line joins. That decision feeds the header
-- layout (render's decorate), write-back (edit's plan_hunk), and the inserted
-- line's syntax (highlight's row_lang).
--
-- Each inserted row carries a tracking extmark in this module's namespace; the
-- mark's id maps (in per-buffer state) to the { filename, lnum } reference it was
-- tagged with. The mark survives later edits; the whole baseline is cleared on
-- (re)paint via reset().
local M = {}

local ns = vim.api.nvim_create_namespace('stitch_intent')

-- buf -> { cursor_ref = {filename,lnum}|nil, marks = { [extmark_id] = ref|false } }.
-- A mark tagged `false` means "inserted while cursor_ref was unknown" — recorded
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

--- Record the source line under the cursor — the line an inserted row will join
--- next. `ref` is { filename, lnum }. Called only on real stitch lines (see
--- render.update_commentstring) so it survives the cursor landing on a
--- freshly-inserted (unanchored) line.
function M.note_cursor(buf, ref)
  state_of(buf).cursor_ref = ref
end

--- The intent of an inserted row (0-based), get-or-create: reads the row's mark,
--- or creates one tagged with the current `cursor_ref` (or `false` if unknown).
--- Returns the tagged reference (table), `false`, or the freshly-recorded
--- cursor_ref (which may be nil). The `~= nil` check is load-bearing: it finds a
--- row already tagged `false` and reuses it instead of creating a duplicate mark
--- each pass.
function M.tag(buf, row)
  local s = state_of(buf)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})) do
    if s.marks[m[1]] ~= nil then
      return s.marks[m[1]]
    end
  end
  local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { right_gravity = false })
  s.marks[id] = s.cursor_ref or false
  return s.cursor_ref
end

--- The source line currently under the cursor (read-only), or nil. The
--- baseline's slide normalization falls back to this on the first reconcile
--- after an edit, before any mark exists for it.
function M.cursor(buf)
  local s = M.state[buf]
  return s and s.cursor_ref or nil
end

--- First usable tagged reference on any row in [row0, row1] (0-based,
--- inclusive), or nil. A slid insertion's mark may sit at a previous tick's
--- reported position anywhere in the hunk's slide span, so readers scan the
--- whole span rather than one row.
function M.find(buf, row0, row1)
  local s = M.state[buf]
  if not s then
    return nil
  end
  row1 = math.min(row1, vim.api.nvim_buf_line_count(buf) - 1)
  if row1 < row0 then
    return nil
  end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row0, 0 }, { row1, -1 }, {})) do
    if s.marks[m[1]] then
      return s.marks[m[1]]
    end
  end
  return nil
end

--- Tag `row` (0-based) with `ref` directly, upgrading an existing mark on the
--- row rather than duplicating it. Used when the baseline re-anchors a slid
--- insertion: the chosen row must carry the resolved reference so write-back
--- (edit.plan_hunk's intent.at) and the header walk agree with the map.
function M.put(buf, row, ref)
  local s = state_of(buf)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})) do
    if s.marks[m[1]] ~= nil then
      s.marks[m[1]] = ref
      return
    end
  end
  local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { right_gravity = false })
  s.marks[id] = ref
end

--- Deletion decisions: a deleted line leaves no buffer row to carry a mark,
--- so a slid deletion's resolution is remembered against its snapshot-stable
--- key instead, locked at first sight (the only moment cursor_ref still
--- reflects where the deletion was made). `ref` may be false ("resolved:
--- intent unknown, keep the raw position") — recall returns it as stored, or
--- nil when nothing was decided for this key/gen.
function M.remember(buf, key, gen, ref)
  local s = state_of(buf)
  s.dels = s.dels or {}
  s.dels[key] = { gen = gen, ref = ref }
end

function M.recall(buf, key, gen)
  local s = M.state[buf]
  local d = s and s.dels and s.dels[key]
  if d and d.gen == gen then
    return d.ref
  end
  return nil
end

--- Read-only intent of a row (0-based): the { filename, lnum } it was tagged
--- with, or nil. A `false` tag (unknown reference) reads as nil here — readers
--- only want a usable reference.
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
--- `cursor_ref` — paint doesn't move the cursor's line, only the marks.
function M.reset(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local s = M.state[buf]
  if s then
    s.marks = {}
    s.dels = nil
  else
    M.state[buf] = { marks = {} }
  end
end

--- Drop a buffer's intent state entirely (called on BufWipeout).
function M.discard(buf)
  M.state[buf] = nil
end

return M
