-- Reproduction: diff hunk *slides* — an inserted/deleted line whose text equals
-- the adjacent line across a stitch boundary gets attributed to the wrong side.
-- Run: nvim --headless -u NONE -l tests/slide_repro.lua
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

local n = 0
local function mkfile(lines)
  n = n + 1
  local path = ('%s/f%d.txt'):format(dir, n)
  vim.fn.writefile(lines, path)
  return path
end

local function go(buf, row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end
local function norm(buf, keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end

local function lines_for(prefix, boundary)
  local t = {}
  for i = 1, 12 do t[i] = ('%s line %d'):format(prefix, i) end
  for k, v in pairs(boundary or {}) do t[k] = v end
  return t
end

-- Two files, match on line 3 of each, context 1.
-- View rows: 1 spacer, 2..4 = A src 2..4, 5..7 = B src 2..4.
local function two_file_view(a_lines, b_lines)
  local fa, fb = mkfile(a_lines), mkfile(b_lines)
  local src = model.from_items({
    { filename = fa, lnum = 3, col = 1, text = 'x' },
    { filename = fb, lnum = 3, col = 1, text = 'x' },
  }, 'test')
  return render.open(src), fa, fb
end

-- One file, matches on 3 and 9, context 1.
-- View rows: 1 spacer, 2..4 = src 2..4, 5..7 = src 8..10.
local function two_block_view(lines)
  local f = mkfile(lines)
  local src = model.from_items({
    { filename = f, lnum = 3, col = 1, text = 'x' },
    { filename = f, lnum = 9, col = 1, text = 'x' },
  }, 'test')
  return render.open(src), f
end

------------------------------------------------------------------
-- X1: yyp on A's last shown line when it equals B's first shown line.
-- The copy must land in file A (after its line 4), not in file B.
local A = lines_for('A', { [4] = 'BOUNDARY' })
local B = lines_for('B', { [2] = 'BOUNDARY' })
local buf, fa, fb = two_file_view(A, B)
go(buf, 4)
norm(buf, 'yyp')
edit.save(buf)
local da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X1 yyp of boundary-equal line stays in A',
  #da == 13 and da[4] == 'BOUNDARY' and da[5] == 'BOUNDARY' and #db == 12,
  { lenA = #da, a4 = da[4], a5 = da[5], lenB = #db, b2 = db[2], b3 = db[3] })

-- X2: yyP on B's first shown line when it equals A's last shown line.
-- The copy must land in file B, not in file A.
buf, fa, fb = two_file_view(lines_for('A', { [4] = 'BOUNDARY' }), lines_for('B', { [2] = 'BOUNDARY' }))
go(buf, 5)
norm(buf, 'yyP')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X2 yyP of boundary-equal line stays in B',
  #db == 13 and db[2] == 'BOUNDARY' and db[3] == 'BOUNDARY' and #da == 12,
  { lenA = #da, a4 = da[4], a5 = da[5], lenB = #db, b2 = db[2], b3 = db[3] })

-- X3: o below A's last shown line, typing text equal to B's first shown line.
-- Must append to A, not prepend to B.
buf, fa, fb = two_file_view(lines_for('A'), lines_for('B', { [2] = 'TYPED' }))
go(buf, 4)
norm(buf, 'oTYPED')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X3 o typing B-equal text stays in A',
  #da == 13 and da[5] == 'TYPED' and #db == 12,
  { lenA = #da, a5 = da[5], lenB = #db, b2 = db[2], b3 = db[3] })

-- X3b: blank line opened below A's last shown line when B's first shown line
-- is blank — the everyday case (o<Esc> before a blank separator line).
buf, fa, fb = two_file_view(lines_for('A'), lines_for('B', { [2] = '' }))
go(buf, 4)
norm(buf, 'o')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X3b o<Esc> blank before blank B line stays in A',
  #da == 13 and da[5] == '' and #db == 12,
  { lenA = #da, a5 = da[5], lenB = #db, b1 = db[1], b2 = db[2] })

-- X4: O above B's first shown line, typing text equal to A's last shown line.
-- Must prepend to B, not append to A.
buf, fa, fb = two_file_view(lines_for('A', { [4] = 'TYPED' }), lines_for('B'))
go(buf, 5)
norm(buf, 'OTYPED')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X4 O typing A-equal text stays in B',
  #db == 13 and db[2] == 'TYPED' and #da == 12,
  { lenA = #da, a4 = da[4], a5 = da[5], lenB = #db, b2 = db[2] })

-- X5: dd of A's last shown line when it equals B's first shown line.
-- Must delete from A, not from B.
buf, fa, fb = two_file_view(lines_for('A', { [4] = 'BOUNDARY' }), lines_for('B', { [2] = 'BOUNDARY' }))
go(buf, 4)
norm(buf, 'dd')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X5 dd of boundary-equal line deletes from A',
  #da == 11 and da[4] == 'A line 5' and #db == 12,
  { lenA = #da, a4 = da[4], lenB = #db, b2 = db[2] })

-- X6: dd of B's first shown line when it equals A's last shown line.
-- Must delete from B, not from A.
buf, fa, fb = two_file_view(lines_for('A', { [4] = 'BOUNDARY' }), lines_for('B', { [2] = 'BOUNDARY' }))
go(buf, 5)
norm(buf, 'dd')
edit.save(buf)
da, db = vim.fn.readfile(fa), vim.fn.readfile(fb)
check('X6 dd of boundary-equal line deletes from B',
  #db == 11 and db[2] == 'B line 3' and #da == 12,
  { lenA = #da, a4 = da[4], lenB = #db, b2 = db[2] })

------------------------------------------------------------------
-- Block boundary inside one file: rows 2..4 = src 2..4, 5..7 = src 8..10.

-- X7: o below block 1's last line (src 4), typing text equal to src 8.
-- Must insert at source line 5, not next to line 8.
local C = lines_for('C', { [8] = 'TYPED' })
local f
buf, f = two_block_view(C)
go(buf, 4)
norm(buf, 'oTYPED')
edit.save(buf)
local d = vim.fn.readfile(f)
check('X7 o typing block2-equal text inserts at src 5',
  #d == 13 and d[5] == 'TYPED' and d[9] == 'TYPED' and d[10] == 'C line 9',
  { d5 = d[5], d8 = d[8], d9 = d[9], d10 = d[10], len = #d })

-- X8: dd of block 1's last line when it equals block 2's first line.
-- Must delete source line 4, not line 8.
buf, f = two_block_view(lines_for('C', { [4] = 'BOUNDARY', [8] = 'BOUNDARY' }))
go(buf, 4)
norm(buf, 'dd')
edit.save(buf)
d = vim.fn.readfile(f)
check('X8 dd of block-boundary-equal line deletes src 4',
  #d == 11 and d[4] == 'C line 5' and d[7] == 'BOUNDARY',
  { d4 = d[4], d7 = d[7], d8 = d[8], len = #d })

------------------------------------------------------------------
print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
os.exit(failed == 0 and 0 or 1)
