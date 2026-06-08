-- Renders a model into a dedicated, read-only buffer:
--   * one real line per excerpt (the source line text)
--   * file headers as virt_lines (zero bytes, not editable)
--   * source line number shown inline (virt_text)
--   * quickfix annotation (e.g. diagnostic message) at end of line
--
-- Each excerpt line carries an "anchor" extmark whose id maps back to the
-- source {filename, bufnr, lnum}. This is the stable line address that v0.2's
-- write-back and v0.1's jump-to-source both rely on.
local config = require('multibuffers.config')

local M = {}

local ns = vim.api.nvim_create_namespace('multibuffers')

-- bufnr -> { marks = { [extmark_id] = {filename,bufnr,lnum,col,source} } }
M.state = {}

-- Namespace holding the anchor extmarks; the editor reads it to map edited
-- lines back to their source location.
M.ns = ns

local function setup_highlights()
  local set = function(name, val)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', val, { default = true }))
  end
  set('MultibuffersHeader', { link = 'Directory' })
  set('MultibuffersLnum', { link = 'LineNr' })
  set('MultibuffersAnnotation', { link = 'Comment' })
  set('MultibuffersSeparator', { link = 'NonText' })
end
setup_highlights()

local function unique_name(title)
  local base = '[Multibuffers] ' .. title
  local name = base
  local n = 1
  while vim.fn.bufexists(name) == 1 do
    n = n + 1
    name = base .. ' (' .. n .. ')'
  end
  return name
end

local function file_header(relname, is_first)
  local lines = {}
  if not is_first then
    lines[#lines + 1] = { { '', 'MultibuffersSeparator' } }
  end
  lines[#lines + 1] = { { '▌ ' .. relname, 'MultibuffersHeader' } }
  return lines
end

local function open_window(buf)
  local mode = config.options.window
  if mode == 'current' then
    vim.api.nvim_set_current_buf(buf)
  elseif mode == 'vsplit' then
    vim.cmd('botright vsplit')
    vim.api.nvim_win_set_buf(0, buf)
  elseif mode == 'tab' then
    vim.cmd('tabnew')
    vim.api.nvim_win_set_buf(0, buf)
  else -- 'split'
    vim.cmd('botright split')
    vim.api.nvim_win_set_buf(0, buf)
  end
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].list = false
  return win
end

local function set_keymaps(buf)
  local keys = config.options.keys
  local opts = { buffer = buf, nowait = true, silent = true }
  if keys.jump then
    vim.keymap.set('n', keys.jump, function()
      require('multibuffers.nav').jump(buf)
    end, opts)
  end
  if keys.close then
    vim.keymap.set('n', keys.close, function()
      M.close(buf)
    end, opts)
  end
end

--- Look up the source record for a buffer row (0-indexed).
function M.record_at(buf, row)
  local st = M.state[buf]
  if not st then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, {})
  for _, m in ipairs(marks) do
    local rec = st.marks[m[1]]
    if rec then
      return rec
    end
  end
  return nil
end

function M.close(buf)
  if vim.api.nvim_win_get_buf(0) == buf and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.cmd('close')
  else
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- Render a model into a new multibuffer view. Returns (buf, win).
function M.open(model)
  local buf = vim.api.nvim_create_buf(true, true)
  local st = { marks = {} }
  M.state[buf] = st

  -- Flatten the model into buffer lines, remembering each row's source.
  -- A leading blank line is required: Neovim does not render virt_lines placed
  -- *above* buffer line 0, so the first file header would be invisible. Reserving
  -- row 0 puts every header on a content row >= 1, where virt_lines_above renders.
  local lines = { '' }
  local infos = {}
  for fi, f in ipairs(model.files) do
    for ii, item in ipairs(f.items) do
      local row = #lines
      lines[#lines + 1] = item.source
      infos[#infos + 1] = {
        row = row,
        filename = f.filename,
        relname = f.relname,
        bufnr = f.bufnr,
        lnum = item.lnum,
        col = item.col,
        source = item.source,
        annotation = item.annotation,
        first_in_file = (ii == 1),
        is_first_file = (fi == 1),
      }
    end
  end

  -- Populate with undo disabled so a single `u` can't wipe the whole view back
  -- to an empty buffer; user edits after this point undo normally.
  vim.bo[buf].modifiable = true
  local save_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for _, info in ipairs(infos) do
    -- Anchor extmark + inline source line number. Doubles as the line address.
    local id = vim.api.nvim_buf_set_extmark(buf, ns, info.row, 0, {
      right_gravity = false,
      invalidate = true,
      virt_text = { { string.format('%5d ', info.lnum), 'MultibuffersLnum' } },
      virt_text_pos = 'inline',
    })
    st.marks[id] = {
      filename = info.filename,
      bufnr = info.bufnr,
      lnum = info.lnum,
      col = info.col,
      source = info.source,
    }

    if info.annotation then
      vim.api.nvim_buf_set_extmark(buf, ns, info.row, 0, {
        virt_text = { { '  ┊ ' .. info.annotation, 'MultibuffersAnnotation' } },
        virt_text_pos = 'eol',
      })
    end

    if info.first_in_file then
      vim.api.nvim_buf_set_extmark(buf, ns, info.row, 0, {
        virt_lines = file_header(info.relname, info.is_first_file),
        virt_lines_above = true,
      })
    end
  end

  -- 'acwrite' makes `:w` fire BufWriteCmd instead of writing a file named after
  -- the buffer; the editor module turns that into per-source-file writes.
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'multibuffers'
  pcall(vim.api.nvim_buf_set_name, buf, unique_name(model.title or 'list'))

  -- Re-enable undo from a clean slate, and treat the freshly rendered view as
  -- unmodified.
  vim.bo[buf].undolevels = save_undolevels
  vim.bo[buf].modified = false

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = function(args)
      require('multibuffers.edit').save(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      M.state[buf] = nil
    end,
  })

  local win = open_window(buf)
  set_keymaps(buf)
  -- Land on the first excerpt, not the blank spacer at row 0.
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(2, #lines), 0 })
  return buf, win
end

return M
