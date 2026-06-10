-- Headless suite for the legacy-syntax fallback tier (syn include + line
-- regions for files without a Treesitter grammar). Run: tests/run.sh
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
vim.notify = function() end
vim.cmd('syntax on')

local results, failed = {}, 0
local function check(name, cond, extra)
  if not cond then failed = failed + 1 end
  results[#results + 1] = (cond and 'PASS  ' or 'FAIL  ') .. name
      .. (cond and '' or ('  :: ' .. vim.inspect(extra)))
end

require('stitch.config').setup({ context = 1, window = 'split', highlight = true })

-- kitty.conf: filetype resolves by path pattern, the runtime ships a regex
-- syntax file for it, and no Treesitter parser is bundled — the exact shape
-- the fallback tier exists for.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. '/kitty', 'p')
local path = dir .. '/kitty/kitty.conf'
vim.fn.writefile({
  '# Fonts',              -- 1
  'font_family Mono',     -- 2
  'bold_font auto',       -- 3
  '',                     -- 4
  '# Bell',               -- 5
  'enable_audio_bell no', -- 6
}, path)

local srclang = require('stitch.lang')
check('ts_lang: no grammar for kitty', srclang.ts_lang(path) == nil, srclang.ts_lang(path))
check('syntax_ft resolves kitty', srclang.syntax_ft(path) == 'kitty', srclang.syntax_ft(path))

local src = require('stitch.model').from_items({
  { filename = path, lnum = 2, col = 1, text = 'x' },
  { filename = path, lnum = 6, col = 1, text = 'x' },
}, 'syn')
local render = require('stitch.render')
local buf = render.open(src)
-- View rows (1-based lines): 1 spacer | 2..4 = src 1..3 | 5..6 = src 5..6.

-- Stack of syntax group names at (line, col 1) in the stitch window.
local function stack(l)
  local names = {}
  for _, id in ipairs(vim.fn.synstack(l, 1)) do
    names[#names + 1] = vim.fn.synIDattr(id, 'name')
  end
  return table.concat(names, '>')
end

check('block 1 comment row highlighted', stack(2) == 'StitchSynBlock1>kittyComment', stack(2))
check('block 1 option row highlighted', stack(3):find('kittyOption') ~= nil, stack(3))
check('block 2 gets its own region', stack(5):find('StitchSynBlock2') ~= nil, stack(5))
check('block 2 option row highlighted', stack(6):find('kittyOption') ~= nil, stack(6))

-- Insert a line inside block 1: the block splits around the unmapped row and
-- every region below shifts down one line.
vim.api.nvim_buf_set_lines(buf, 3, 3, false, { 'italic_font auto' })
render.redecorate(buf)
check('inserted row carries no region', stack(4) == '', stack(4))
check('row below the insert keeps highlighting', stack(5):find('kittyOption') ~= nil, stack(5))
check('later block shifted with the layout', stack(7):find('kittyOption') ~= nil, stack(7))

-- Save: write-back rebases, paint relays the regions over the merged block.
require('stitch.edit').save(buf)
check('after save: merged block highlighted', stack(4):find('kittyOption') ~= nil, stack(4))
check('after save: last row still highlighted', stack(7):find('kittyOption') ~= nil, stack(7))

print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
os.exit(failed == 0 and 0 or 1)
