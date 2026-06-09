-- Direct unit tests for the model's persistent visible ranges: how
-- shift_file moves them through edits (content-anchored grow/shrink/shift),
-- and the initial derivation/merge. Run: tests/run.sh
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))

local results, failed = {}, 0
local function check(name, cond, extra)
  if not cond then failed = failed + 1 end
  results[#results + 1] = (cond and 'PASS  ' or 'FAIL  ') .. name
      .. (cond and '' or ('  :: ' .. vim.inspect(extra)))
end

local model = require('stitch.model')

local function file_with(ranges, matches, line_count)
  local f = { match_lnums = {}, matches = {}, ranges = {}, line_count = line_count }
  for _, r in ipairs(ranges) do
    f.ranges[#f.ranges + 1] = { s = r[1], e = r[2] }
  end
  for _, ml in ipairs(matches or {}) do
    f.match_lnums[#f.match_lnums + 1] = ml
    f.matches[ml] = { col = 1, qftext = '', spans = {} }
  end
  return f
end
local function ranges_of(f)
  local out = {}
  for _, r in ipairs(f.ranges) do
    out[#out + 1] = { r.s, r.e }
  end
  return out
end

-- Initial derivation: match ± context, clamped, merged.
check('init: derive and merge',
  vim.deep_equal(model.ranges_from_matches({ 3, 5, 20 }, 1, 21),
    { { s = 2, e = 6 }, { s = 19, e = 21 } }),
  model.ranges_from_matches({ 3, 5, 20 }, 1, 21))

-- Insertion inside a range grows it; ranges below shift.
local f = file_with({ { 4, 6 }, { 8, 10 } }, { 5, 9 }, 12)
model.shift_file(f, { { l0 = 6, oldcount = 0, newcount = 1 } })
check('insert inside grows the range',
  vim.deep_equal(ranges_of(f), { { 4, 7 }, { 9, 11 } }), ranges_of(f))
check('insert inside: matches below shift', f.match_lnums[2] == 10, f.match_lnums)
check('line_count follows', f.line_count == 13, f.line_count)

-- Our own boundary insertions join the range (replacing the old pinning).
f = file_with({ { 4, 6 } }, { 5 }, 12)
model.shift_file(f, { { l0 = 7, oldcount = 0, newcount = 1 } }) -- `o` on the last line
check('own append at the edge joins', vim.deep_equal(ranges_of(f), { { 4, 7 } }), ranges_of(f))
model.shift_file(f, { { l0 = 4, oldcount = 0, newcount = 1 } }) -- `O` on the first line
check('own prepend at the edge joins', vim.deep_equal(ranges_of(f), { { 4, 8 } }), ranges_of(f))

-- Foreign (drift) edits: boundary insertions shift instead of joining;
-- interior ones still show (their neighbours are visible).
f = file_with({ { 4, 6 } }, { 5 }, 12)
model.shift_file(f, { { l0 = 7, oldcount = 0, newcount = 2 } }, false)
check('foreign append at the edge stays hidden', vim.deep_equal(ranges_of(f), { { 4, 6 } }), ranges_of(f))
model.shift_file(f, { { l0 = 4, oldcount = 0, newcount = 1 } }, false)
check('foreign prepend at the edge shifts the range', vim.deep_equal(ranges_of(f), { { 5, 7 } }), ranges_of(f))
model.shift_file(f, { { l0 = 6, oldcount = 0, newcount = 1 } }, false)
check('foreign interior insert still shows', vim.deep_equal(ranges_of(f), { { 5, 8 } }), ranges_of(f))

-- Deletion strictly inside shrinks; nothing hidden slides in.
f = file_with({ { 4, 6 }, { 8, 10 } }, { 5, 9 }, 12)
model.shift_file(f, { { l0 = 4, oldcount = 1, newcount = 0 } })
check('deletion shrinks the range',
  vim.deep_equal(ranges_of(f), { { 4, 5 }, { 7, 9 } }), ranges_of(f))

-- Deleting the gap between two ranges merges them into one block.
f = file_with({ { 4, 6 }, { 8, 10 } }, { 5, 9 }, 12)
model.shift_file(f, { { l0 = 7, oldcount = 1, newcount = 0 } })
check('deleting the gap merges the blocks',
  vim.deep_equal(ranges_of(f), { { 4, 9 } }), ranges_of(f))

-- Deleting every line of a range drops it (and its match).
f = file_with({ { 4, 6 }, { 8, 10 } }, { 5, 9 }, 12)
model.shift_file(f, { { l0 = 4, oldcount = 3, newcount = 0 } })
check('fully deleted range is dropped',
  vim.deep_equal(ranges_of(f), { { 5, 7 } }), ranges_of(f))
check('its match is dropped too', #f.match_lnums == 1 and f.match_lnums[1] == 6, f.match_lnums)

-- A replacement overlapping a range's bottom covers all its new lines.
f = file_with({ { 4, 6 } }, { 5 }, 12)
model.shift_file(f, { { l0 = 6, oldcount = 2, newcount = 3 } })
check('overlapping replacement is covered',
  vim.deep_equal(ranges_of(f), { { 4, 8 } }), ranges_of(f))

-- Edits above a range shift it wholesale.
f = file_with({ { 8, 10 } }, { 9 }, 12)
model.shift_file(f, {
  { l0 = 2, oldcount = 0, newcount = 2 },
  { l0 = 4, oldcount = 1, newcount = 0 },
})
check('mixed edits above shift by the net delta',
  vim.deep_equal(ranges_of(f), { { 9, 11 } }), ranges_of(f))

print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
os.exit(failed == 0 and 0 or 1)
