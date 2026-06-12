-- Undo across `:w`: a clean structural save repaints with byte-identical text
-- (paint's 'advance' kind skips the rewrite), so the undo history survives the
-- save — `u` brings the change back into the view and a second `:w` reverts it
-- in the source files, mirroring the long-standing in-place-save semantics.
-- Also covers the honest dirty-check (undo past a save leaves 'modified' off
-- while the text differs from the baseline) and the no-op-save drift guard.
-- Run: tests/run.sh   (or: nvim --headless -u NONE -l tests/undo_spec.lua)
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))

local results, failed = {}, 0
local function check(name, cond, extra)
  if not cond then failed = failed + 1 end
  results[#results + 1] = (cond and 'PASS  ' or 'FAIL  ') .. name
      .. (cond and '' or ('  :: ' .. vim.inspect(extra)))
end

local notes = {}
vim.notify = function(msg)
  notes[#notes + 1] = msg
end

local config = require('stitch.config')
local model = require('stitch.model')
local render = require('stitch.render')
local context = require('stitch.context')
local edit = require('stitch.edit')

config.setup({ context = 1, window = 'current', highlight = false })

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')

local n = 0
local function mkfile()
  n = n + 1
  local path = ('%s/a%d.txt'):format(dir, n)
  local lines = {}
  for i = 1, 12 do
    lines[i] = ('A line %d'):format(i)
  end
  vim.fn.writefile(lines, path)
  return path, lines
end

-- One file, match on line 3, context 1.
-- View rows: 1 spacer, 2..4 = src 2..4.
local function view()
  local f, orig = mkfile()
  local src = model.from_items({ { filename = f, lnum = 3, col = 1, text = 'x' } }, 'test')
  return render.open(src), f, orig
end

-- Close the current undo block: consecutive script-context edits otherwise
-- merge into one. The self-assign round-trips the -123456 use-global sentinel.
local function blk(buf)
  vim.bo[buf].undolevels = vim.bo[buf].undolevels
end

-- Simulate live editing: feedkeys alone fires none of these autocmds
-- headlessly, so fire them in the measured live order (see
-- tests/edit_boundary_spec.lua).
local function go(buf, row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
end
local function norm(buf, keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
  blk(buf)
end
local function ins(buf, keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
  vim.api.nvim_exec_autocmds('TextChangedI', { buffer = buf })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
  blk(buf)
end
-- Undo/redo fire TextChanged live; no blk — there is no open block to close.
local function undo(buf)
  vim.api.nvim_feedkeys('u', 'x', false)
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
end
local function redo(buf)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-r>', true, false, true), 'x', false)
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
end

local function buflines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

------------------------------------------------------------------
-- U1: in-place save → u → :w reverts the source (existing semantics).
------------------------------------------------------------------
local buf, f, orig = view()
go(buf, 3)
ins(buf, 'cwX<Esc>')
edit.save(buf)
check('U1a in-place save wrote', vim.fn.readfile(f)[3] == 'X line 3', vim.fn.readfile(f)[3])
undo(buf)
check('U1b undo restored the view line', buflines(buf)[3] == 'A line 3', buflines(buf)[3])
edit.save(buf)
check('U1c :w after undo reverted source', vim.deep_equal(vim.fn.readfile(f), orig), vim.fn.readfile(f))

------------------------------------------------------------------
-- U2: structural insert save preserves undo history; u + :w reverts.
------------------------------------------------------------------
local opened
buf, f, orig = view()
opened = buflines(buf)
go(buf, 3)
ins(buf, 'oNEW LINE<Esc>')
local pre_save = buflines(buf)
local seq_before = vim.fn.undotree().seq_last
edit.save(buf)
check('U2a save wrote NEW LINE to source', vim.fn.readfile(f)[4] == 'NEW LINE', vim.fn.readfile(f))
check('U2b advance repaint left buffer text untouched', vim.deep_equal(buflines(buf), pre_save),
  { before = pre_save, after = buflines(buf) })
check('U2c undo history survived the save', vim.fn.undotree().seq_last == seq_before,
  { before = seq_before, after = vim.fn.undotree().seq_last })
undo(buf)
check('U2d undo removed the inserted line from the view', vim.deep_equal(buflines(buf), opened),
  buflines(buf))
edit.save(buf)
check('U2e :w after undo reverted source', vim.deep_equal(vim.fn.readfile(f), orig), vim.fn.readfile(f))

------------------------------------------------------------------
-- U3: structural delete save → u brings the line back → :w restores it.
------------------------------------------------------------------
buf, f, orig = view()
go(buf, 3)
norm(buf, 'dd')
edit.save(buf)
local d = vim.fn.readfile(f)
check('U3a dd save removed source line 3', #d == 11 and d[3] == 'A line 4', d)
undo(buf)
check('U3b undo restored the line in the view', buflines(buf)[3] == 'A line 3', buflines(buf))
edit.save(buf)
check('U3c :w after undo restored source', vim.deep_equal(vim.fn.readfile(f), orig), vim.fn.readfile(f))

------------------------------------------------------------------
-- U4: undo past a save, redo forward → :w is a no-op.
------------------------------------------------------------------
buf, f = view()
go(buf, 3)
ins(buf, 'oNEW LINE<Esc>')
edit.save(buf)
undo(buf)
redo(buf)
edit.save(buf)
check('U4a :w after redo reports no changes', notes[#notes] ~= nil and notes[#notes]:find('no changes') ~= nil,
  notes[#notes])
check('U4b source kept the change', vim.fn.readfile(f)[4] == 'NEW LINE', vim.fn.readfile(f))
check('U4c modified flag cleared', vim.bo[buf].modified == false, vim.bo[buf].modified)

------------------------------------------------------------------
-- U5: undo past a save turns 'modified' off while the text differs from the
-- baseline — expand must still see the buffer as dirty and refuse, instead of
-- silently repainting the unsaved revert away.
------------------------------------------------------------------
buf, f = view()
go(buf, 3)
ins(buf, 'oNEW LINE<Esc>')
edit.save(buf)
undo(buf)
check('U5a precondition: modified flag off after undo past save', vim.bo[buf].modified == false,
  vim.bo[buf].modified)
local before_expand = buflines(buf)
go(buf, 3)
context.expand(buf)
check('U5b expand refused while undo-dirty', vim.deep_equal(buflines(buf), before_expand),
  buflines(buf))
check('U5c warning shown', notes[#notes] ~= nil and notes[#notes]:find('before expand/collapse') ~= nil,
  notes[#notes])

------------------------------------------------------------------
-- U6: a no-op :w must not refresh the drift markers (that would mute drift
-- detection after an external source edit).
------------------------------------------------------------------
buf, f = view()
local ext = {}
for i = 1, 12 do
  ext[i] = ('A line %d'):format(i)
end
ext[2] = 'EXTERNALLY CHANGED LINE WITH A VERY DIFFERENT LENGTH'
vim.fn.writefile(ext, f)
edit.save(buf) -- no changes in the view
check('U6a no-op :w reported no changes', notes[#notes] ~= nil and notes[#notes]:find('no changes') ~= nil,
  notes[#notes])
local diverged = render.state[buf].baseline:drift()
check('U6b drift still detected after no-op :w', #diverged == 1, #diverged)

------------------------------------------------------------------
-- U7: insert-mode line split still redecorates (TextChangedI path untouched).
------------------------------------------------------------------
buf, f = view()
go(buf, 3)
ins(buf, 'oXYZ<Esc>')
check('U7 TextChangedI redecorated on line-count change',
  render.state[buf].decorated_count == vim.api.nvim_buf_line_count(buf),
  { decorated = render.state[buf].decorated_count, count = vim.api.nvim_buf_line_count(buf) })

------------------------------------------------------------------
print(table.concat(results, '\n'))
print(failed == 0 and 'ALL PASS' or (failed .. ' FAILURE(S)'))
if failed > 0 then os.exit(1) end
os.exit(0)
