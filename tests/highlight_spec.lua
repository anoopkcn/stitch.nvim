-- Headless suite for the two-tier highlighter (projection + buffer-parse
-- fallback). Run: tests/run.sh
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
vim.notify = function() end

local results, failed = {}, 0
local function check(name, cond, extra)
  if not cond then failed = failed + 1 end
  results[#results + 1] = (cond and 'PASS  ' or 'FAIL  ') .. name
      .. (cond and '' or ('  :: ' .. vim.inspect(extra)))
end

require('stitch.config').setup({ context = 1, window = 'split', highlight = true })

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local path = dir .. '/x.lua'
vim.fn.writefile({
  'local function helper()', -- 1
  '  return 1',              -- 2
  'end',                     -- 3
  '',                        -- 4
  'map("n", "a", function()', -- 5  match
  '  print("a")',            -- 6
  'end)',                    -- 7
  '',                        -- 8
  'map("n", "b", function()', -- 9  match
  '  print("b")',            -- 10
  'end)',                    -- 11
}, path)

local src = require('stitch.model').from_items({
  { filename = path, lnum = 5, col = 1, text = 'x' },
  { filename = path, lnum = 9, col = 1, text = 'x' },
}, 'hl')
local buf = require('stitch.render').open(src)
-- View rows (0-based): 0 spacer | 1..3 = src 4..6 | 4..6 = src 8..10.
-- Each block ends before its function's `end)`: an incomplete fragment.

local marks
local function collect()
  marks = {}
  local orig = vim.api.nvim_buf_set_extmark
  vim.api.nvim_buf_set_extmark = function(b, ns, row, col, opts)
    if b == buf and opts and opts.ephemeral then
      marks[#marks + 1] = { row = row, col = col, hl = opts.hl_group }
      return 0
    end
    return orig(b, ns, row, col, opts)
  end
  local ok = pcall(vim.api.nvim__redraw, { flush = true })
  if not ok then
    vim.cmd('redraw!')
  end
  vim.api.nvim_buf_set_extmark = orig
end
local function has(row, col, hl_pat)
  for _, m in ipairs(marks) do
    if m.row == row and (col == nil or m.col == col) and m.hl:find(hl_pat) then
      return true
    end
  end
  return false
end

collect()
check('captures were emitted at all', #marks > 0, #marks)
check('block 1: map gets @function.call (row 2)', has(2, 0, '^@function%.call'), marks)
check('block 2: map gets @function.call (row 5)', has(5, 0, '^@function%.call'), marks)
check('block 1: function keyword captured (row 2)', has(2, nil, '^@keyword%.function'), marks)
check('block 2: function keyword captured (row 5)', has(5, nil, '^@keyword%.function'), marks)

-- Edit block 1's match line: that block falls back to buffer parsing, block 2
-- must keep its projected captures.
vim.api.nvim_buf_set_lines(buf, 2, 3, false, { 'map("n", "EDITED", function()' })
collect()
check('after edit: dirty block still emits something on row 2', has(2, nil, '^@'), marks)
check('after edit: clean block keeps @function.call (row 5)', has(5, 0, '^@function%.call'), marks)

-- Save: write-back is clean+in-place, baseline advances, block 1 becomes
-- projectable again from the updated source.
require('stitch.edit').save(buf)
collect()
check('after save: block 1 projected again with @function.call', has(2, 0, '^@function%.call'), marks)
check('after save: block 2 still highlighted', has(5, 0, '^@function%.call'), marks)

print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
os.exit(failed == 0 and 0 or 1)
