if vim.g.loaded_excerpts then
  return
end
vim.g.loaded_excerpts = true

local subcommands = { 'grep', 'references', 'diagnostics', 'qf' }

vim.api.nvim_create_user_command('Excerpts', function(opts)
  local sub = opts.fargs[1]
  local mb = require('excerpts')
  if sub == 'grep' then
    mb.grep(table.concat(vim.list_slice(opts.fargs, 2), ' '))
  elseif sub == 'references' then
    mb.references()
  elseif sub == 'diagnostics' then
    mb.diagnostics()
  elseif sub == 'qf' then
    mb.from_qflist()
  else
    vim.notify('Excerpts: unknown subcommand: ' .. tostring(sub), vim.log.levels.ERROR)
  end
end, {
  nargs = '*',
  desc = 'Open an excerpts view (grep|references|diagnostics|qf)',
  complete = function(arglead, line)
    -- Only complete the subcommand in the first argument position.
    if line:match('^%s*Excerpts%s+%S*$') then
      return vim.tbl_filter(function(s)
        return s:find(arglead, 1, true) == 1
      end, subcommands)
    end
    return {}
  end,
})
