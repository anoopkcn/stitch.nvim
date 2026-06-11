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
--- @param normalize? fun(hunks: table[]) optional hunk rewriter, called between
---        the diff and the map walk (the baseline re-anchors slidable hunks to
---        the side the user edited; see insert_slide/delete_slide). May mutate
---        the hunks in place; the map is built from the result.
--- @return table { map, hunks } where
---   map[i]  = source info for *current* row i, or false (spacer/inserted/unmapped)
---   hunks   = raw vim.diff indices: list of { start_a, count_a, start_b, count_b }
function M.compute(snapshot, current, origin, normalize)
  local hunks = vim.diff(
    table.concat(snapshot, '\n') .. '\n',
    table.concat(current, '\n') .. '\n',
    { result_type = 'indices' }
  )
  if normalize then
    normalize(hunks)
  end
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

-- A hunk bordered by equal lines is positionally ambiguous: inserting (or
-- deleting) `}` next to an existing `}` yields the same buffer wherever in the
-- equal run the hunk is placed, and xdiff reports it at the LOWEST valid
-- position. When the run straddles a stitch/file boundary that choice decides
-- which source file receives the edit, so the baseline re-anchors such hunks
-- by the user's recorded intent. These two helpers compute the valid range.

--- The slide range of a pure-insertion hunk {sa, 0, sb, cb}: every position
--- the inserted block can occupy while producing the identical buffer.
--- Sliding up one step is valid when the line above the block equals the
--- block's last line; down when the line below equals its first (the block
--- "rotates" through the equal run). Returns (sa_lo, sa_hi, sb_lo): the
--- inclusive range of start_a values, plus start_b at the low end (start_b for
--- position p is sb_lo + (p - sa_lo)).
function M.insert_slide(current, hunk)
  local sa, _, sb, cb = hunk[1], hunk[2], hunk[3], hunk[4]
  local sa_lo, sb_lo = sa, sb
  while sb_lo > 1 and current[sb_lo - 1] == current[sb_lo + cb - 1] do
    sa_lo, sb_lo = sa_lo - 1, sb_lo - 1
  end
  local sa_hi, sb_hi = sa, sb
  while sb_hi + cb <= #current and current[sb_hi + cb] == current[sb_hi] do
    sa_hi, sb_hi = sa_hi + 1, sb_hi + 1
  end
  return sa_lo, sa_hi, sb_lo
end

--- The slide range of a pure-deletion hunk {sa, ca, sb, 0}: every start_a the
--- deleted block can take while removing the same buffer text. Returns
--- (sa_lo, sa_hi); start_b moves with start_a by the same delta.
function M.delete_slide(snapshot, hunk)
  local sa, ca = hunk[1], hunk[2]
  local lo, hi = sa, sa
  while lo > 1 and snapshot[lo - 1] == snapshot[lo + ca - 1] do
    lo = lo - 1
  end
  while hi + ca <= #snapshot and snapshot[hi + ca] == snapshot[hi] do
    hi = hi + 1
  end
  return lo, hi
end

--- Decompose the live row→source map into blocks: maximal runs of rows that
--- are mapped, same-file, and source-contiguous (each row's lnum follows the
--- previous one's). The spacer and inserted rows (false in `map`) break a
--- run. Each block carries its start row's layout role, computed from the
--- *live* adjacency to the previous mapped row — not baked at paint — so a
--- deletion of a file/block's first displayed line promotes the next block to
--- carry the header/divider instead of losing it:
---   * first_in_file / is_first_file — the block opens a new file (the first
---     file's header rides the row-0 spacer)
---   * block_divider — same file, but its lnums don't continue the previous
---     block's (a `⋮` gap)
---   * neither — the run was merely split by an inserted row; no chrome.
--- This is the single implementation of the block concept: the renderer's
--- header/divider placement (via layout_bounds) and the highlighter's
--- projection blocks both consume it.
--- @param map table[] info-or-false per current row (1-based)
--- @return table[] blocks { s_row, e_row, filename, s_lnum, e_lnum,
---         first_in_file?, is_first_file?, block_divider? } (rows are 1-based
---         map indices: 0-based view row + 1)
function M.blocks(map)
  local blocks = {}
  local prev, cur -- previous mapped info anywhere above; the open block
  for i = 1, #map do
    local info = map[i]
    if info and info.lnum then
      if cur and cur.filename == info.filename and info.lnum == cur.e_lnum + 1 then
        cur.e_row, cur.e_lnum = i, info.lnum
      else
        cur = {
          s_row = i, e_row = i,
          filename = info.filename,
          s_lnum = info.lnum, e_lnum = info.lnum,
        }
        if not prev or prev.filename ~= info.filename then
          cur.first_in_file = true
          cur.is_first_file = (prev == nil)
        elseif info.lnum ~= prev.lnum + 1 then
          cur.block_divider = true
        end
        blocks[#blocks + 1] = cur
      end
      prev = info
    else
      cur = nil -- spacer / inserted row: breaks the run
    end
  end
  return blocks
end

--- The per-row view of blocks(): bounds[i] = { first_in_file?, is_first_file?,
--- block_divider? } for rows that begin a file or a non-contiguous block; nil
--- otherwise. What the renderer's per-row decoration walk consumes.
function M.bounds_of(blocks)
  local bounds = {}
  for _, b in ipairs(blocks) do
    if b.first_in_file then
      bounds[b.s_row] = { first_in_file = true, is_first_file = b.is_first_file }
    elseif b.block_divider then
      bounds[b.s_row] = { block_divider = true }
    end
  end
  return bounds
end

--- bounds_of(blocks(rows)) in one call, for callers that only want the
--- per-row flags.
--- @param rows table[] info-or-false per current row (1-based)
function M.layout_bounds(rows)
  return M.bounds_of(M.blocks(rows))
end

return M
