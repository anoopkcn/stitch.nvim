-- LSP find-all-references source: gathers references to the symbol under the
-- cursor across all attached clients into quickfix items.
local M = {}

--- @param present fun(items: table[], title: string)
function M.run(present)
  local bufnr = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = 'textDocument/references' })
  if #clients == 0 then
    vim.notify('multibuffers: no LSP client supports references here', vim.log.levels.WARN)
    return
  end

  local encoding = clients[1].offset_encoding or 'utf-16'
  local params = vim.lsp.util.make_position_params(0, encoding)
  params.context = { includeDeclaration = true }

  vim.lsp.buf_request_all(bufnr, 'textDocument/references', params, function(results)
    local locations = {}
    for _, res in pairs(results) do
      if res.result then
        vim.list_extend(locations, res.result)
      end
    end
    if #locations == 0 then
      vim.notify('multibuffers: no references found', vim.log.levels.WARN)
      return
    end
    local items = vim.lsp.util.locations_to_items(locations, encoding)
    present(items, 'References')
  end)
end

return M
