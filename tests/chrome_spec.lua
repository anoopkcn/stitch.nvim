-- Direct unit tests for the pure chrome builders (gutter cells, header bar):
-- display-width cutting around wide glyphs, statuscolumn %-escaping, exact
-- padding. Run: tests/run.sh
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))

local results, failed = {}, 0
local function check(name, cond, extra)
  if not cond then failed = failed + 1 end
  results[#results + 1] = (cond and 'PASS  ' or 'FAIL  ') .. name
      .. (cond and '' or ('  :: ' .. vim.inspect(extra)))
end

local chrome = require('stitch.chrome')

check('GUTTER is six columns', chrome.GUTTER == '      ')

-- lnum cells: right-aligned in 5 digits + space, brightness by is_match.
check('lnum_cell match', chrome.lnum_cell(12, true) == '%#StitchLnum#   12 %*',
  chrome.lnum_cell(12, true))
check('lnum_cell context', chrome.lnum_cell(7, false) == '%#StitchContextLnum#    7 %*',
  chrome.lnum_cell(7, false))

-- Header split: the first 6 display columns spill into the gutter string,
-- the rest become body chunks.
local gut, body = chrome.header_parts('a/b.lua')
check('header gutter takes the first 6 columns',
  gut == '%#StitchHeaderDir#a/%#StitchHeaderName#b.lu%*', gut)
check('header body continues where the gutter cut',
  body[1][1] == 'a' and body[1][2] == 'StitchHeaderName', body)
check('header body is just the path remainder (no pad)', #body == 1, body)

-- A path shorter than the gutter: padded with plain (non-underlined) spaces
-- to exactly 6.
local gut2 = chrome.header_parts('x.c')
check('short header padded to gutter width',
  gut2 == '%#StitchHeaderName#x.c%*   %*', gut2)

-- % in a path must be escaped in the statuscolumn string (it would otherwise
-- be parsed as a statusline item) — gutter and not the body chunks (virt_text
-- is literal).
local gut3, body3 = chrome.header_parts('x%y/file.lua')
check('percent escaped in the gutter string', gut3:find('x%%%%y/', 1, false) ~= nil, gut3)
check('percent kept literal in body chunks', vim.inspect(body3):find('%%%%') == nil, body3)

-- A wide glyph that would straddle the 6-column cut goes wholly to the body;
-- the gutter is padded to width instead.
local gut4, body4 = chrome.header_parts('a日本語x.md')
check('wide glyph never straddles the cut',
  gut4 == '%#StitchHeaderName#a日本%* %*', gut4)
check('straddling glyph starts the body', body4[1][1] == '語x.md', body4)

-- Divider chrome.
check('divider gutter cell', chrome.DIVIDER_GUTTER == '%#StitchSeparator#    ⋮ %*')
check('divider reserves one blank virt_line',
  vim.deep_equal(chrome.divider_lines(), { { { '', 'StitchSeparator' } } }))

print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
os.exit(failed == 0 and 0 or 1)
