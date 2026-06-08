# excerpts.nvim

View excerpts from many files in a single buffer

Populate one grouped view from a project search, LSP references, or diagnostics,
read/edit and push changes back to the buffers, and jump straight to any source line.

## Requirements

- Neovim **0.11+** (developed against 0.12.x)
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for the grep source

## Install

## Usage

```vim
:Excerpts grep <pattern>   " project search (ripgrep)
:Excerpts references       " all references to the symbol under the cursor
:Excerpts diagnostics      " all project diagnostics
:Excerpts diff             " working-tree changes (git or jj)
:Excerpts diff <rev>       " everything changed since <rev>
:Excerpts qf               " build a view from the current quickfix list
```

Or from Lua:

```lua
require('excerpts').grep('TODO')
require('excerpts').references()
require('excerpts').diagnostics()
require('excerpts').diff()         -- or .diff('main')
require('excerpts').from_qflist()
```

Inside the view:

| Key     | Action                                   |
| ------- | ---------------------------------------- |
| `<CR>`  | open the source file at the line/cursor  |
| `q`     | close the view                           |
| `+`     | show more context around this excerpt    |
| `-`     | show less context around this excerpt    |
| `:w`    | write all edits back to their source files |

`+`/`-` accept a count: `10+` reveals 10 lines at once.

Each excerpt shows its source line number inline; files are separated by a
header. Diagnostics show their message as a trailing annotation.

## Configuration

Defaults:

```lua
require('excerpts').setup({
  window = 'split',  -- 'split' | 'vsplit' | 'tab' | 'current'
  highlight = true,  -- project Treesitter syntax highlighting onto excerpts
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
| `ExcerptsHeaderBg`      | `CursorLine` bg (the header bar) |
| `ExcerptsHeader`        | `Directory` fg (the `▌` accent) |
| `ExcerptsHeaderDir`     | `Comment` fg (dimmed directory) |
| `ExcerptsHeaderName`    | bold (the file name) |
| `ExcerptsLnum`          | `LineNr`     |
| `ExcerptsContextLnum`   | `NonText`    |
| `ExcerptsMatch`         | blue underline |
| `ExcerptsAnnotation`    | `Comment`    |
| `ExcerptsSeparator`     | `NonText`    |

