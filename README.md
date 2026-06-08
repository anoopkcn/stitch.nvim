# multibuffers.nvim

View excerpts from many files in a single buffer — Neovim's take on
[Zed's multibuffers](https://zed.dev/docs/multibuffers).

Populate one grouped view from a project search, LSP references, or diagnostics,
read it top-to-bottom, and jump straight to any source line.

> **Status: v0.1 — read-only viewer.** Editing excerpts and saving all files at
> once (the "edit once, write back everywhere" core) lands in v0.2. See
> [SCOPE.md](SCOPE.md) for the roadmap.

## Requirements

- Neovim **0.11+** (developed against 0.12.x)
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for the grep source

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'multibuffers.nvim',
  opts = {}, -- calls require('multibuffers').setup()
}
```

`setup()` is optional; the plugin works with defaults out of the box.

## Usage

```vim
:Multibuffers grep <pattern>   " project search (ripgrep)
:Multibuffers references       " all references to the symbol under the cursor
:Multibuffers diagnostics      " all project diagnostics
:Multibuffers qf               " build a view from the current quickfix list
```

Or from Lua:

```lua
require('multibuffers').grep('TODO')
require('multibuffers').references()
require('multibuffers').diagnostics()
require('multibuffers').from_qflist()
```

Inside the view:

| Key     | Action                                   |
| ------- | ---------------------------------------- |
| `<CR>`  | open the source file at the line/cursor  |
| `q`     | close the view                           |

Each excerpt shows its source line number inline; files are separated by a
header. Diagnostics show their message as a trailing annotation.

### Bulk edits

The view is backed by the quickfix list, so Neovim's built-in cross-file edit
commands work on the same set without any extra plugin code:

```vim
:cdo s/old/new/ | update     " substitute across every excerpt's line
:cfdo %s/old/new/g | update  " substitute across every file in the list
```

## Configuration

Defaults:

```lua
require('multibuffers').setup({
  window = 'split', -- 'split' | 'vsplit' | 'tab' | 'current'
  keys = {
    jump = '<CR>',
    close = 'q',
  },
})
```

### Highlight groups

| Group                     | Default link |
| ------------------------- | ------------ |
| `MultibuffersHeader`      | `Directory`  |
| `MultibuffersLnum`        | `LineNr`     |
| `MultibuffersAnnotation`  | `Comment`    |
| `MultibuffersSeparator`   | `NonText`    |

## Not in scope

Multi-cursor editing across files is intentionally **not** implemented — use
`:cdo`/`:cfdo` over the quickfix list for bulk changes. See [SCOPE.md](SCOPE.md).
