-- Reconciliation kernel: the single place the stitch buffer is diffed against
-- the snapshot taken at paint time.
--
-- The buffer text is pure source; `st.snapshot` is what was painted and
-- `st.origin` is the source info for each painted row. Diffing the live buffer
-- against the snapshot answers both of the plugin's edit-time questions from one
-- `vim.diff` call:
--   * display — where did each *current* row come from? (`map`, used by the
--     gutter/header decoration and the Treesitter region split)
--   * write-back — what source edits do the changes imply? (`hunks`, decomposed
--     into per-file source ranges by the editor)
--
-- This module is pure: it takes line arrays and returns plain tables, touching no
-- buffer or module state, so the index walk below — historically the subtle part
-- — can be exercised directly.
local M = {}

--- Diff `current` against `snapshot` and map current rows back to their source.
--- @param snapshot string[] the painted source text (1-based)
--- @param current string[] the current buffer lines (1-based)
--- @param origin table[] origin[i] = source info for snapshot row i, or false
---        (e.g. origin[1] = false, the row-0 spacer)
--- @return table { map, hunks } where
---   map[i]  = source info for *current* row i, or false (spacer/inserted/unmapped)
---   hunks   = raw vim.diff indices: list of { start_a, count_a, start_b, count_b }
function M.compute(snapshot, current, origin)
  local hunks = vim.diff(
    table.concat(snapshot, '\n') .. '\n',
    table.concat(current, '\n') .. '\n',
    { result_type = 'indices' }
  )
  local map = {}
  local si, ci = 1, 1 -- 1-based snapshot / current positions
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- The current row where this hunk's change begins. vim.diff is asymmetric:
    -- for insert/replace start_b is the first *changed* b-row, but for a pure
    -- deletion (cb == 0) it is the last *kept* b-row (the gap follows it). Without
    -- this normalization the prefix loop under-copies by one on a deletion and the
    -- `si + ca` advance then skips the kept origin, mis-mapping the deleted line's
    -- origin onto the preceding row (wrong gutter / dropped header).
    local change_b = (cb == 0) and (sb + 1) or sb
    while ci < change_b do -- identical region before the hunk; si and ci move together
      map[ci] = origin[si] or false
      si, ci = si + 1, ci + 1
    end
    for k = 0, cb - 1 do -- changed region: top-align new rows with the old ones
      map[change_b + k] = (k < ca and origin[si + k]) or false
    end
    -- Advance the running pointer by the hunk's old-row count from wherever the
    -- identical-region loop left it. NB: si == sa only when ca > 0; for a pure
    -- insertion (ca == 0) vim.diff reports start_a as the line *after which* text
    -- is inserted, the leading loop consumes row sa, so si == sa + 1 here. That's
    -- harmless because `si + k` is never read when ca == 0 (the `k < ca` guard is
    -- false) — but the advance must be `si + ca`, not `sa + ca`. Don't "simplify"
    -- to absolute sa addressing: it breaks insertions.
    si, ci = si + ca, change_b + cb
  end
  while ci <= #current do -- identical tail
    map[ci] = origin[si] or false
    si, ci = si + 1, ci + 1
  end
  return { map = map, hunks = hunks }
end

--- Derive each row's layout role from the *live* adjacency of `rows` (rows[i] is
--- the source info for current row i, or false for the spacer / an inserted line).
--- Returns bounds[i] = { first_in_file?, is_first_file?, block_divider? } for the
--- rows that begin a file or a non-contiguous block; nil otherwise. Computed live
--- (not baked at paint) so a deletion of a file/block's first displayed line
--- promotes the new top row to carry the header/divider instead of losing it.
--- @param rows table[] info-or-false per current row (1-based)
function M.layout_bounds(rows)
  local bounds = {}
  local prev -- the previous row's source info
  for i = 1, #rows do
    local info = rows[i]
    if info and info.lnum then
      if not prev or prev.filename ~= info.filename then
        bounds[i] = { first_in_file = true, is_first_file = (prev == nil) }
      elseif info.lnum ~= prev.lnum + 1 then
        bounds[i] = { block_divider = true }
      end
      prev = info
    end
  end
  return bounds
end

return M
