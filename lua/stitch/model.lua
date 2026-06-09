-- Turns a flat list of quickfix-style items into a per-file "source model":
--   { title, files = { { filename, relname, bufnr, line_count,
--       match_lnums = sorted, matches = { lnum -> { col, qftext, spans } } } } }
--
-- The view then adds `ranges` to each file (ranges_from_matches): the visible
-- source spans, kept as *persistent view state*. They are created from
-- match ± context once, at open — and from then on only ever *moved*: source
-- edits shift them content-anchored (shift_file: an insertion inside a range
-- grows it, a deletion shrinks it), expand/collapse widens or narrows them.
-- They are never re-derived around the matches, so a structural edit can't
-- slide previously-visible lines out of view or surprise-reveal hidden ones.
-- `materialize` turns the ranges into displayable blocks.
local M = {}

local function read_lines(filename, bufnr)
  if bufnr and bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, filename)
  if ok then
    return lines
  end
  return {}
end

local function resolve_filename(item)
  if item.filename and item.filename ~= '' then
    return item.filename
  end
  if item.bufnr and item.bufnr > 0 then
    local name = vim.api.nvim_buf_get_name(item.bufnr)
    if name ~= '' then
      return name
    end
  end
  return nil
end

--- Sort and merge overlapping/adjacent ranges into a fresh list. Adjacent
--- ranges ({2,5} and {6,9}) merge too — their lines are contiguous, so they
--- are one block — which keeps the invariant that distinct ranges are
--- separated by at least one hidden line (range edits stay unambiguous).
function M.merge_ranges(ranges)
  table.sort(ranges, function(a, b)
    if a.s ~= b.s then
      return a.s < b.s
    end
    return a.e < b.e
  end)
  local out = {}
  for _, r in ipairs(ranges) do
    local last = out[#out]
    if last and r.s <= last.e + 1 then
      last.e = math.max(last.e, r.e)
    else
      out[#out + 1] = { s = r.s, e = r.e }
    end
  end
  return out
end

--- A file's initial visible ranges: each match expanded by `context` lines,
--- clamped to the file, merged. Called once when the view opens; from then on
--- the ranges are persistent view state, moved by shift_file and
--- expand/collapse but never re-derived from the matches.
--- @param match_lnums integer[] sorted match line numbers
--- @param context integer lines shown above/below each match
--- @param line_count integer
function M.ranges_from_matches(match_lnums, context, line_count)
  local ranges = {}
  for _, ml in ipairs(match_lnums) do
    local s = math.max(1, ml - context)
    local e = math.min(line_count, ml + context)
    if s <= e then
      ranges[#ranges + 1] = { s = s, e = e }
    end
  end
  return M.merge_ranges(ranges)
end

--- Materialize a file's visible ranges: read source and build the per-line
--- records the renderer paints.
--- @param file_src table source-model entry (with .ranges)
--- @param lines string[]|nil pre-read source lines (saves a re-read when the
---        caller also needs them, e.g. paint's drift baseline)
--- @return table[] blocks  { { lines = { {lnum,source,is_match,col,annotation,spans} } } }
function M.materialize(file_src, lines)
  lines = lines or read_lines(file_src.filename, file_src.bufnr)
  local blocks = {}
  for _, range in ipairs(file_src.ranges or {}) do
    local block_lines = {}
    -- Clamp defensively; shift_file keeps ranges within the file.
    for lnum = math.max(1, range.s), math.min(range.e, #lines) do
      local match = file_src.matches[lnum]
      local src = lines[lnum] or ''
      local annotation
      if match then
        local trimmed = vim.trim(match.qftext)
        if trimmed ~= '' and trimmed ~= vim.trim(src) then
          annotation = trimmed
        end
      end
      block_lines[#block_lines + 1] = {
        lnum = lnum,
        source = src,
        is_match = match ~= nil,
        col = match and match.col or 1,
        annotation = annotation,
        spans = match and #match.spans > 0 and match.spans or nil,
      }
    end
    if #block_lines > 0 then
      blocks[#blocks + 1] = { lines = block_lines }
    end
  end
  return blocks
end

--- Diff `old_lines` against `new_lines` and return the source edits that turn the
--- first into the second, as `shift_file` consumes them: `{ l0, oldcount, newcount }`
--- with `oldcount == 0` ⇒ pure insertion before `l0`. Used to rebase the model when
--- a source file changed underneath the view (see render.sync); the same vim.diff
--- decomposition the write-back path uses, run the other direction.
--- @param old_lines string[]
--- @param new_lines string[]
function M.diff_to_edits(old_lines, new_lines)
  local hunks = vim.diff(
    table.concat(old_lines, '\n') .. '\n',
    table.concat(new_lines, '\n') .. '\n',
    { result_type = 'indices' }
  )
  local edits = {}
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca == 0 then
      -- vim.diff reports start_a as the line *after which* text is inserted, so
      -- the insertion lands before sa + 1.
      edits[#edits + 1] = { l0 = sa + 1, oldcount = 0, newcount = cb }
    else
      edits[#edits + 1] = { l0 = sa, oldcount = ca, newcount = cb }
    end
  end
  return edits
end

-- Move one visible range through `edits` (sorted ascending, original
-- coordinates), content-anchored:
--   * an edit entirely above shifts the whole range by its net delta
--   * an insertion inside grows the range — nothing slides out of view; with
--     `grow` (our own write-back) an insertion at the range's very edge
--     (prepended at its first line, appended after its last) joins it too,
--     so a line the user opened at a block boundary stays visible. An
--     external-drift rebase passes grow=false: foreign boundary insertions
--     shift the range instead of forcing themselves into the view (interior
--     foreign insertions still show — their neighbours are visible).
--   * a replacement/deletion overlapping the range snaps the overlapped
--     endpoints to the replacement (covering all its new lines); a deletion
--     strictly inside just shrinks it — nothing hidden slides in.
-- Returns the new { s, e }, or nil when every line of the range was deleted.
-- Accumulates endpoint deltas against original coordinates (edits are
-- disjoint and ascending), so later edits never see half-shifted positions.
local function shift_range(r, edits, grow)
  local s, e = r.s, r.e -- original coordinates, compared against edit positions
  local add_s, add_e = 0, 0 -- accumulated shifts for each endpoint
  local snap_s, snap_e -- absolute overrides (already in new coordinates)
  for _, ed in ipairs(edits) do
    if ed.oldcount == 0 then
      local p = ed.l0 -- insertion lands before original line p
      local joins = grow and (p >= s and p <= e + 1) or (p > s and p <= e)
      if joins then
        add_e = add_e + ed.newcount
      elseif p <= s then
        add_s = add_s + ed.newcount
        add_e = add_e + ed.newcount
      end
    else
      local last = ed.l0 + ed.oldcount - 1
      local n = ed.newcount - ed.oldcount
      if last < s then
        add_s = add_s + n
        add_e = add_e + n
      elseif ed.l0 <= e then -- the edited region overlaps the range
        if ed.l0 <= s then
          snap_s = ed.l0 + add_s -- top overlapped: start at the replacement
        end
        if last >= e then
          snap_e = ed.l0 + add_e + ed.newcount - 1 -- bottom overlapped: cover it
        else
          add_e = add_e + n -- strictly interior: net growth/shrink
        end
      end
    end
  end
  local ns = snap_s or (s + add_s)
  local ne = snap_e or (e + add_e)
  if ne < ns then
    return nil -- the whole range was deleted
  end
  return { s = ns, e = ne }
end

--- Re-base a file's view state after its source changed. Each edit is
--- { l0, oldcount, newcount }: source lines [l0, l0+oldcount-1] (1-based) were
--- replaced by `newcount` lines (oldcount=0 ⇒ pure insertion at l0). Matches
--- on deleted lines are dropped; matches below an edit shift by the net line
--- delta. The visible ranges move content-anchored (see shift_range): an
--- insertion grows the range it lands in, a deletion shrinks it, and ranges
--- whose gap was deleted merge into one block — so what the user sees changes
--- by exactly what the edit did, never by re-centering around the matches.
--- @param file table view file (match_lnums, matches, ranges, line_count)
--- @param edits table[]
--- @param grow boolean|nil boundary insertions join their range (default
---        true, for our own write-back; drift rebases pass false)
function M.shift_file(file, edits, grow)
  if grow == nil then
    grow = true
  end
  table.sort(edits, function(a, b)
    return a.l0 < b.l0
  end)
  local function shift(lnum)
    local out = lnum
    for _, e in ipairs(edits) do
      local last = e.l0 + e.oldcount - 1
      if e.oldcount > 0 and lnum >= e.l0 and lnum <= last then
        if e.newcount == 0 then
          return nil -- the line itself was deleted
        end
        return out - (lnum - e.l0) -- snap to the edited region's new start
      elseif lnum > last then
        out = out + (e.newcount - e.oldcount)
      end
    end
    return out
  end

  local nl_list, nmatches = {}, {}
  for _, ml in ipairs(file.match_lnums) do
    local nl = shift(ml)
    -- When an edit collapses a region that held 2+ matches, they all snap to the
    -- region's new start (the shift() snap branch). Keep the first and drop the
    -- rest so match_lnums stays duplicate-free and the surviving record isn't
    -- silently overwritten last-wins.
    if nl and nmatches[nl] == nil then
      nl_list[#nl_list + 1] = nl
      nmatches[nl] = file.matches[ml]
    end
  end
  file.match_lnums = nl_list
  file.matches = nmatches

  local nranges = {}
  for _, r in ipairs(file.ranges or {}) do
    local nr = shift_range(r, edits, grow)
    if nr then
      nranges[#nranges + 1] = nr
    end
  end
  file.ranges = M.merge_ranges(nranges)

  local delta = 0
  for _, e in ipairs(edits) do
    delta = delta + (e.newcount - e.oldcount)
  end
  file.line_count = math.max(0, file.line_count + delta)
end

--- Build a per-file source model from quickfix-style items.
--- @param items table[] quickfix items ({ filename|bufnr, lnum, col, end_col, text })
--- @param title string|nil
function M.from_items(items, title)
  local by_file = {}
  local order = {}

  for _, it in ipairs(items or {}) do
    local lnum = it.lnum
    if lnum and lnum > 0 then
      local fname = resolve_filename(it)
      if fname then
        local f = by_file[fname]
        if not f then
          f = {
            filename = fname,
            relname = vim.fn.fnamemodify(fname, ':.'),
            bufnr = (it.bufnr and it.bufnr > 0) and it.bufnr or nil,
            matches = {}, -- lnum -> { col, qftext, spans }
            match_lnums = {},
          }
          by_file[fname] = f
          order[#order + 1] = fname
        end
        if not f.matches[lnum] then -- one stitch per source line
          f.matches[lnum] = { col = it.col or 1, qftext = it.text or '', spans = {} }
          f.match_lnums[#f.match_lnums + 1] = lnum
        end
        -- Accumulate the highlight span for this item. Multiple items can share a
        -- line (e.g. two matches, or two references), each contributing a span.
        local c, e = it.col, it.end_col
        local same_line = (not it.end_lnum) or (it.end_lnum == lnum)
        if c and e and e > c and same_line then
          local spans = f.matches[lnum].spans
          spans[#spans + 1] = { c - 1, e - 1 } -- 0-based byte cols, end exclusive
        end
      end
    end
  end

  local files = {}
  for _, fname in ipairs(order) do
    local f = by_file[fname]
    table.sort(f.match_lnums)
    f.line_count = #read_lines(f.filename, f.bufnr)
    if f.line_count > 0 then -- skip unreadable/empty files
      files[#files + 1] = f
    end
  end

  return { title = title or 'Stitch', files = files }
end

-- The current source of a file, buffer-first (so unsaved buffer edits are seen),
-- disk otherwise. Exposed for render.sync's divergence check / rebase.
M.read_lines = read_lines

return M
