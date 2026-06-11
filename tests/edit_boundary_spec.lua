-- Line edits at stitch boundaries (yyp/yyP/o/O/p/dd) must stay on the side
-- the user edited — including when the edited text equals the line across the
-- boundary, where the raw vim.diff hunk slides to the wrong side (see
-- baseline.normalize_slides).
-- Run: tests/run.sh   (or: nvim --headless -u NONE -l tests/edit_boundary_spec.lua)
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))

local results, failed = {}, 0
local function check(name, cond, extra)
  if not cond then failed = failed + 1 end
  results[#results + 1] = (cond and 'PASS  ' or 'FAIL  ') .. name
      .. (cond and '' or ('  :: ' .. vim.inspect(extra)))
end

vim.notify = function() end

local config = require('stitch.config')
local model = require('stitch.model')
local render = require('stitch.render')
local edit = require('stitch.edit')
local reconcile = require('stitch.reconcile')

config.setup({ context = 1, window = 'current', highlight = false })

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')

local n = 0
local function mkfile(prefix, overrides)
  n = n + 1
  local path = ('%s/%s%d.txt'):format(dir, prefix:lower(), n)
  local lines = {}
  for i = 1, 12 do lines[i] = ('%s line %d'):format(prefix, i) end
  for k, v in pairs(overrides or {}) do lines[k] = v end
  vim.fn.writefile(lines, path)
  return path
end

-- Simulate live editing. feedkeys alone fires none of these autocmds
-- headlessly, so fire them in the measured live order: normal-mode edits fire
-- CursorMoved, then TextChanged; insert-mode edits (o/O…) fire TextChangedI
-- while inserting and CursorMoved after leaving, with no TextChanged.
local function go(buf, row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end
local function norm(buf, keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
end
local function ins(buf, keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = buf })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end

-- Two files, match on line 3 of each, context 1.
-- View rows: 1 spacer, 2..4 = A src 2..4, 5..7 = B src 2..4.
local function two_file_view(a_over, b_over)
  local fa, fb = mkfile('A', a_over), mkfile('B', b_over)
  local src = model.from_items({
    { filename = fa, lnum = 3, col = 1, text = 'x' },
    { filename = fb, lnum = 3, col = 1, text = 'x' },
  }, 'test')
  return render.open(src), fa, fb
end

-- One file, matches on 3 and 9, context 1.
-- View rows: 1 spacer, 2..4 = src 2..4, 5..7 = src 8..10.
local function two_block_view(overrides)
  local f = mkfile('C', overrides)
  local src = model.from_items({
    { filename = f, lnum = 3, col = 1, text = 'x' },
    { filename = f, lnum = 9, col = 1, text = 'x' },
  }, 'test')
  return render.open(src), f
end

------------------------------------------------------------------
-- File boundary, distinct text (between row 4 = A:4 and row 5 = B:2)
------------------------------------------------------------------

-- S1: yyp on the last line of A's stitch → the copy belongs to file A.
local buf, fa, fb = two_file_view()
go(buf, 4)
norm(buf, 'yyp')
edit.save(buf)
local da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S1 yyp last line of A stays in A',
  #da == 13 and da[5] == 'A line 4' and #db == 12,
  { a4 = da[4], a5 = da[5], lenA = #da, b2 = db[2], lenB = #db })

-- S2: yyP on the first line of B's stitch → the copy belongs to file B.
buf, fa, fb = two_file_view()
go(buf, 5)
norm(buf, 'yyP')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S2 yyP first line of B stays in B',
  #db == 13 and db[2] == 'B line 2' and db[3] == 'B line 2' and #da == 12,
  { lenA = #da, b2 = db[2], b3 = db[3], lenB = #db })

-- S3/S4: o below A's last line appends to A; O above B's first line prepends to B.
buf, fa, fb = two_file_view()
go(buf, 4)
ins(buf, 'oNEWLINE')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S3 o below last line of A goes to A',
  #da == 13 and da[5] == 'NEWLINE' and #db == 12,
  { a5 = da[5], lenA = #da, lenB = #db })

buf, fa, fb = two_file_view()
go(buf, 5)
ins(buf, 'ONEWLINE')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S4 O above first line of B goes to B',
  #db == 13 and db[2] == 'NEWLINE' and #da == 12,
  { b2 = db[2], lenB = #db, lenA = #da })

-- S5: cross-file pastes follow the cursor's side.
buf, fa, fb = two_file_view()
go(buf, 3)
norm(buf, 'yy')
go(buf, 5)
norm(buf, 'P')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S5 P of an A-line on B first line goes to B',
  #db == 13 and db[2] == 'A line 3' and #da == 12,
  { b2 = db[2], lenB = #db, lenA = #da })

buf, fa, fb = two_file_view()
go(buf, 6)
norm(buf, 'yy')
go(buf, 4)
norm(buf, 'p')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S5b p of a B-line on A last line goes to A',
  #da == 13 and da[5] == 'B line 3' and #db == 12,
  { a5 = da[5], lenA = #da, lenB = #db })

buf, fa, fb = two_file_view()
go(buf, 3)
norm(buf, '2yy')
go(buf, 4)
norm(buf, 'p')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S5c 2-line p on A last line goes to A',
  #da == 14 and da[5] == 'A line 3' and da[6] == 'A line 4' and #db == 12,
  { a5 = da[5], a6 = da[6], lenA = #da, lenB = #db })

------------------------------------------------------------------
-- Block boundary, distinct text (row 4 = src 4, row 5 = src 8)
------------------------------------------------------------------

local f
buf, f = two_block_view()
go(buf, 4)
norm(buf, 'yyp')
edit.save(buf)
local d = vim.fn.readfile(f)
check('S6 yyp last line of block 1 inserts after src 4',
  #d == 13 and d[5] == 'C line 4' and d[6] == 'C line 5' and d[9] == 'C line 8',
  { d5 = d[5], d6 = d[6], d9 = d[9], len = #d })

buf, f = two_block_view()
go(buf, 5)
norm(buf, 'yyP')
edit.save(buf)
d = vim.fn.readfile(f)
check('S7 yyP first line of block 2 inserts before src 8',
  #d == 13 and d[8] == 'C line 8' and d[9] == 'C line 8' and d[5] == 'C line 5',
  { d8 = d[8], d9 = d[9], len = #d })

buf, f = two_block_view()
go(buf, 4)
ins(buf, 'oNEWLINE')
edit.save(buf)
d = vim.fn.readfile(f)
check('S8 o below last line of block 1 inserts after src 4',
  #d == 13 and d[5] == 'NEWLINE' and d[9] == 'C line 8',
  { d5 = d[5], d9 = d[9], len = #d })

buf, f = two_block_view()
go(buf, 5)
ins(buf, 'ONEWLINE')
edit.save(buf)
d = vim.fn.readfile(f)
check('S9 O above first line of block 2 inserts before src 8',
  #d == 13 and d[8] == 'NEWLINE' and d[9] == 'C line 8',
  { d8 = d[8], d9 = d[9], len = #d })

------------------------------------------------------------------
-- Boundary-equal text: the raw diff hunk slides across the boundary and must
-- be re-anchored to the side the user edited (baseline.normalize_slides).
------------------------------------------------------------------

-- X1: yyp on A's last shown line when it equals B's first shown line.
buf, fa, fb = two_file_view({ [4] = 'BOUNDARY' }, { [2] = 'BOUNDARY' })
go(buf, 4)
norm(buf, 'yyp')
-- Display before save: B's first line keeps its own header row — the pasted
-- line stays on A's side of the boundary.
local map = render.state[buf].baseline:map()
local bounds = reconcile.layout_bounds(map)
local b_first
for i, info in pairs(map) do
  if info and info.filename == fb and info.lnum == 2 then b_first = i end
end
check('X1 display: B header stays on B\'s real first line',
  b_first and bounds[b_first] and bounds[b_first].first_in_file or false,
  { b_first = b_first, bounds = bounds })
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X1 yyp of boundary-equal line stays in A',
  #da == 13 and da[4] == 'BOUNDARY' and da[5] == 'BOUNDARY' and #db == 12,
  { lenA = #da, a4 = da[4], a5 = da[5], lenB = #db, b2 = db[2], b3 = db[3] })

-- X2: yyP on B's first shown line when it equals A's last shown line.
buf, fa, fb = two_file_view({ [4] = 'BOUNDARY' }, { [2] = 'BOUNDARY' })
go(buf, 5)
norm(buf, 'yyP')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X2 yyP of boundary-equal line stays in B',
  #db == 13 and db[2] == 'BOUNDARY' and db[3] == 'BOUNDARY' and #da == 12,
  { lenA = #da, lenB = #db, b2 = db[2], b3 = db[3] })

-- X3: o below A's last shown line, typing text equal to B's first shown line.
buf, fa, fb = two_file_view(nil, { [2] = 'TYPED' })
go(buf, 4)
ins(buf, 'oTYPED')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X3 o typing B-equal text stays in A',
  #da == 13 and da[5] == 'TYPED' and #db == 12,
  { lenA = #da, a5 = da[5], lenB = #db, b2 = db[2] })

-- X3b: blank line opened below A's last shown line when B's first shown line
-- is blank — the everyday case (o<Esc> before a blank separator line).
buf, fa, fb = two_file_view(nil, { [2] = '' })
go(buf, 4)
ins(buf, 'o')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X3b o<Esc> blank before blank B line stays in A',
  #da == 13 and da[5] == '' and #db == 12,
  { lenA = #da, a5 = da[5], lenB = #db, b2 = db[2] })

-- X4: O above B's first shown line, typing text equal to A's last shown line.
buf, fa, fb = two_file_view({ [4] = 'TYPED' }, nil)
go(buf, 5)
ins(buf, 'OTYPED')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X4 O typing A-equal text stays in B',
  #db == 13 and db[2] == 'TYPED' and #da == 12,
  { lenA = #da, lenB = #db, b2 = db[2] })

-- X5/X6: dd of a boundary-equal line deletes from the side the cursor was on.
buf, fa, fb = two_file_view({ [4] = 'BOUNDARY' }, { [2] = 'BOUNDARY' })
go(buf, 4)
norm(buf, 'dd')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X5 dd of boundary-equal line deletes from A',
  #da == 11 and da[4] == 'A line 5' and #db == 12,
  { lenA = #da, a4 = da[4], lenB = #db, b2 = db[2] })

buf, fa, fb = two_file_view({ [4] = 'BOUNDARY' }, { [2] = 'BOUNDARY' })
go(buf, 5)
norm(buf, 'dd')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X6 dd of boundary-equal line deletes from B',
  #db == 11 and db[2] == 'B line 3' and #da == 12,
  { lenA = #da, lenB = #db, b2 = db[2] })

-- X7: o below block 1's last line (src 4), typing text equal to src 8.
buf, f = two_block_view({ [8] = 'TYPED' })
go(buf, 4)
ins(buf, 'oTYPED')
edit.save(buf)
d = vim.fn.readfile(f)
check('X7 o typing block2-equal text inserts at src 5',
  #d == 13 and d[5] == 'TYPED' and d[9] == 'TYPED' and d[10] == 'C line 9',
  { d5 = d[5], d9 = d[9], d10 = d[10], len = #d })

-- X8: dd of block 1's last line when it equals block 2's first line.
buf, f = two_block_view({ [4] = 'BOUNDARY', [8] = 'BOUNDARY' })
go(buf, 4)
norm(buf, 'dd')
edit.save(buf)
d = vim.fn.readfile(f)
check('X8 dd of block-boundary-equal line deletes src 4',
  #d == 11 and d[4] == 'C line 5' and d[7] == 'BOUNDARY',
  { d4 = d[4], d7 = d[7], len = #d })

------------------------------------------------------------------
print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
if failed > 0 then os.exit(1) end
os.exit(0)
