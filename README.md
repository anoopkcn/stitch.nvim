# multibuffers.nvim

View excerpts from many files in a single buffer — Neovim's take on
[Zed's multibuffers](https://zed.dev/docs/multibuffers).

Populate one grouped view from a project search, LSP references, or diagnostics,
read it top-to-bottom, and jump straight to any source line.

> **Status: v0.2 — editable.** Edit excerpt lines in place and `:w` to write the
> changes back to every source file at once. Strict 1:1 line editing only (see
> [Editing](#editing)); per-excerpt context and expand/collapse land in v0.3.
> See [SCOPE.md](SCOPE.md) for the roadmap.

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
| `+`     | show more context around this excerpt    |
| `-`     | show less context around this excerpt    |
| `:w`    | write all edits back to their source files |

`+`/`-` accept a count: `10+` reveals 10 lines at once.

Each excerpt shows its source line number inline; files are separated by a
header. Diagnostics show their message as a trailing annotation.

## Editing

Edit excerpt lines as if they were an ordinary buffer, then `:w` — every changed
line is written back to its source file, and all touched files are saved
together.

v0.2 is **strict 1:1 line editing**:

- Editing the text of an existing excerpt line is written back.
- Lines you *insert* (which have no source location) are ignored.
- Excerpts you *delete* are ignored (the source line is left as-is).
- If a source line changed underneath you since the view was opened, that
  excerpt is flagged inline (`‹ source changed — not written ›`) and **skipped**,
  never clobbered.

After `:w` you get a summary, e.g. `wrote 3 line(s) in 2 file(s)`, plus any
skipped/ignored counts. Inserting and deleting lines inside an excerpt is a
deliberate non-goal for now — use `:cdo` for structural bulk edits.

> Note: write-back goes through each source buffer and writes it, so saving the
> multibuffer behaves like saving those files directly — it also persists any
> other unsaved changes in them and triggers their `BufWritePre`/`BufWritePost`
> autocmds. If you use format-on-save, every touched file is formatted on `:w`.

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

### Context lines

Set `context = N` to show N source lines above and below each match. Overlapping
or adjacent context within a file is merged into one block, and a gap between
blocks is shown as a `⋮ N lines` divider. Context lines are dimmer than match
lines but are **fully editable** — editing one writes back to its source line
just like a match. So `context` is also a quick way to edit a few lines around
each hit without leaving the view.

Press `+` / `-` to grow or shrink the context around the excerpt under the
cursor (by `context_step` lines, or a count: `10+`). Expanding far enough merges
neighbouring excerpts; collapsing splits them back. Note: because expand/collapse
re-lays-out real anchored lines, it **resets the undo history** — any pending
edits to existing excerpt lines are kept (and still save), but you can't `u`
across an expand/collapse, and brand-new lines you typed into the view (which
aren't anchored to a source line, and wouldn't be written by `:w` anyway) are
dropped.

### Syntax highlighting

Each excerpt is syntax-highlighted with its **source file's** Treesitter
grammar, so a view mixing Lua, Python and Markdown shows each line in the right
colours. The language is derived from the filename, so source files are read but
not filetype-detected — no LSP is started just to colour an excerpt. Files
without a Treesitter parser simply render uncoloured. Disable with
`highlight = false`.

The matched text itself is highlighted on top of syntax (`MultibuffersMatch`):
the exact search span(s) for grep (via `rg --json`), and the symbol/diagnostic
range for references and diagnostics.

### Highlight groups

| Group                       | Default link |
| --------------------------- | ------------ |
| `MultibuffersHeader`        | `Directory`  |
| `MultibuffersLnum`          | `LineNr`     |
| `MultibuffersContextLnum`   | `NonText`    |
| `MultibuffersMatch`         | `Search`     |
| `MultibuffersAnnotation`    | `Comment`    |
| `MultibuffersSeparator`     | `NonText`    |

## Not in scope

Multi-cursor editing across files is intentionally **not** implemented — use
`:cdo`/`:cfdo` over the quickfix list for bulk changes. See [SCOPE.md](SCOPE.md).
