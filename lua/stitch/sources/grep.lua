-- Project search source: runs ripgrep (--json) and parses the results into
-- quickfix items, one per matched span so exact match columns are preserved.
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
    vim.notify('stitches: ripgrep (rg) not found on PATH', vim.log.levels.ERROR)
    return
  end

  -- Run ripgrep async so a large repo doesn't freeze the UI while it scans.
  vim.system({ 'rg', '--json', '--', pattern }, { text = true }, vim.schedule_wrap(function(result)
    if result.code == 2 then
      vim.notify('stitches: ripgrep error\n' .. (result.stderr or ''), vim.log.levels.ERROR)
      return
    end

    -- rg --json emits one JSON object per line. Each "match" carries the line text
    -- and the byte offsets of every submatch on that line, which become the exact
    -- highlight span (col..end_col) for each quickfix item. Parsing stops at
    -- max_results: past it, every further item only grows an unusably large view
    -- (and each unique file costs a full read at paint).
    local max = require('stitch.config').options.max_results
    local items, truncated = {}, false
    for _, line in ipairs(vim.split(result.stdout or '', '\n', { trimempty = true })) do
      if max and #items >= max then
        truncated = true
        break
      end
      local ok, obj = pcall(vim.json.decode, line)
      if ok and type(obj) == 'table' and obj.type == 'match' then
        local data = obj.data
        local path = data.path and data.path.text
        local text = data.lines and data.lines.text
        local lnum = data.line_number
        if path and text and lnum then
          text = text:gsub('\n$', '')
          for _, sm in ipairs(data.submatches or {}) do
            items[#items + 1] = {
              filename = path,
              lnum = lnum,
              col = sm.start + 1,
              end_col = sm['end'] + 1, -- 'end' is a Lua keyword
              text = text,
            }
          end
        end
      end
    end

    if #items == 0 then
      vim.notify('stitches: no matches for ' .. pattern, vim.log.levels.WARN)
      return
    end
    if truncated then
      vim.notify(('stitches: showing first %d results (max_results)'):format(#items), vim.log.levels.WARN)
    end

    present(items, 'grep: ' .. pattern)
  end))
end

return M
