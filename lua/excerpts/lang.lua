-- Source-file language facets, resolved from a filename and cached.
--
-- The excerpts buffer text is pure source, so its filetype is `excerpts` — it
-- tells neither native `gc` which comment syntax to use nor the highlighter which
-- Treesitter grammar to parse with. Both are derived from each excerpt's *source*
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

-- Filetype for a filename (name-based, cached). Returns the filetype or nil.
local function filetype(filename)
  if not filename then
    return nil
  end
  local ft = ft_cache[filename]
  if ft == nil then
    local m = vim.filetype.match({ filename = filename })
    ft = (m and m ~= '') and m or false
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
--- installed. The `vim.treesitter.language.add` call gates the result: a language
--- whose parser fails to load resolves to nil (and is cached so it isn't retried),
--- so callers never get a lang without a working parser.
function M.ts_lang(filename)
  local ft = filetype(filename)
  if not ft then
    return nil
  end
  local lang = lang_cache[ft]
  if lang == nil then
    lang = false
    local l = vim.treesitter.language.get_lang(ft)
    if l and pcall(vim.treesitter.language.add, l) then
      lang = l
    end
    lang_cache[ft] = lang
  end
  return lang or nil
end

return M
