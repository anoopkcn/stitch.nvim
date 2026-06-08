-- Turns a flat list of quickfix-style items into a grouped model:
--   { title, files = { { filename, relname, bufnr, items = { {lnum,col,source,annotation} } } } }
--
-- The model reads the *real* source line for each item (not the quickfix `text`,
-- which for diagnostics is the message rather than the code). The original line
-- text is kept on each item so v0.2 write-back can detect source divergence.
local M = {}

-- Read all lines of a file, preferring a loaded buffer over disk.
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

--- Build a grouped model from quickfix-style items.
--- @param items table[] quickfix items ({ filename|bufnr, lnum, col, text, type })
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
            items = {},
            _seen = {},
          }
          by_file[fname] = f
          order[#order + 1] = fname
        end
        -- One excerpt per source line (dedupe multiple matches on the same line).
        if not f._seen[lnum] then
          f._seen[lnum] = true
          f.items[#f.items + 1] = {
            lnum = lnum,
            col = it.col or 1,
            qftext = it.text or '',
            type = it.type,
          }
        end
      end
    end
  end

  local files = {}
  for _, fname in ipairs(order) do
    local f = by_file[fname]
    table.sort(f.items, function(a, b)
      return a.lnum < b.lnum
    end)
    local lines = read_lines(f.filename, f.bufnr)
    for _, item in ipairs(f.items) do
      local src = lines[item.lnum] or ''
      item.source = src
      -- Show the quickfix text as an annotation only when it carries information
      -- beyond the source line itself (e.g. a diagnostic message).
      local trimmed = vim.trim(item.qftext)
      if trimmed ~= '' and trimmed ~= vim.trim(src) then
        item.annotation = trimmed
      end
    end
    f._seen = nil
    files[#files + 1] = f
  end

  return { title = title or 'Multibuffers', files = files }
end

--- Build a model from the current quickfix list.
function M.from_qflist()
  local qf = vim.fn.getqflist({ items = 1, title = 1 })
  return M.from_items(qf.items, qf.title)
end

return M
