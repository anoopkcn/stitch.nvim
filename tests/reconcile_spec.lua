-- Direct unit tests for the pure reconciliation kernel: block decomposition
-- (file starts, dividers, insert-splits, header promotion) and compute()'s
-- row mapping — including the documented deletion normalization.
-- Run: tests/run.sh
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))

local results, failed = {}, 0
local function check(name, cond, extra)
  if not cond then failed = failed + 1 end
  results[#results + 1] = (cond and 'PASS  ' or 'FAIL  ') .. name
      .. (cond and '' or ('  :: ' .. vim.inspect(extra)))
end

local reconcile = require('stitch.reconcile')
local function info(file, lnum)
  return { filename = file, lnum = lnum }
end

-- ---------------------------------------------------------------- blocks()
-- Two files; file 'a' shown as two non-adjacent blocks (lines 2-4 and 8-9).
local map = {
  false, -- row-0 spacer
  info('a', 2), info('a', 3), info('a', 4),
  info('a', 8), info('a', 9),
  info('b', 1), info('b', 2),
}
local bl = reconcile.blocks(map)
check('three blocks', #bl == 3, bl)
check('first block: first file, rows/lnums',
  bl[1].first_in_file and bl[1].is_first_file == true
  and bl[1].s_row == 2 and bl[1].e_row == 4 and bl[1].s_lnum == 2 and bl[1].e_lnum == 4, bl[1])
check('second block: divider (same file, lnum gap)',
  bl[2].block_divider and not bl[2].first_in_file
  and bl[2].s_row == 5 and bl[2].e_row == 6, bl[2])
check('third block: new file, not the first',
  bl[3].first_in_file and bl[3].is_first_file == false, bl[3])

local bounds = reconcile.bounds_of(bl)
check('bounds mirror the block starts',
  bounds[2] and bounds[2].first_in_file and bounds[2].is_first_file == true
  and bounds[5] and bounds[5].block_divider
  and bounds[7] and bounds[7].first_in_file and bounds[7].is_first_file == false
  and bounds[3] == nil and bounds[6] == nil, bounds)

-- Header promotion: the first file's rows all deleted from the live map — the
-- next file's block must become the first file (its header rides the spacer).
local promoted = reconcile.blocks({ false, info('b', 1), info('b', 2) })
check('deletion promotes the next block to first file',
  promoted[1].first_in_file and promoted[1].is_first_file == true, promoted)

-- An inserted row (false) splitting a contiguous run: two blocks, and the
-- second carries NO chrome — neither a header nor a divider.
local split = reconcile.blocks({ false, info('a', 2), false, info('a', 3) })
check('insert-split makes two blocks', #split == 2, split)
check('insert-split block has no chrome role',
  split[2].first_in_file == nil and split[2].block_divider == nil, split[2])

-- An inserted row across a real gap still yields a divider on the lower block.
local gap = reconcile.blocks({ false, info('a', 2), false, info('a', 9) })
check('divider survives an inserted row in the gap',
  gap[2].block_divider == true, gap[2])

-- ---------------------------------------------------------------- compute()
local snapshot = { '', 'A', 'B', 'C' }
local origin = { false, info('f', 1), info('f', 2), info('f', 3) }

-- Pure deletion: the rows after the gap must keep their identity (the
-- deletion normalization — without it, C would inherit B's origin).
local del = reconcile.compute(snapshot, { '', 'A', 'C' }, origin)
check('deletion: kept rows keep their origins',
  del.map[2] == origin[2] and del.map[3] == origin[4], del.map)

-- Pure insertion: the new row maps to false, neighbours keep identity.
local ins = reconcile.compute(snapshot, { '', 'A', 'X', 'B', 'C' }, origin)
check('insertion: new row unmapped, neighbours keep origins',
  ins.map[2] == origin[2] and ins.map[3] == false
  and ins.map[4] == origin[3] and ins.map[5] == origin[4], ins.map)

-- In-place replacement: the changed row keeps its origin (top-aligned).
local rep = reconcile.compute(snapshot, { '', 'A', 'Z', 'C' }, origin)
check('replacement: changed row keeps its origin',
  rep.map[3] == origin[3] and rep.map[4] == origin[4], rep.map)

-- Replacement growing by one row: extra row unmapped.
local grow = reconcile.compute(snapshot, { '', 'A', 'Z1', 'Z2', 'C' }, origin)
check('growing replacement: overflow row unmapped',
  grow.map[3] == origin[3] and grow.map[4] == false and grow.map[5] == origin[4], grow.map)

print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
os.exit(failed == 0 and 0 or 1)
