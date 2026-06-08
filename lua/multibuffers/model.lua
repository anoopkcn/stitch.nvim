-- Turns a flat list of quickfix-style items into a per-file "source model":
--   { title, files = { { filename, relname, bufnr, line_count,
--       match_lnums = sorted, matches = { lnum -> { col, qftext, spans } } } } }
--
-- The source model carries no layout. `blocks_from_levels` + `materialize` turn
-- it into displayable blocks for a given per-match context level, so the view
-- can be re-laid-out interactively (expand/collapse) without re-querying.
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

--- Expand each match by its own context level, clamp to the file, and merge
--- overlapping/adjacent ranges. Returns a list of { s, e } (inclusive, 1-based).
--- @param match_lnums integer[] sorted match line numbers
--- @param levels table<integer,integer> lnum -> context level
--- @param line_count integer
function M.blocks_from_levels(match_lnums, levels, line_count)
  local ranges = {}
  for _, ml in ipairs(match_lnums) do
    local n = levels[ml] or 0
    local s = math.max(1, ml - n)
    local e = math.min(line_count, ml + n)
    if s <= e then
      ranges[#ranges + 1] = { s = s, e = e }
    end
  end
  -- match_lnums is sorted, so ranges are sorted by start.
  local blocks = {}
  for _, r in ipairs(ranges) do
    local last = blocks[#blocks]
    if last and r.s <= last.e + 1 then
      last.e = math.max(last.e, r.e)
    else
      blocks[#blocks + 1] = { s = r.s, e = r.e }
    end
  end
  return blocks
end

--- Materialize a file's blocks for the given levels: read source and build the
--- per-line records the renderer paints.
--- @param file_src table source-model entry
--- @param levels table<integer,integer>
--- @return table[] blocks  { { lines = { {lnum,source,is_match,col,annotation,spans} } } }
function M.materialize(file_src, levels)
  local lines = read_lines(file_src.filename, file_src.bufnr)
  local blocks = {}
  for _, range in ipairs(M.blocks_from_levels(file_src.match_lnums, levels, file_src.line_count)) do
    local block_lines = {}
    for lnum = range.s, range.e do
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
    blocks[#blocks + 1] = { lines = block_lines }
  end
  return blocks
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
        if not f.matches[lnum] then -- one excerpt per source line
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

  return { title = title or 'Multibuffers', files = files }
end

return M
