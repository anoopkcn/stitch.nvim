-- Headless regression suite for stitch navigation (:Stitch next / :Stitch prev).
-- Run: tests/run.sh   (or: nvim --headless -u NONE -l tests/nav_spec.lua)
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))

local results, failed = {}, 0
local function check(name, cond, extra)
  if not cond then failed = failed + 1 end
  results[#results + 1] = (cond and 'PASS  ' or 'FAIL  ') .. name
      .. (cond and '' or ('  :: ' .. vim.inspect(extra)))
end

local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end
local function note_matching(pat)
  for _, n in ipairs(notes) do
    if n.msg:find(pat, 1, true) then return n end
  end
  return nil
end

local config = require('stitch.config')
local model = require('stitch.model')
local render = require('stitch.render')
local nav = require('stitch.nav')

config.setup({ context = 1, window = 'split', highlight = false })

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')

local function mkfile(name, prefix)
  local path = dir .. '/' .. name
  local lines = {}
  for i = 1, 12 do lines[i] = ('%s line %d'):format(prefix, i) end
  vim.fn.writefile(lines, path)
  return path
end

-- Where the cursor sits: { tail of buffer name, lnum, col }.
local function at()
  return {
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'),
    vim.api.nvim_win_get_cursor(0)[1],
    vim.api.nvim_win_get_cursor(0)[2],
  }
end

------------------------------------------------------------------
-- Scenario N: walk a two-file view forward and backward, wrapping
------------------------------------------------------------------
-- Layout (1-based view lines): 1 spacer; 2-4 = a1 src 2-4 (match line 3);
-- 5-7 = a1 src 8-10 (match line 6); 8-10 = a2 src 2-4 (match line 9);
-- 11-13 = a2 src 8-10 (match line 12).
local fileN1 = mkfile('na.txt', 'N')
local fileN2 = mkfile('nb.txt', 'M')
vim.cmd('only')
vim.cmd('enew')
local origwin = vim.api.nvim_get_current_win()
local bufN = render.open(model.from_items({
  { filename = fileN1, lnum = 3, col = 4, text = 'x' },
  { filename = fileN1, lnum = 9, col = 1, text = 'x' },
  { filename = fileN2, lnum = 3, col = 1, text = 'x' },
  { filename = fileN2, lnum = 9, col = 1, text = 'x' },
}, 'navtest'))
local viewwin = vim.api.nvim_get_current_win()

nav.next() -- from the view window: first match below the initial cursor (line 2)
check('N1: next lands in the source buffer at the match line/col',
  vim.deep_equal(at(), { 'na.txt', 3, 3 }), at())
check('N1: focus left the view window', vim.api.nvim_get_current_win() ~= viewwin,
  vim.api.nvim_get_current_win())
check('N1: view cursor advanced to the stitch',
  vim.api.nvim_win_get_cursor(viewwin)[1] == 3, vim.api.nvim_win_get_cursor(viewwin))

nav.next() -- now from the source window: the visible view keeps the position
check('N2: next from the source window continues the walk',
  vim.deep_equal(at(), { 'na.txt', 9, 0 }), at())
nav.next()
check('N3: next crosses into the second file', vim.deep_equal(at(), { 'nb.txt', 3, 0 }), at())
nav.next()
check('N4: next reaches the last stitch', vim.deep_equal(at(), { 'nb.txt', 9, 0 }), at())
nav.next()
check('N5: next wraps to the first stitch', vim.deep_equal(at(), { 'na.txt', 3, 3 }), at())
nav.prev()
check('N6: prev from the first stitch wraps to the last', vim.deep_equal(at(), { 'nb.txt', 9, 0 }), at())
nav.prev()
check('N7: prev steps backward', vim.deep_equal(at(), { 'nb.txt', 3, 0 }), at())
check('N7: view cursor tracks every step',
  vim.api.nvim_win_get_cursor(viewwin)[1] == 9, vim.api.nvim_win_get_cursor(viewwin))

------------------------------------------------------------------
-- Scenario O: no stitch view visible -> warn, do nothing
------------------------------------------------------------------
vim.cmd('tabnew')
local before = at()
notes = {}
nav.next()
check('O1: warns when no view is visible in the tabpage',
  note_matching('no stitch view open') ~= nil, notes)
check('O1: cursor untouched', vim.deep_equal(at(), before), at())
vim.cmd('tabclose')

------------------------------------------------------------------
-- Scenario P: two views visible -> the most recently used one wins
------------------------------------------------------------------
local fileP1 = mkfile('pa.txt', 'P')
local fileP2 = mkfile('pb.txt', 'Q')
vim.cmd('only')
vim.cmd('enew')
local pwin = vim.api.nvim_get_current_win()
local function open_one(path)
  return render.open(model.from_items({
    { filename = path, lnum = 3, col = 1, text = 'x' },
    { filename = path, lnum = 9, col = 1, text = 'x' },
  }, 'p'))
end
local bufP1 = open_one(fileP1)
vim.api.nvim_set_current_win(pwin)
local bufP2 = open_one(fileP2)
check('P1: opening a view makes it the navigation target', render.last_view == bufP2, render.last_view)

vim.api.nvim_set_current_win(pwin)
nav.next()
check('P2: global next walks the most recent view', at()[1] == 'pb.txt', at())
render.last_view = bufP1 -- as if the user had entered the other view
nav.next()
check('P3: entering the other view redirects next to it', at()[1] == 'pa.txt', at())

------------------------------------------------------------------
-- Scenario Q: unsaved view edits shift the rows; next follows the anchors
------------------------------------------------------------------
vim.cmd('only')
vim.cmd('enew')
local fileQ = mkfile('qa.txt', 'Q')
local bufQ = open_one(fileQ)
local qwin = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(bufQ, 1, 1, false, { 'INSERTED' }) -- match rows shift down by one
vim.api.nvim_win_set_cursor(qwin, { 1, 0 })
nav.next()
check('Q1: next finds the shifted match row and still jumps to source line 3',
  vim.deep_equal(at(), { 'qa.txt', 3, 0 }), at())
check('Q1: view cursor sits on the shifted row',
  vim.api.nvim_win_get_cursor(qwin)[1] == 4, vim.api.nvim_win_get_cursor(qwin))

------------------------------------------------------------------
print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
if failed > 0 then os.exit(1) end
os.exit(0)
