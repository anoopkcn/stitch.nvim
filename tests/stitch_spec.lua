-- Headless regression suite for stitch.nvim (write-back, windows, perf).
-- Run: tests/run.sh   (or: nvim --headless -u NONE -l tests/stitch_spec.lua)
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
local edit = require('stitch.edit')

config.setup({ context = 1, window = 'current', highlight = false })

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')

local function mkfile(name, prefix)
  local path = dir .. '/' .. name
  local lines = {}
  for i = 1, 12 do lines[i] = ('%s line %d'):format(prefix, i) end
  vim.fn.writefile(lines, path)
  return path
end

local function open_view(path)
  local src = model.from_items({
    { filename = path, lnum = 3, col = 1, text = 'x' },
    { filename = path, lnum = 9, col = 1, text = 'x' },
  }, 'test')
  return render.open(src)
end
-- View layout (1-based buffer lines): 1 spacer, 2..4 = source 2..4, 5..7 = source 8..10

------------------------------------------------------------------
-- Scenario A: in-place applied edit + unmappable edit, save twice
------------------------------------------------------------------
local fileA = mkfile('a.txt', 'A')
local bufA = open_view(fileA)
vim.api.nvim_buf_set_lines(bufA, 1, 2, false, { 'A line 2 EDITED' }) -- in-place, mappable
vim.api.nvim_buf_set_lines(bufA, 3, 5, false, { 'JOINED' })          -- 2 rows -> 1 across blocks: unmappable

notes = {}
edit.save(bufA)
local diskA = vim.fn.readfile(fileA)
check('A1: in-place edit written to disk', diskA[2] == 'A line 2 EDITED', diskA)
check('A1: unmappable edit not written', diskA[4] == 'A line 4' and diskA[8] == 'A line 8', diskA)
check('A1: summary reports 1 written, 1 unmappable',
  note_matching('wrote 1 edit(s)') ~= nil and note_matching('skipped (unmappable)') ~= nil, notes)
check('A1: buffer stays modified', vim.bo[bufA].modified)

notes = {}
edit.save(bufA) -- second save: applied hunk must NOT resurface as divergence
check('A2: no spurious "source changed" on re-save', note_matching('source changed') == nil, notes)
check('A2: nothing re-written', note_matching('wrote 0 edit(s)') ~= nil, notes)

notes = {}
render.sync(bufA) -- our own write must not read as external drift
check('A3: sync sees no drift from our own write', note_matching('source changed underneath') == nil, notes)

------------------------------------------------------------------
-- Scenario B: structural insert + unmappable, then resolve & converge
------------------------------------------------------------------
local fileB = mkfile('b.txt', 'B')
local bufB = open_view(fileB)
vim.api.nvim_buf_set_lines(bufB, 2, 2, false, { 'NEW' })    -- insert between source 2 and 3
vim.api.nvim_buf_set_lines(bufB, 4, 6, false, { 'JOINED' }) -- B4,B8 -> 1 line: unmappable

