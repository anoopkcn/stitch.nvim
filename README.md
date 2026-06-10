# stitch.nvim

Stitches are portions of text belonging to a file.

View 'stitches' from many files in a single buffer and edit them as if they belong to a single buffer.

- stitches can be search results, diffs, LSP references, diagnostics or quickfix results
- read/edit and push changes back to the buffers, and jump straight to any source line.
- expand or collapse context around a stitch

![disply_img](https://github.com/user-attachments/assets/34bc7e20-e772-40de-a843-08b34897f2b3)

## Requirements

- Neovim **0.12+** (developed against 0.12.x)
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for the grep source

## Install

The plugin works out of the box, no `setup()` call required.


```lua
vim.pack.add({"https://github.com/anoopkcn/stitch.nvim"})
```

## Usage

```vim
:Stitch grep <pattern>   " project search (ripgrep)
:Stitch references       " all references to the symbol under the cursor
:Stitch diagnostics      " all project diagnostics
:Stitch diff             " working-tree changes (git or jj)
:Stitch diff <rev>       " everything changed since <rev>
:Stitch qf               " build a view from the current quickfix list
:Stitch next             " jump to the next stitch (loads the source buffer)
:Stitch prev             " jump to the previous stitch
```

Or from Lua:

```lua
require('stitch').grep('TODO')
require('stitch').references()
require('stitch').diagnostics()
require('stitch').diff()         -- or .diff('main')
require('stitch').from_qflist()
require('stitch').next()         -- and .prev()
```

`next`/`prev` work from anywhere: they walk the stitches of the visible view
(the most recently used one if several are open), load the stitch's source
buffer and land the cursor on its line and column, wrapping at the ends. The
view's cursor advances with each step, so the walk continues from wherever
you last were in the view. Unlike `:cnext`, they follow the live view — line
numbers stay correct after edits.

Inside the view:

| Key     | Action                                   |
| ------- | ---------------------------------------- |
| `<CR>`  | open the source file at the line/cursor  |
| `q`     | close the view                           |
| `+`     | show more context around this stitch    |
| `-`     | show less context around this stitch    |
| `:w`    | write all edits back to their source files |

`+`/`-` accept a count: `10+` reveals 10 lines at once.

Each stitch shows its source line number in the gutter; each file is introduced
by an underlined, dimmed `dir/name` header, aligned to the left edge.
Diagnostics show their message as a trailing annotation.

## Configuration

Defaults:

```lua
require('stitch').setup({
  window = 'split',  -- 'split' | 'vsplit' | 'tab' | 'current'
  highlight = true,  -- syntax highlighting (Treesitter, regex syntax fallback)
  context = 1,       -- initial source context lines above/below each match
  context_step = 1,  -- lines added/removed per +/- press (a count overrides it)
  max_results = 2000, -- cap on grep results (false disables the cap)
  keys = {
    jump = '<CR>',
    close = 'q',
    expand = '+',
    collapse = '-',
  },
})
```

### Highlight groups

| Group                       | Default link |
| --------------------------- | ------------ |
| `StitchHeaderDir`     | `Comment` fg, underlined (the dimmed directory) |
| `StitchHeaderName`    | `Comment` fg, underlined (the file name, dimmed too) |
| `StitchLnum`          | `LineNr`     |
| `StitchContextLnum`   | `NonText`    |
| `StitchMatch`         | translucent blue bg |
| `StitchAnnotation`    | `Comment`    |
| `StitchSeparator`     | `NonText` (the `⋮` block divider and inter-file spacing) |

