-- The view's chrome: the ready-to-draw strings and chunk lists for everything
-- painted *around* stitch text — the source-line-number gutter cells, the
-- underlined file-header path, and the `⋮` block divider.
--
-- Pure string building: no state, no buffer access (only strdisplaywidth for
-- display-column math), so the fiddly parts — a wide glyph straddling the
-- gutter cut, `%` in a path needing statuscolumn escaping, exact padding —
-- are testable by calling these functions directly (tests/chrome_spec.lua).
-- Output references highlight groups by name only; the groups themselves are
-- defined (and re-defined on ColorScheme) by render.
local M = {}

-- Width of the line-number gutter ('%5d ' is 5 digits + a space). Also the
-- blank pad statuscol returns for rows with no source line (spacer, inserted,
-- virtual) so the gutter keeps a constant width, and the number of leading
-- path columns a file header spills into its (line-number-less) gutter.
M.GUTTER = string.rep(' ', 6)

-- The gutter cell for a block divider: the dim `⋮` aligned under the line
-- numbers (column 4, where single-digit numbers sit).
M.DIVIDER_GUTTER = '%#StitchSeparator#    ⋮ %*'

-- Take the prefix of `s` spanning the first `n` display columns, plus the rest.
-- Cuts on a character boundary, so a wide glyph that would straddle the cut goes
-- wholly to the rest (the head is then padded to width by the caller).
local function split_display(s, n)
  if vim.fn.strdisplaywidth(s) <= n then
    return s, ''
  end
  local head, used = {}, 0
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    local cw = vim.fn.strdisplaywidth(ch)
    if used + cw > n then
      break
    end
    head[#head + 1] = ch
    used = used + cw
  end
  local hs = table.concat(head)
  return hs, s:sub(#hs + 1)
end

-- Split a list of {text, hl} chunks at display column `width`. Returns the head as
-- a `statuscolumn` string (each piece `%#hl#text`, with `%` escaped), padded with
-- plain spaces to exactly `width`, plus the remaining chunks. Used to spill the
-- start of a file header into its otherwise-blank gutter so the path reads from
-- column 0. The pad resets highlighting first (`%*`) so it doesn't extend the
-- header's underline past the text.
local function split_chunks(chunks, width)
  local head, tail, used = {}, {}, 0
  for _, c in ipairs(chunks) do
    local text, hl = c[1], c[2]
    if used >= width then
      tail[#tail + 1] = c
    else
      local w = vim.fn.strdisplaywidth(text)
      if used + w <= width then
        head[#head + 1] = '%#' .. hl .. '#' .. text:gsub('%%', '%%%%')
        used = used + w
      else
        local hs, rest = split_display(text, width - used)
        head[#head + 1] = '%#' .. hl .. '#' .. hs:gsub('%%', '%%%%')
        used = used + vim.fn.strdisplaywidth(hs)
        if rest ~= '' then
          tail[#tail + 1] = { rest, hl }
        end
      end
    end
  end
  if used < width then
    head[#head + 1] = '%*' .. string.rep(' ', width - used)
  end
  return table.concat(head) .. '%*', tail
end

-- The header label chunks on the bar: the directory and file name, both dimmed.
local function header_chunks(relname)
  local dir, base = relname:match('^(.*/)([^/]+)$')
  if not dir then
    dir, base = '', relname
  end
  local chunks = {}
  if dir ~= '' then
    chunks[#chunks + 1] = { dir, 'StitchHeaderDir' }
  end
  chunks[#chunks + 1] = { base, 'StitchHeaderName' }
  return chunks
end

--- Split a file header into (gutter statuscolumn string, body virt-text
--- chunks). The first GUTTER columns of the path are drawn in the header
--- row's gutter — which carries no line number — so the path starts at the
--- left edge; the body is the remainder.
function M.header_parts(relname)
  return split_chunks(header_chunks(relname), #M.GUTTER)
end

--- The gutter cell for a source line: its number, right-aligned, blue-tinted
--- for a match line, dimmed for a context line.
function M.lnum_cell(lnum, is_match)
  local hl = is_match and 'StitchLnum' or 'StitchContextLnum'
  return string.format('%%#%s#%5d %%*', hl, lnum)
end

--- The virt_lines shown between two non-adjacent blocks of the same file. The
--- blank virt_line just reserves the row; statuscol paints the dim `⋮` in the
--- gutter (DIVIDER_GUTTER). The jump in line numbers already shows the gap's
--- size.
function M.divider_lines()
  return { { { '', 'StitchSeparator' } } }
end

return M
