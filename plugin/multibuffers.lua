if vim.g.loaded_multibuffers then
  return
end
vim.g.loaded_multibuffers = true

local subcommands = { 'grep', 'references', 'diagnostics', 'qf' }

vim.api.nvim_create_user_command('Multibuffers', function(opts)
  local sub = opts.fargs[1]
  local mb = require('multibuffers')
  if sub == 'grep' then
    mb.grep(table.concat(vim.list_slice(opts.fargs, 2), ' '))
  elseif sub == 'references' then
    mb.references()
  elseif sub == 'diagnostics' then
    mb.diagnostics()
  elseif sub == 'qf' then
    mb.from_qflist()
  else
    vim.notify('Multibuffers: unknown subcommand: ' .. tostring(sub), vim.log.levels.ERROR)
  end
end, {
  nargs = '*',
  desc = 'Open a multibuffer view (grep|references|diagnostics|qf)',
  complete = function(arglead, line)
    -- Only complete the subcommand in the first argument position.
    if line:match('^%s*Multibuffers%s+%S*$') then
      return vim.tbl_filter(function(s)
        return s:find(arglead, 1, true) == 1
      end, subcommands)
    end
    return {}
  end,
})