notes = {}
edit.save(bufB)
local diskB = vim.fn.readfile(fileB)
check('B1: structural insert written at source line 3', diskB[3] == 'NEW' and diskB[4] == 'B line 3', diskB)
check('B1: file grew by one line', #diskB == 13, #diskB)
check('B1: summary reports 1 written, 1 unmappable',
  note_matching('wrote 1 edit(s)') ~= nil and note_matching('skipped (unmappable)') ~= nil, notes)

local stB = render.state[bufB].baseline
check('B1: origin lnums shifted below the insert',
  stB.origin[3] and stB.origin[3].lnum == 3      -- NEW
  and stB.origin[4] and stB.origin[4].lnum == 4  -- B3 shifted 3->4
  and stB.origin[5] and stB.origin[5].lnum == 5  -- B4 shifted 4->5
  and stB.origin[8] and stB.origin[8].lnum == 11, -- B10 shifted 10->11
  { o3 = stB.origin[3], o4 = stB.origin[4], o5 = stB.origin[5], o8 = stB.origin[8] })

-- Resolve the unmappable edit: restore the two joined rows.
vim.api.nvim_buf_set_lines(bufB, 4, 5, false, { 'B line 4', 'B line 8' })
notes = {}
edit.save(bufB)
check('B2: converges to a clean save', note_matching('no changes to write') ~= nil
  and note_matching('source changed') == nil and note_matching('unmappable') == nil, notes)
check('B2: buffer clean after convergence', not vim.bo[bufB].modified)

notes = {}
render.sync(bufB)
check('B3: sync clean after convergence', #notes == 0, notes)

------------------------------------------------------------------
-- Scenario C: disk write failure must not abort the save
------------------------------------------------------------------
local fileC = mkfile('c.txt', 'C')
local bufC = open_view(fileC)
vim.fn.setfperm(fileC, 'r--r--r--')
vim.api.nvim_buf_set_lines(bufC, 1, 2, false, { 'C line 2 EDITED' })

notes = {}
local ok, err = pcall(edit.save, bufC)
check('C1: save does not raise on write failure', ok, err)
check('C1: failure reported', note_matching('could not write') ~= nil
  and note_matching('failed to write') ~= nil, notes)
check('C1: disk untouched', vim.fn.readfile(fileC)[2] == 'C line 2', vim.fn.readfile(fileC))
vim.fn.setfperm(fileC, 'rw-r--r--')

------------------------------------------------------------------
-- Scenario D: plain clean saves (in-place, then structural) still work
------------------------------------------------------------------
local fileD = mkfile('d.txt', 'D')
local bufD = open_view(fileD)
vim.api.nvim_buf_set_lines(bufD, 2, 3, false, { 'D line 3 EDITED' }) -- match line, in-place
notes = {}
edit.save(bufD)
check('D1: clean in-place save writes and unmodifies',
  vim.fn.readfile(fileD)[3] == 'D line 3 EDITED' and not vim.bo[bufD].modified, notes)

vim.api.nvim_buf_set_lines(bufD, 5, 5, false, { 'D NEW' }) -- insert inside block 2 (after source 8)
notes = {}
edit.save(bufD)
local diskD = vim.fn.readfile(fileD)
check('D2: clean structural save inserts and repaints',
  diskD[9] == 'D NEW' and #diskD == 13 and not vim.bo[bufD].modified,
  { disk = diskD, notes = notes })

------------------------------------------------------------------
-- Scenario E: jump must not reuse a window showing another stitch view
------------------------------------------------------------------
config.setup({ context = 1, window = 'split', highlight = false })
local fileE = mkfile('e.txt', 'E')
local fileF = mkfile('f.txt', 'F')

vim.cmd('only')
vim.cmd('enew') -- scenario D left a stitch buffer in this window; make it a normal one
local origwin = vim.api.nvim_get_current_win()
vim.wo[origwin].number = true
local bufS1 = open_view(fileE)
local win1 = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(origwin)
local bufS2 = open_view(fileF)
local win2 = vim.api.nvim_get_current_win()

vim.api.nvim_win_set_cursor(win2, { 2, 0 })
require('stitch.nav').jump(bufS2)
local cur = vim.api.nvim_get_current_win()
check('E1: jump reuses the non-stitch window', cur == origwin, { cur = cur, origwin = origwin, win1 = win1 })
check('E1: source file shown there', vim.api.nvim_buf_get_name(0):find('f.txt', 1, true) ~= nil,
  vim.api.nvim_buf_get_name(0))
check('E1: other stitch window untouched', vim.api.nvim_win_get_buf(win1) == bufS1)

-- Close the only normal window: jump must now split a fresh one (and restore
-- the user's winopts on it), never dump the source into the other stitch view.
vim.api.nvim_win_close(origwin, false)
vim.api.nvim_set_current_win(win2)
vim.api.nvim_win_set_cursor(win2, { 3, 0 })
require('stitch.nav').jump(bufS2)
local cur2 = vim.api.nvim_get_current_win()
check('E2: a fresh window was created', cur2 ~= win1 and cur2 ~= win2, { cur2 = cur2, win1 = win1, win2 = win2 })
check('E2: other stitch window untouched', vim.api.nvim_win_get_buf(win1) == bufS1)
check('E2: forced winopts restored on the new window',
  vim.wo[cur2].statuscolumn == '' and vim.wo[cur2].number == true,
  { statuscolumn = vim.wo[cur2].statuscolumn, number = vim.wo[cur2].number })

------------------------------------------------------------------
-- Scenario F: forced winopts must not leak into global defaults
------------------------------------------------------------------
check('F1: global statuscolumn untouched after many views', vim.go.statuscolumn == '', vim.go.statuscolumn)
check('F1: global wrap untouched', vim.go.wrap == true, vim.go.wrap)
vim.cmd('tabnew')
check('F1: window in a fresh tab gets user defaults',
  vim.wo.statuscolumn == '' and vim.wo.wrap == true,
  { statuscolumn = vim.wo.statuscolumn, wrap = vim.wo.wrap })
vim.cmd('tabclose')

------------------------------------------------------------------
-- Scenario G: window='current' must restore the window on close
------------------------------------------------------------------
config.setup({ context = 1, window = 'current', highlight = false })
local fileG = mkfile('g.txt', 'G')
vim.cmd('only')
vim.cmd('enew')
local gwin = vim.api.nvim_get_current_win()
vim.api.nvim_set_option_value('number', true, { scope = 'local', win = gwin })
local bufG = open_view(fileG)
check('G1: view shows with forced opts', vim.wo[gwin].statuscolumn ~= '' and vim.wo[gwin].number == false)
render.close(bufG) -- single window: deletes the buffer in place
check('G2: window options restored after close',
  vim.wo[gwin].statuscolumn == '' and vim.wo[gwin].number == true,
  { statuscolumn = vim.wo[gwin].statuscolumn, number = vim.wo[gwin].number })

-- Switching the stitch window to another buffer must restore too.
local fileH = mkfile('h.txt', 'H')
local bufH = open_view(fileH)
vim.cmd('enew')
check('G3: window options restored after :enew away from the view',
  vim.wo[gwin].statuscolumn == '' and vim.wo[gwin].number == true,
  { statuscolumn = vim.wo[gwin].statuscolumn, number = vim.wo[gwin].number })

------------------------------------------------------------------
-- Scenario H: paint reads each source file exactly once (was twice)
------------------------------------------------------------------
config.setup({ context = 1, window = 'split', highlight = false })
local fileI = mkfile('i.txt', 'I')
local bufI = open_view(fileI)
local reads = 0
local orig_read = model.read_lines
model.read_lines = function(...)
  reads = reads + 1
  return orig_read(...)
end
render.repaint(bufI)
model.read_lines = orig_read
check('H1: repaint reads each file exactly once', reads == 1, reads)

------------------------------------------------------------------
-- Scenario I: persistent ranges — edits grow/shrink the view, never slide it
------------------------------------------------------------------
config.setup({ context = 1, window = 'split', highlight = false })
vim.cmd('only')
vim.cmd('enew')
local fileI2 = mkfile('i2.txt', 'I')
local bufI2 = open_view(fileI2) -- matches 3 & 9, context 1: src 2-4 and 8-10
local winI2 = vim.api.nvim_get_current_win()
local function buf_lines()
  return vim.api.nvim_buf_get_lines(bufI2, 0, -1, false)
end

-- Insert a line inside the first block and save: the view must GROW — the
-- displaced neighbour ('I line 4') stays visible alongside the new line.
vim.api.nvim_buf_set_lines(bufI2, 3, 3, false, { 'NEW' })
notes = {}
edit.save(bufI2)
check('I1: insert grows the block — displaced neighbour stays visible',
  vim.deep_equal(buf_lines(),
    { '', 'I line 2', 'I line 3', 'NEW', 'I line 4', 'I line 8', 'I line 9', 'I line 10' }),
  buf_lines())

-- Delete a context line and save: the view must SHRINK — the previously
-- hidden 'I line 1' must not be revealed.
vim.api.nvim_buf_set_lines(bufI2, 1, 2, false, {})
notes = {}
edit.save(bufI2)
check('I2: delete shrinks the block — no hidden line revealed',
  vim.deep_equal(buf_lines(),
    { '', 'I line 3', 'NEW', 'I line 4', 'I line 8', 'I line 9', 'I line 10' }),
  buf_lines())

-- Collapse floors at the block's matches: two steps reach the match line,
-- a third changes nothing.
local ctx = require('stitch.context')
vim.api.nvim_win_set_cursor(winI2, { 2, 0 })
ctx.collapse(bufI2)
vim.api.nvim_win_set_cursor(winI2, { 2, 0 })
ctx.collapse(bufI2)
check('I3: collapse reaches the match hull',
  vim.deep_equal(buf_lines(),
    { '', 'I line 3', 'I line 8', 'I line 9', 'I line 10' }),
  buf_lines())
vim.api.nvim_win_set_cursor(winI2, { 2, 0 })
ctx.collapse(bufI2)
check('I3: further collapse is a no-op at the hull',
  vim.deep_equal(buf_lines(),
    { '', 'I line 3', 'I line 8', 'I line 9', 'I line 10' }),
  buf_lines())

-- Expand widens the range again.
vim.api.nvim_win_set_cursor(winI2, { 2, 0 })
ctx.expand(bufI2)
check('I4: expand widens the block',
  vim.deep_equal(buf_lines(),
    { '', 'I line 1', 'I line 3', 'NEW', 'I line 8', 'I line 9', 'I line 10' }),
  buf_lines())

------------------------------------------------------------------
-- Scenario J: a substitution that also hits the row-0 spacer (e.g.
-- :%s/^/…/ over the whole buffer) must still write every real line —
-- only the spacer row is flagged, not the whole coalesced hunk
------------------------------------------------------------------
config.setup({ context = 1, window = 'current', highlight = false })
vim.cmd('only')
vim.cmd('enew')
local fileJ = mkfile('j.txt', 'J')
local bufJ = open_view(fileJ)
vim.cmd('%s/^/> /') -- one hunk covering the spacer and both blocks
notes = {}
edit.save(bufJ)
local diskJ = vim.fn.readfile(fileJ)
check('J1: all real lines written despite the spacer edit',
  diskJ[2] == '> J line 2' and diskJ[4] == '> J line 4'
  and diskJ[8] == '> J line 8' and diskJ[10] == '> J line 10',
  { disk = diskJ, notes = notes })
check('J1: hidden lines untouched', diskJ[1] == 'J line 1' and diskJ[5] == 'J line 5', diskJ)
check('J1: spacer edit reported as skipped',
  note_matching('wrote 2 edit(s)') ~= nil and note_matching('skipped (unmappable)') ~= nil, notes)
check('J1: buffer stays modified (spacer edit unsaved)', vim.bo[bufJ].modified)

-- Restoring the spacer converges to a clean no-op save.
vim.api.nvim_buf_set_lines(bufJ, 0, 1, false, { '' })
notes = {}
edit.save(bufJ)
check('J2: converges clean after restoring the spacer',
  note_matching('no changes to write') ~= nil and not vim.bo[bufJ].modified, notes)

------------------------------------------------------------------
-- Scenario K: a clean in-place save must not mute drift detection for
-- files the save didn't write (advance must move only the written
-- files' markers, not re-capture every file)
------------------------------------------------------------------
config.setup({ context = 1, window = 'current', highlight = false })
vim.cmd('only')
vim.cmd('enew')
local fileK1 = mkfile('k1.txt', 'K1')
local fileK2 = mkfile('k2.txt', 'K2')
local srcK = model.from_items({
  { filename = fileK1, lnum = 3, col = 1, text = 'x' },
  { filename = fileK2, lnum = 3, col = 1, text = 'x' },
}, 'k')
local bufK = render.open(srcK)
-- rows: 1 spacer, 2..4 = k1 2..4, 5..7 = k2 2..4
;(vim.uv or vim.loop).sleep(20) -- move k2's mtime past the captured marker
local k2lines = vim.fn.readfile(fileK2)
k2lines[2] = 'K2 line 2 DRIFTED'
vim.fn.writefile(k2lines, fileK2)
vim.api.nvim_buf_set_lines(bufK, 1, 2, false, { 'K1 line 2 EDITED' }) -- in-place, k1 only
notes = {}
edit.save(bufK)
check('K1: clean in-place save wrote k1', vim.fn.readfile(fileK1)[2] == 'K1 line 2 EDITED', notes)
notes = {}
render.sync(bufK)
check('K2: k2 drift still detected and absorbed after the save',
  vim.tbl_contains(vim.api.nvim_buf_get_lines(bufK, 0, -1, false), 'K2 line 2 DRIFTED'),
  vim.api.nvim_buf_get_lines(bufK, 0, -1, false))

------------------------------------------------------------------
-- Scenario L: relative item paths are anchored at open — a later :cd
-- must not redirect write-back (or the drift stat) to another file
------------------------------------------------------------------
local ldir = dir .. '/ldir'
vim.fn.mkdir(ldir .. '/sub', 'p')
vim.fn.writefile({ 'L1', 'L2', 'L3' }, ldir .. '/l.txt')
vim.fn.writefile({ 'L1', 'L2', 'L3' }, ldir .. '/sub/l.txt') -- decoy at the new cwd
local prev_cwd = vim.fn.getcwd()
vim.cmd('cd ' .. vim.fn.fnameescape(ldir))
local srcL = model.from_items({ { filename = 'l.txt', lnum = 2, col = 1, text = 'L2' } }, 'l')
local bufL = render.open(srcL)
vim.cmd('cd ' .. vim.fn.fnameescape(ldir .. '/sub'))
vim.api.nvim_buf_set_lines(bufL, 2, 3, false, { 'L2 EDITED' })
edit.save(bufL)
vim.cmd('cd ' .. vim.fn.fnameescape(prev_cwd))
check('L1: original file written despite :cd',
  vim.fn.readfile(ldir .. '/l.txt')[2] == 'L2 EDITED', vim.fn.readfile(ldir .. '/l.txt'))
check('L1: decoy at the new cwd untouched',
  vim.fn.readfile(ldir .. '/sub/l.txt')[2] == 'L2', vim.fn.readfile(ldir .. '/sub/l.txt'))

------------------------------------------------------------------
-- Scenario N: the row→source map stays live after undoing past a
-- structural save ('modified' reads false while the text differs
-- from the advanced baseline)
------------------------------------------------------------------
vim.cmd('only')
vim.cmd('enew')
local fileN = mkfile('n.txt', 'N')
local bufN = open_view(fileN)
vim.api.nvim_buf_set_lines(bufN, 3, 3, false, { 'N NEW' }) -- insert inside block 1
edit.save(bufN) -- clean structural save; the 'advance' repaint keeps undo
vim.cmd('normal! u') -- buffer shrinks by one row; flag may read unmodified
local mapN = render.state[bufN].baseline:map()
check('N1: map length tracks the buffer after undo past save',
  mapN ~= nil and #mapN == vim.api.nvim_buf_line_count(bufN),
  { rows = vim.api.nvim_buf_line_count(bufN), maplen = mapN and #mapN,
    modified = vim.bo[bufN].modified })

------------------------------------------------------------------
print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
if failed > 0 then os.exit(1) end
os.exit(0)
