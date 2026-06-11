-- Reproduction: do line edits (yyp/yyP/o/O/p) at stitch boundaries cross into
-- the wrong file/block on save?
-- Run: nvim --headless -u NONE -l tests/boundary_repro.lua
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

-- Simulate live editing: move the cursor (fires CursorMoved), run normal-mode
-- keys (fires TextChanged + CursorMoved afterwards), per the headless caveat
-- that feedkeys alone does not fire these autocmds.
local function go(buf, row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end
local function norm(buf, keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end

-- Fresh two-file view: rows 1=spacer, 2..4 = A src 2..4, 5..7 = B src 2..4.
local n = 0
local function two_file_view()
  n = n + 1
  local fa = mkfile(('a%d.txt'):format(n), 'A')
  local fb = mkfile(('b%d.txt'):format(n), 'B')
  local src = model.from_items({
    { filename = fa, lnum = 3, col = 1, text = 'x' },
    { filename = fb, lnum = 3, col = 1, text = 'x' },
  }, 'test')
  local buf = render.open(src)
  return buf, fa, fb
end

-- Fresh one-file two-block view: rows 1=spacer, 2..4 = src 2..4, 5..7 = src 8..10.
local function two_block_view()
  n = n + 1
  local f = mkfile(('c%d.txt'):format(n), 'C')
  local src = model.from_items({
    { filename = f, lnum = 3, col = 1, text = 'x' },
    { filename = f, lnum = 9, col = 1, text = 'x' },
  }, 'test')
  local buf = render.open(src)
  return buf, f
end

------------------------------------------------------------------
-- File boundary (between row 4 = A:4 and row 5 = B:2)
------------------------------------------------------------------

-- S1: yyp on the last line of A's stitch → the copy belongs to file A.
local buf, fa, fb = two_file_view()
go(buf, 4)
norm(buf, 'yyp')
edit.save(buf)
local da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S1 yyp last line of A stays in A',
  #da == 13 and da[5] == 'A line 4' and #db == 12,
  { a4 = da[4], a5 = da[5], lenA = #da, b1 = db[1], b2 = db[2], lenB = #db })

-- S2: yyP on the first line of B's stitch → the copy belongs to file B.
buf, fa, fb = two_file_view()
go(buf, 5)
norm(buf, 'yyP')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S2 yyP first line of B stays in B',
  #db == 13 and db[2] == 'B line 2' and db[3] == 'B line 2' and #da == 12,
  { lenA = #da, a12 = da[12], b1 = db[1], b2 = db[2], b3 = db[3], lenB = #db })

-- S3: o on the last line of A's stitch → new line appends to A.
buf, fa, fb = two_file_view()
go(buf, 4)
norm(buf, 'oNEWLINE')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S3 o below last line of A goes to A',
  #da == 13 and da[5] == 'NEWLINE' and #db == 12,
  { a5 = da[5], lenA = #da, b1 = db[1], lenB = #db })

-- S4: O on the first line of B's stitch → new line prepends to B.
buf, fa, fb = two_file_view()
go(buf, 5)
norm(buf, 'ONEWLINE')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('S4 O above first line of B goes to B',
  #db == 13 and db[2] == 'NEWLINE' and #da == 12,
  { b2 = db[2], lenB = #db, lenA = #da })

-- S5: yank in A, P on B's first line → pasted line belongs to B.
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

-- S5b: yank in B, p on A's last line → pasted line belongs to A.
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

-- S5c: 2-line paste at the A/B boundary stays in A.
buf, fa, fb = two_file_view()
go(buf, 3)
norm(buf, 'yj') -- charwise; use 2yy instead
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
-- Block boundary inside one file (row 4 = src 4, row 5 = src 8)
------------------------------------------------------------------

-- S6: yyp on the last line of block 1 → inserts after source line 4.
local f
buf, f = two_block_view()
go(buf, 4)
norm(buf, 'yyp')
edit.save(buf)
local d = vim.fn.readfile(f)
check('S6 yyp last line of block 1 inserts after src 4',
  #d == 13 and d[5] == 'C line 4' and d[6] == 'C line 5' and d[9] == 'C line 8',
  { d4 = d[4], d5 = d[5], d6 = d[6], d9 = d[9], len = #d })

-- S7: yyP on the first line of block 2 → inserts before source line 8.
buf, f = two_block_view()
go(buf, 5)
norm(buf, 'yyP')
edit.save(buf)
d = vim.fn.readfile(f)
check('S7 yyP first line of block 2 inserts before src 8',
  #d == 13 and d[8] == 'C line 8' and d[9] == 'C line 8' and d[5] == 'C line 5',
  { d7 = d[7], d8 = d[8], d9 = d[9], len = #d })

-- S8: o on the last line of block 1 → inserts after source line 4.
buf, f = two_block_view()
go(buf, 4)
norm(buf, 'oNEWLINE')
edit.save(buf)
d = vim.fn.readfile(f)
check('S8 o below last line of block 1 inserts after src 4',
  #d == 13 and d[5] == 'NEWLINE' and d[9] == 'C line 8',
  { d5 = d[5], d8 = d[8], d9 = d[9], len = #d })

-- S9: O on the first line of block 2 → inserts before source line 8.
buf, f = two_block_view()
go(buf, 5)
norm(buf, 'ONEWLINE')
edit.save(buf)
d = vim.fn.readfile(f)
check('S9 O above first line of block 2 inserts before src 8',
  #d == 13 and d[8] == 'NEWLINE' and d[9] == 'C line 8',
  { d5 = d[5], d8 = d[8], d9 = d[9], len = #d })

------------------------------------------------------------------
print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
os.exit(failed == 0 and 0 or 1)
