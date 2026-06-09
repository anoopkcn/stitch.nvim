-- The view-window lifecycle: stitch forces a set of window-local options on
-- any window showing a view (no number column, no wrap, and the statuscolumn
-- that draws the source-line gutter), and this module is the single owner of
-- how those options move:
--
--   capture  — adopt() snapshots the user's real settings from the window the
--              view is opened *from*, before anything is forced. Opening a
--              view from a window that itself shows a view inherits that
--              view's snapshot, so forced options never masquerade as the
--              user's.
--   force    — claim() applies the forced set, window-locally. Scope 'local'
--              is load-bearing: `vim.wo[win][opt] = v` behaves like `:set`,
--              writing the *global* default too — one view would leak the
--              stitch gutter and nowrap into every window created afterwards.
--   reassert — the options are window-local, so they're re-forced whenever
--              the view is shown in another window (a `<C-w>s` split would
--              otherwise render with the default number column). Reasserting
--              never touches cursorline: that is inherited once at claim and
--              then the user's to toggle.
--   restore  — release() hands a window its real options back the moment it
--              stops showing the view: a window split off by a jump, the view
--              window after `:b#`/`:edit other`, and every window still
--              showing the view when it is wiped.
--
-- Nothing outside this module reads or writes the forced set or the
-- snapshots.
local M = {}

-- The options forced on a window showing a view. The statuscolumn is the
-- source-line gutter — a genuine non-text column the cursor can never enter,
-- correct even on empty/inserted lines where inline virt_text would let the
-- cursor render at screen column 0.
local FORCED = {
  number = false,
  relativenumber = false,
  signcolumn = 'no',
  wrap = false,
  foldcolumn = '0',
  list = false,
  statuscolumn = "%!v:lua.require'stitch.render'.statuscol()",
}

-- view buf -> the user's real window options (plus their cursorline), as
-- captured by adopt(). Doubles as the registry of live view buffers
-- (is_view_win); dropped on BufWipeout.
local saved = {}

local function set_local(win, opt, val)
  vim.api.nvim_set_option_value(opt, val, { scope = 'local', win = win })
end

local function force(win)
  for opt, val in pairs(FORCED) do
    set_local(win, opt, val)
  end
end

--- Is `win` showing a stitch view?
function M.is_view_win(win)
  return saved[vim.api.nvim_win_get_buf(win)] ~= nil
end

--- Restore on `win` the user's real options (the snapshot adopt() took for
--- view `buf`; without one, the global values — which at least clear the
--- stitch gutter). Explicit nil-check, not `a and b or c`: a captured `false`
--- (e.g. nowrap, nonumber) is a valid value the ternary would wrongly drop.
function M.release(win, buf)
  local s = saved[buf]
  for opt in pairs(FORCED) do
    local val = vim.go[opt]
    if s and s[opt] ~= nil then
      val = s[opt]
    end
    set_local(win, opt, val)
  end
end

--- Force the view options on `win`, first display: also inherits the user's
--- cursorline (keep it off if they keep it off). Reassertion on later
--- BufWinEnter/WinEnter goes through force() and leaves cursorline alone.
function M.claim(win, buf)
  force(win)
  local s = saved[buf]
  if s and s.cursorline ~= nil then
    set_local(win, 'cursorline', s.cursorline)
  end
end

--- Snapshot the user's real settings for view `buf` from the *current*
--- window — call before any split or buffer swap, while it still shows the
--- user's state — and wire the lifecycle autocmds. When the current window
--- shows another view (window='current' chains), its snapshot is inherited:
--- capturing its live options would record stitch's forced ones as the
--- user's.
function M.adopt(buf)
  local from_buf = vim.api.nvim_get_current_buf()
  if saved[from_buf] then
    saved[buf] = saved[from_buf]
  else
    local s = { cursorline = vim.wo.cursorline }
    for opt in pairs(FORCED) do
      s[opt] = vim.wo[opt]
    end
    saved[buf] = s
  end

  -- The forced options are window-local: reassert them whenever this buffer
  -- is displayed in a window, or a split would lose the gutter entirely.
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == buf then
        force(win)
      end
    end,
  })

  -- The user can switch the view's window to another buffer (`:b#`,
  -- `:edit file`) without wiping the view; restore that window's options as
  -- the buffer leaves it. (BufWinLeave doesn't fire while the view stays
  -- visible in another window — which keeps its forced options, correctly.)
  vim.api.nvim_create_autocmd('BufWinLeave', {
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == buf then
        M.release(win, buf)
      end
    end,
  })

  -- Hand windows still showing the view (e.g. window='current') their real
  -- options back when it is wiped: they're about to show another buffer and
  -- would otherwise keep the stitch gutter / nonumber for good.
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      for _, w in ipairs(vim.fn.win_findbuf(buf)) do
        M.release(w, buf)
      end
      saved[buf] = nil
    end,
  })
end

--- Pick a window fit for showing a source file: any non-floating window in
--- the current tab that isn't `exclude` and isn't showing a stitch view (a
--- view window carries the forced options, and a reused window is *not*
--- released, so the source would render with the stitch gutter and no
--- numbers). If none, split one off. Returns the window and whether it was
--- created — a created window inherited the view's options and must be
--- release()d once the source is shown.
function M.pick_source_win(exclude)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= exclude
        and vim.api.nvim_win_get_config(w).relative == ''
        and not M.is_view_win(w) then
      return w, false
    end
  end
  vim.cmd('aboveleft vsplit')
  return vim.api.nvim_get_current_win(), true
end

return M
