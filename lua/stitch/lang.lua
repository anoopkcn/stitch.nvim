-- Source-file language facets, resolved from a filename and cached.
--
-- The stitch buffer text is pure source, so its filetype is `stitch` — it
-- tells neither native `gc` which comment syntax to use nor the highlighter which
-- Treesitter grammar to parse with. Both are derived from each stitch's *source*
-- filename instead. This is the single place that maps a filename to a filetype
-- (`vim.filetype.match`); the commentstring and the Treesitter language are
-- derived from that filetype.
local M = {}

-- filename -> filetype string, or false when the name resolves to no filetype.
local ft_cache = {}
-- filetype -> commentstring string ('' when none). Keyed by filetype so files of
-- the same type share one lookup.
local cs_cache = {}
-- filetype -> Treesitter lang string, or false when no grammar is available.
local lang_cache = {}

-- Filetype for a filename (cached). A loaded buffer for the file is ground
-- truth — its filetype reflects whatever set it there (ftdetect autocmds,
-- modelines, content detection, a manual :setf) — then name-based matching on
-- the absolute path (many builtin patterns are path-anchored, e.g.
-- `*/kitty/*.conf`), then content-based matching on the file's first lines.
-- Returns the filetype or nil.
local function filetype(filename)
  if not filename then
    return nil
  end
  local ft = ft_cache[filename]
  if ft == nil then
    local abs = vim.fn.fnamemodify(filename, ':p')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs then
        local bft = vim.bo[b].filetype
        ft = bft ~= '' and bft or nil
        break
      end
    end
    ft = ft or vim.filetype.match({ filename = abs })
    if not ft then
      local ok, head = pcall(vim.fn.readfile, abs, '', 64)
      if ok and #head > 0 then
        ft = vim.filetype.match({ filename = abs, contents = head })
      end
    end
    ft = (ft and ft ~= '') and ft or false
    ft_cache[filename] = ft
  end
  return ft or nil
end

--- 'commentstring' for a source file, derived from its filetype. Returns '' (a
--- string, for direct assignment to vim.bo.commentstring) when there's no
--- filetype or no commentstring for it.
function M.commentstring(filename)
  local ft = filetype(filename)
  if not ft then
    return ''
  end
  local cs = cs_cache[ft]
  if cs == nil then
    local ok, val = pcall(vim.filetype.get_option, ft, 'commentstring')
    cs = (ok and val) or ''
    cs_cache[ft] = cs
  end
  return cs
end

--- Treesitter language for a source file, or nil when its grammar isn't
--- installed. `vim.treesitter.language.add` gates the result — note it reports
--- a missing parser by *returning* nil/false, not by throwing, so its return
--- value must be checked, not just pcall'd. A highlights query must exist too:
--- a parser without one emits no captures, and the block should fall back to
--- the legacy syntax tier instead of silently claiming Treesitter coverage.
--- Failures are cached so they aren't retried.
function M.ts_lang(filename)
  local ft = filetype(filename)
  if not ft then
    return nil
  end
  local lang = lang_cache[ft]
  if lang == nil then
    lang = false
    local l = vim.treesitter.language.get_lang(ft)
    if l then
      local ok, loaded = pcall(vim.treesitter.language.add, l)
      local qok, query = pcall(vim.treesitter.query.get, l, 'highlights')
      if ok and loaded and qok and query then
        lang = l
      end
    end
    lang_cache[ft] = lang
  end
  return lang or nil
end

-- filetype -> syntax-fallback filetype, or false when Treesitter owns the
-- filetype or no syntax file exists for it.
local syn_cache = {}

--- Filetype whose legacy syntax file should highlight this source file, or
--- nil. Resolves only when the file has no usable Treesitter grammar but an
--- on-rtp syntax/<ft>.vim — the same regex highlighting its real buffer
--- would get.
function M.syntax_ft(filename)
  local ft = filetype(filename)
  if not ft or M.ts_lang(filename) then
    return nil
  end
  local s = syn_cache[ft]
  if s == nil then
    -- The ft is interpolated into a :syn command and a runtime path; only
    -- plain names qualify (composite 'a.b' filetypes have no single file).
    s = ft:match('^[%w_%-]+$') ~= nil
      and #vim.api.nvim_get_runtime_file('syntax/' .. ft .. '.vim', false) > 0
      and ft
    syn_cache[ft] = s
  end
  return s or nil
end

return M
