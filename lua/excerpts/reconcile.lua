-- Reconciliation kernel: the single place the excerpts buffer is diffed against
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
    while ci < sb do -- identical region before the hunk; si and ci move together
      map[ci] = origin[si] or false
      si, ci = si + 1, ci + 1
    end
    for k = 0, cb - 1 do -- changed region: top-align new rows with the old ones
      map[sb + k] = (k < ca and origin[si + k]) or false
    end
    -- Advance the running pointer by the hunk's old-row count from wherever the
    -- identical-region loop left it. NB: si == sa only when ca > 0; for a pure
    -- insertion (ca == 0) vim.diff reports start_a as the line *after which* text
    -- is inserted, the leading loop consumes row sa, so si == sa + 1 here. That's
    -- harmless because `si + k` is never read when ca == 0 (the `k < ca` guard is
    -- false) — but the advance must be `si + ca`, not `sa + ca`. Don't "simplify"
    -- to absolute sa addressing: it breaks insertions.
    si, ci = si + ca, sb + cb
  end
  while ci <= #current do -- identical tail
    map[ci] = origin[si] or false
    si, ci = si + 1, ci + 1
  end
  return { map = map, hunks = hunks }
end

return M
