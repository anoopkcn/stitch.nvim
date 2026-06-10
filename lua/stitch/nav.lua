-- Jump from a stitch line in the stitch view to its source location, and
-- walk the view's stitches in order (:Stitch next / :Stitch prev).
local M = {}

-- Show `rec`'s source: pick a window fit for it, load the buffer (or edit the
-- file) and land the cursor on the record's line/column. Focus ends in the
-- source window.
local function goto_record(buf, rec)
  local viewwin = require('stitch.viewwin')
  -- Invoked from a normal window (e.g. :Stitch next from the source itself):
  -- stay in it. Otherwise — from the view window — pick or split one.
  local cur = vim.api.nvim_get_current_win()
  local target, created
  if vim.api.nvim_win_get_config(cur).relative == '' and not viewwin.is_view_win(cur) then
    target, created = cur, false
  else
    target, created = viewwin.pick_source_win(cur)
  end
  vim.api.nvim_set_current_win(target)
  if rec.bufnr and vim.api.nvim_buf_is_valid(rec.bufnr) then
    vim.api.nvim_set_current_buf(rec.bufnr)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(rec.filename))
  end
  -- Release after the source is shown: a window split off the stitch window
  -- inherited its forced options (no number, stitch gutter, …), and showing
  -- the stitch buffer in that split even re-triggers the reassert autocmd —
  -- so the release has to be the last word, returning the user's normal
  -- window.
  if created then
    viewwin.release(target, buf)
  end
  pcall(vim.api.nvim_win_set_cursor, target, { rec.lnum, math.max((rec.col or 1) - 1, 0) })
  vim.cmd('normal! zz')
end

function M.jump(buf)
  local mbwin = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(mbwin)[1] - 1
  local rec = require('stitch.render').record_at(buf, row)
  if not rec then
    vim.notify('stitches: no source for this line', vim.log.levels.WARN)
    return
  end
  goto_record(buf, rec)
end

-- The view next/prev navigates: the current buffer when it is itself a view,
-- otherwise a view visible in this tabpage — the most recently entered one
-- (render.last_view) when several are showing. Returns (viewbuf, viewwin) or
-- nothing.
local function find_view()
  local render = require('stitch.render')
  local cur = vim.api.nvim_get_current_buf()
  if render.state[cur] then
    return cur, vim.api.nvim_get_current_win()
  end
  local fbuf, fwin
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if render.state[b] and vim.api.nvim_win_get_config(w).relative == '' then
      if b == render.last_view then
        return b, w
      end
      if not fbuf then
        fbuf, fwin = b, w
      end
    end
  end
  return fbuf, fwin
end

-- The view's match rows (0-based, ascending), read off the anchor extmarks so
-- they are correct even mid-edit, when rows have shifted since the paint.
local function match_rows(buf)
  local render = require('stitch.render')
  local st = render.state[buf]
  local rows, last = {}, nil
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, {})) do
    local rec = st.marks[m[1]]
    if rec and rec.is_match and m[2] ~= last then
      rows[#rows + 1] = m[2]
      last = m[2]
    end
  end
  return rows
end

-- Step the view cursor to the next/previous match row (wrapping at the ends)
-- and open its source. The view cursor is the navigation position: it
-- advances with every step, so repeated invocations walk the stitches even
-- when issued from the source window.
local function advance(delta)
  local buf, win = find_view()
  if not buf then
    vim.notify('stitches: no stitch view open', vim.log.levels.WARN)
    return
  end
  local rows = match_rows(buf)
  if #rows == 0 then
    vim.notify('stitches: no stitches to navigate', vim.log.levels.WARN)
    return
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1] - 1
  local target
  if delta > 0 then
    for _, r in ipairs(rows) do
      if r > cur then
        target = r
        break
      end
    end
    target = target or rows[1] -- wrap to the first stitch
  else
    for i = #rows, 1, -1 do
      if rows[i] < cur then
        target = rows[i]
        break
      end
    end
    target = target or rows[#rows] -- wrap to the last stitch
  end
  pcall(vim.api.nvim_win_set_cursor, win, { target + 1, 0 })
  local rec = require('stitch.render').record_at(buf, target)
  if rec then -- target came from an anchor, so this only fails mid-wipe
    goto_record(buf, rec)
  end
end

--- Jump to the next stitch (wraps past the last one).
function M.next()
  advance(1)
end

--- Jump to the previous stitch (wraps past the first one).
function M.prev()
  advance(-1)
end

return M
