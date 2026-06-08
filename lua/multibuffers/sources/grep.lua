-- Project search source: runs ripgrep and parses the results into quickfix items.
local M = {}

--- @param pattern string|nil search pattern (prompts if empty)
--- @param present fun(items: table[], title: string)
function M.run(pattern, present)
  if not pattern or pattern == '' then
    pattern = vim.fn.input('Grep pattern: ')
    if pattern == '' then
      return
    end
  end

  if vim.fn.executable('rg') == 0 then
    vim.notify('multibuffers: ripgrep (rg) not found on PATH', vim.log.levels.ERROR)
    return
  end

  local result = vim.system(
    { 'rg', '--vimgrep', '--color=never', '--', pattern },
    { text = true }
  ):wait()

  if result.code == 2 then
    vim.notify('multibuffers: ripgrep error\n' .. (result.stderr or ''), vim.log.levels.ERROR)
    return
  end

  local lines = vim.split(result.stdout or '', '\n', { trimempty = true })
  if #lines == 0 then
    vim.notify('multibuffers: no matches for ' .. pattern, vim.log.levels.WARN)
    return
  end

  -- Parse rg --vimgrep output into items without disturbing the live qf list.
  local items = vim.fn.getqflist({ lines = lines, efm = '%f:%l:%c:%m' }).items
  present(items, 'grep: ' .. pattern)
end

return M
