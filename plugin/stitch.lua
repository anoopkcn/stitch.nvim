if vim.g.loaded_stitch then
  return
end
vim.g.loaded_stitch = true

local subcommands = { 'grep', 'references', 'diagnostics', 'diff', 'qf', 'next', 'prev' }

vim.api.nvim_create_user_command('Stitch', function(opts)
  local sub = opts.fargs[1]
  local mb = require('stitch')
  if sub == 'grep' then
    mb.grep(table.concat(vim.list_slice(opts.fargs, 2), ' '))
  elseif sub == 'references' then
    mb.references()
  elseif sub == 'diagnostics' then
    mb.diagnostics()
  elseif sub == 'diff' then
    mb.diff(table.concat(vim.list_slice(opts.fargs, 2), ' '))
  elseif sub == 'qf' then
    mb.from_qflist()
  elseif sub == 'next' then
    mb.next()
  elseif sub == 'prev' then
    mb.prev()
  else
    vim.notify('Stitch: unknown subcommand: ' .. tostring(sub), vim.log.levels.ERROR)
  end
end, {
  nargs = '*',
  desc = 'Open a stitch view (grep|references|diagnostics|diff|qf) or walk it (next|prev)',
  complete = function(arglead, line)
    -- Only complete the subcommand in the first argument position.
    if line:match('^%s*Stitch%s+%S*$') then
      return vim.tbl_filter(function(s)
        return s:find(arglead, 1, true) == 1
      end, subcommands)
    end
    return {}
  end,
})
