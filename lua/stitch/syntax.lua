-- Legacy-syntax fallback tier: files whose filetype has no Treesitter grammar
-- (kitty.conf, ghostty's config, ...) still get the regex syntax highlighting
-- their real buffer would use. Each such file's syntax file is `:syn include`d
-- into the stitch buffer once, as a contained cluster, and every block of the
-- file becomes a line-anchored `syn region` over its current rows pointing at
-- that cluster. Regions address rows by line number, so they are rebuilt
-- whenever the layout moves — decorate() already runs at exactly those times,
-- and the wanted region set is keyed so an unmoved layout costs one string
-- compare.
local reconcile = require('stitch.reconcile')
local srclang = require('stitch.lang')

local M = {}

--- Sync the buffer's syntax regions with the current row→source map.
--- Per-buffer state rides `st`: syn_key (last applied region set), syn_clusters
--- (filetypes already included), syn_regions (region group count to clear).
function M.sync(buf, st, map)
  local wanted, key = {}, {}
  for _, b in ipairs(reconcile.blocks(map)) do
    local ft = srclang.syntax_ft(b.filename)
    if ft then
      wanted[#wanted + 1] = { ft = ft, s = b.s_row, e = b.e_row }
      key[#key + 1] = ft .. ':' .. b.s_row .. ':' .. b.e_row
    end
  end
  key = table.concat(key, ',')
  if st.syn_key == key then
    return
  end
  st.syn_key = key
  st.syn_clusters = st.syn_clusters or {}
  vim.api.nvim_buf_call(buf, function()
    for i = 1, st.syn_regions or 0 do
      vim.cmd('silent! syntax clear StitchSynBlock' .. i)
    end
    -- Group/cluster names allow only [A-Za-z0-9_]; a filetype may not (dashes).
    local function cluster(ft)
      return 'StitchSyn_' .. ft:gsub('%W', '_')
    end
    for _, r in ipairs(wanted) do
      if not st.syn_clusters[r.ft] then
        st.syn_clusters[r.ft] = true
        -- `:syn include` refuses to run while b:current_syntax is set (the
        -- included file's own guard), and sets it again when done.
        vim.b[buf].current_syntax = nil
        pcall(vim.cmd, ('silent syntax include @%s syntax/%s.vim'):format(cluster(r.ft), r.ft))
        vim.b[buf].current_syntax = nil
      end
    end
    for i, r in ipairs(wanted) do
      vim.cmd(
        ('syntax region StitchSynBlock%d start=/\\%%%dl/ end=/\\%%%dl$/ contains=@%s keepend'):format(
          i,
          r.s,
          r.e,
          cluster(r.ft)
        )
      )
    end
    st.syn_regions = #wanted
  end)
end

return M
