-- VCS diff source: lists changed lines from the working tree as stitches, so you
-- can review and edit all your changes in one view (edits write back like any
-- stitch).
--
-- Works with git and jujutsu: both emit a git-format unified diff
-- (`git diff` / `jj diff --git`), parsed identically. The VCS is auto-detected
-- (a `.jj` directory means jj, otherwise git). Only added/modified lines appear —
-- the view shows current-file content, so purely-removed lines have nothing to
-- display.
local M = {}

-- Build the diff argv and resolve the repo root. `revspec` (optional) diffs
-- "everything from <revspec> to the working copy", consistent across both VCSes.
-- Returns argv, root or nil.
local function resolve(revspec)
  local cwd = vim.fn.getcwd()
  local has_rev = revspec ~= nil and revspec ~= ''

  local jj_dir = vim.fs.find('.jj', { upward = true, path = cwd, type = 'directory' })[1]
  if jj_dir and vim.fn.executable('jj') == 1 then
    local root = vim.system({ 'jj', 'root' }, { text = true }):wait()
    if root.code ~= 0 then
      return nil
    end
    local argv = { 'jj', 'diff', '--git', '--context', '0' }
    if has_rev then
      vim.list_extend(argv, { '--from', revspec })
    end
    return argv, vim.trim(root.stdout or '')
  end

  if vim.fn.executable('git') == 1 then
    local rp = vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { text = true }):wait()
    if rp.code == 0 then
      local argv =
        { 'git', 'diff', '--no-color', '--no-ext-diff', '-U0', '--src-prefix=a/', '--dst-prefix=b/' }
      argv[#argv + 1] = has_rev and revspec or 'HEAD'
      return argv, vim.trim(rp.stdout or '')
    end
  end

  return nil
end

-- Parse a git-format unified diff into one item per added/modified line, with its
-- line number in the *current* file.
local function parse(text, root)
  local items = {}
  local file, lnum
  for _, line in ipairs(vim.split(text or '', '\n', { plain = true })) do
    if line:sub(1, 11) == 'diff --git ' then
      file, lnum = nil, nil
    elseif line:sub(1, 4) == '+++ ' then
      local path = line:sub(5)
      if path == '/dev/null' then
        file = nil -- deleted file: nothing in the working tree to show
      else
        file = root .. '/' .. path:gsub('^b/', '')
      end
    elseif line:sub(1, 2) == '@@' then
      lnum = tonumber(line:match('^@@ %-[%d,]+ %+(%d+)'))
    elseif file and lnum then
      local tag = line:sub(1, 1)
      if tag == '+' then
        items[#items + 1] = { filename = file, lnum = lnum, text = line:sub(2) }
        lnum = lnum + 1
      elseif tag == ' ' then
        lnum = lnum + 1
      end
      -- '-' (removed) lines aren't in the new file, so they don't advance lnum.
    end
  end
  return items
end

--- @param revspec string|nil
--- @param present fun(items: table[], title: string)
function M.run(revspec, present)
  local argv, root = resolve(revspec)
  if not argv then
    vim.notify('stitches: not inside a git or jj repository', vim.log.levels.ERROR)
    return
  end

  local result = vim.system(argv, { text = true }):wait()
  if result.code ~= 0 then
    vim.notify('stitches: ' .. argv[1] .. ' diff failed\n' .. (result.stderr or ''), vim.log.levels.ERROR)
    return
  end

  local items = parse(result.stdout, root)
  if #items == 0 then
    vim.notify('stitches: no changes to show', vim.log.levels.WARN)
    return
  end

  local title = (revspec and revspec ~= '') and ('diff: ' .. revspec) or 'diff'
  present(items, title)
end

return M
