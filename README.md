# stitch.nvim

Stitches are portions of text belonging to a file.

View 'stitches' from many files in a single buffer and edit them as if they belong to a single buffer.

- stitches can be search results, diffs, LSP references, diagnostics or quickfix results
- read/edit and push changes back to the buffers, and jump straight to any source line.
- expand or collapse context around a stitch

![disply_img](https://github.com/user-attachments/assets/c7073180-f345-45d8-90d1-d9e4f9ae00dc)

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
```

Or from Lua:

```lua
require('stitch').grep('TODO')
require('stitch').references()
require('stitch').diagnostics()
require('stitch').diff()         -- or .diff('main')
require('stitch').from_qflist()
```

Inside the view:

| Key     | Action                                   |
| ------- | ---------------------------------------- |
| `<CR>`  | open the source file at the line/cursor  |
| `q`     | close the view                           |
| `+`     | show more context around this stitch    |
| `-`     | show less context around this stitch    |
| `:w`    | write all edits back to their source files |

`+`/`-` accept a count: `10+` reveals 10 lines at once.

Each stitch shows its source line number inline; files are separated by a
header. Diagnostics show their message as a trailing annotation.

## Configuration

Defaults:

```lua
require('stitch').setup({
  window = 'split',  -- 'split' | 'vsplit' | 'tab' | 'current'
  highlight = true,  -- project Treesitter syntax highlighting onto stitches
  context = 0,       -- lines of source context shown above/below each match
  context_step = 4,  -- lines added/removed per +/- press (a count overrides it)
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
| `StitchHeaderBg`      | `CursorLine` bg (the header bar) |
| `StitchHeaderDir`     | `Comment` fg (dimmed directory) |
| `StitchHeaderName`    | bold (the file name) |
| `StitchLnum`          | `LineNr`     |
| `StitchContextLnum`   | `NonText`    |
| `StitchMatch`         | translucent blue bg |
| `StitchAnnotation`    | `Comment`    |
| `StitchSeparator`     | `NonText`    |

