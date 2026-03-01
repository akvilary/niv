# Vim Standard Keybindings Reference

Status legend: **[niv]** = implemented, **[niv: other]** = key used for different purpose

## Cursor Movement

| Key | Description | niv |
|-----|-------------|-----|
| `h` | Move cursor left | **[niv]** |
| `j` | Move cursor down | **[niv]** |
| `k` | Move cursor up | **[niv]** |
| `l` | Move cursor right | **[niv]** |
| `gj` | Move down on multi-line text | |
| `gk` | Move up on multi-line text | |
| `H` | Jump to top of screen | |
| `M` | Jump to middle of screen | |
| `L` | Jump to bottom of screen | |
| `w` | Jump to start of next word | **[niv]** |
| `W` | Jump to start of next word (with punctuation) | |
| `e` | Jump to end of word | **[niv]** |
| `E` | Jump to end of word (with punctuation) | |
| `b` | Jump back to start of word | **[niv]** |
| `B` | Jump back to start of word (with punctuation) | |
| `ge` | Jump back to end of word | |
| `gE` | Jump back to end of word (with punctuation) | |
| `%` | Jump to matching bracket/parenthesis | |
| `0` | Jump to line start | **[niv]** |
| `^` | Jump to first non-blank character | |
| `$` | Jump to line end | **[niv]** |
| `g_` | Jump to last non-blank character | |
| `gg` | Go to first line | **[niv]** |
| `G` | Go to last line | **[niv]** |
| `5gg` / `5G` | Go to line 5 | **[niv]** |
| `gd` | Move to local declaration | **[niv]** (LSP goto definition) |
| `gD` | Move to global declaration | |
| `fx` | Jump to next occurrence of character x | |
| `tx` | Jump before next occurrence of character x | |
| `Fx` | Jump to previous occurrence of character x | |
| `Tx` | Jump after previous occurrence of character x | |
| `;` | Repeat last f, t, F, or T movement | |
| `,` | Repeat last movement backward | |
| `}` | Jump to next paragraph/block | |
| `{` | Jump to previous paragraph/block | |
| `zz` | Center cursor on screen | |
| `zt` | Position cursor at top of screen | |
| `zb` | Position cursor at bottom of screen | |

## Scrolling

| Key | Description | niv |
|-----|-------------|-----|
| `Ctrl+e` | Scroll screen down one line | |
| `Ctrl+y` | Scroll screen up one line | |
| `Ctrl+b` | Scroll up one page | |
| `Ctrl+f` | Scroll down one page | |
| `Ctrl+d` | Scroll down half page | |
| `Ctrl+u` | Scroll up half page | |

## Insert Mode — Entering

| Key | Description | niv |
|-----|-------------|-----|
| `i` | Insert before cursor | **[niv]** |
| `I` | Insert at line beginning | |
| `a` | Append after cursor | **[niv]** |
| `A` | Append at line end | |
| `o` | Open new line below | **[niv]** |
| `O` | Open new line above | **[niv]** |
| `ea` | Insert at end of word | |
| `s` | Delete character and enter insert | |
| `S` | Delete line and enter insert | |
| `cc` | Replace entire line | |
| `C` / `c$` | Replace to end of line | |
| `ciw` | Replace entire word | |
| `cw` / `ce` | Replace to end of word | |
| `r` | Replace single character (stay in normal) | |
| `R` | Enter replace mode | |

## Insert Mode — Keys

| Key | Description | niv |
|-----|-------------|-----|
| `Ctrl+h` | Delete character before cursor | |
| `Ctrl+w` | Delete word before cursor | |
| `Ctrl+j` | Add line break at cursor | |
| `Ctrl+t` | Indent line right | |
| `Ctrl+d` | De-indent line left | |
| `Ctrl+n` | Auto-complete next match | **[niv]** (LSP completion next) |
| `Ctrl+p` | Auto-complete previous match | **[niv]** (LSP completion prev) |
| `Ctrl+rx` | Insert contents of register x | |
| `Ctrl+o` | Temporarily enter normal mode for one command | |
| `Esc` / `Ctrl+c` | Exit insert mode | **[niv]** (Esc only) |

## Editing (Normal Mode)

| Key | Description | niv |
|-----|-------------|-----|
| `J` | Join line below with space | |
| `gJ` | Join line below without space | |
| `gwip` | Reflow paragraph | |
| `g~` | Switch case (with motion) | |
| `gu` | Change to lowercase (with motion) | |
| `gU` | Change to uppercase (with motion) | |
| `~` | Switch case of character under cursor | |
| `xp` | Transpose two letters | |
| `u` | Undo | **[niv]** |
| `U` | Restore last changed line | |
| `Ctrl+r` | Redo | **[niv]** |
| `.` | Repeat last command | |

## Cut and Paste

| Key | Description | niv |
|-----|-------------|-----|
| `yy` | Yank (copy) line | **[niv]** |
| `2yy` | Yank 2 lines | |
| `yw` | Yank word from cursor | |
| `yiw` | Yank word under cursor | |
| `yaw` | Yank word with space | |
| `y$` / `Y` | Yank to end of line | |
| `p` | Paste after cursor | **[niv]** |
| `P` | Paste before cursor | **[niv]** |
| `gp` | Paste after and move cursor after | |
| `gP` | Paste before and move cursor after | |
| `dd` | Delete (cut) line | **[niv]** |
| `2dd` | Delete 2 lines | |
| `dw` | Delete word from cursor | |
| `diw` | Delete word under cursor | |
| `daw` | Delete word with space | |
| `d$` / `D` | Delete to end of line | |
| `x` | Delete character under cursor | **[niv]** |
| `X` | Delete character before cursor | |

## Indent

| Key | Description | niv |
|-----|-------------|-----|
| `>>` | Indent right one level | |
| `<<` | Indent left one level | |
| `>%` | Indent block with brackets | |
| `<%` | De-indent block with brackets | |
| `>ib` | Indent inner block | |
| `>at` | Indent block with tags | |
| `3==` | Re-indent 3 lines | |
| `=%` | Re-indent block | |
| `gg=G` | Re-indent entire file | |
| `]p` | Paste and adjust indent | |

## Search and Replace

| Key | Description | niv |
|-----|-------------|-----|
| `/pattern` | Search forward | **[niv]** |
| `?pattern` | Search backward | |
| `n` | Repeat search forward | **[niv]** |
| `N` | Repeat search backward | **[niv]** |
| `*` | Search word under cursor forward | |
| `#` | Search word under cursor backward | |
| `:%s/old/new/g` | Replace all in file | |
| `:%s/old/new/gc` | Replace all with confirmation | |
| `:noh` | Remove search highlighting | |

## Visual Mode

| Key | Description | niv |
|-----|-------------|-----|
| `v` | Start character-wise visual mode | |
| `V` | Start line-wise visual mode | |
| `Ctrl+v` | Start block visual mode | |
| `o` | Move to other end of selection | |
| `O` | Move to other corner of block | |
| `aw` | Select a word | |
| `ab` | Select block with () | |
| `aB` | Select block with {} | |
| `at` | Select block with tags | |
| `ib` | Select inner block with () | |
| `iB` | Select inner block with {} | |
| `it` | Select inner block with tags | |
| `Esc` / `Ctrl+c` | Exit visual mode | |

## Visual Mode Commands

| Key | Description | niv |
|-----|-------------|-----|
| `>` | Shift text right | |
| `<` | Shift text left | |
| `y` | Yank selection | |
| `d` | Delete selection | |
| `~` | Switch case | |
| `u` | Change to lowercase | |
| `U` | Change to uppercase | |

## Marks and Jumps

| Key | Description | niv |
|-----|-------------|-----|
| `ma` | Set mark a at current position | |
| `` `a `` | Jump to mark a | |
| `'a` | Jump to line of mark a | |
| `` `0 `` | Go to position when Vim last exited | |
| `` `. `` | Go to last change position | |
| ``` `` ``` | Go to position before last jump | |
| `Ctrl+o` | Go to older position in jump list | |
| `Ctrl+i` | Go to newer position in jump list | |
| `g;` | Go to older change position | |
| `g,` | Go to newer change position | |
| `Ctrl+]` | Jump to tag under cursor | |

## Macros

| Key | Description | niv |
|-----|-------------|-----|
| `qa` | Start recording macro a | |
| `q` | Stop recording | |
| `@a` | Execute macro a | |
| `@@` | Execute last macro | |

## Registers

| Key | Description | niv |
|-----|-------------|-----|
| `:reg` | Show register contents | |
| `"xy` | Yank into register x | |
| `"xp` | Paste from register x | |
| `"+y` | Yank to system clipboard | |
| `"+p` | Paste from system clipboard | |

## Tabs

| Key | Description | niv |
|-----|-------------|-----|
| `:tabnew {file}` | Open file in new tab | |
| `gt` / `:tabn` | Next tab | |
| `gT` / `:tabp` | Previous tab | |
| `#gt` | Go to tab number # | |
| `:tabm #` | Move tab to position # | |
| `:tabc` | Close current tab | |
| `:tabo` | Close all other tabs | |

## Windows

| Key | Description | niv |
|-----|-------------|-----|
| `:sp file` | Horizontal split | |
| `:vsp file` | Vertical split | |
| `Ctrl+ws` | Split horizontally | |
| `Ctrl+wv` | Split vertically | |
| `Ctrl+ww` | Switch to next window | **[niv: other]** switch focus to sidebar |
| `Ctrl+wq` | Close window | |
| `Ctrl+wx` | Exchange windows | |
| `Ctrl+w=` | Equalize window sizes | |
| `Ctrl+wh` | Move to left window | |
| `Ctrl+wl` | Move to right window | |
| `Ctrl+wj` | Move to lower window | |
| `Ctrl+wk` | Move to upper window | |
| `Ctrl+wH` | Move window to far left | |
| `Ctrl+wL` | Move window to far right | |
| `Ctrl+wJ` | Move window to bottom | |
| `Ctrl+wK` | Move window to top | |
| `Ctrl+wT` | Move split to new tab | |

## Buffers

| Key | Description | niv |
|-----|-------------|-----|
| `:e file` | Edit file in new buffer | **[niv]** |
| `:bn` | Next buffer | |
| `:bp` | Previous buffer | |
| `:bd` | Delete buffer | |
| `:b#` | Go to buffer by index | |
| `:ls` / `:buffers` | List all buffers | |

## Folding

| Key | Description | niv |
|-----|-------------|-----|
| `zf` | Create fold | |
| `zd` | Delete fold | |
| `za` | Toggle fold | |
| `zo` | Open fold | |
| `zc` | Close fold | |
| `zr` | Reduce fold depth | |
| `zm` | Increase fold depth | |
| `zi` | Toggle all folding | |

## Diff

| Key | Description | niv |
|-----|-------------|-----|
| `]c` | Jump to next change | |
| `[c` | Jump to previous change | |
| `do` / `:diffget` | Get difference from other buffer | |
| `dp` / `:diffput` | Put difference to other buffer | |

## Exiting

| Key | Description | niv |
|-----|-------------|-----|
| `:w` | Save | **[niv]** |
| `:wq` / `:x` / `ZZ` | Save and quit | **[niv]** (:wq) |
| `:q` | Quit | **[niv]** |
| `:q!` / `ZQ` | Quit without saving | **[niv]** (:q!) |
| `:wqa` | Save and quit all tabs | |

## Ctrl Key Summary (Normal Mode)

| Key | Description | niv |
|-----|-------------|-----|
| `Ctrl+a` | Increment number under cursor | |
| `Ctrl+x` | Decrement number under cursor | |
| `Ctrl+b` | Page up | **[niv: other]** toggle file explorer |
| `Ctrl+f` | Page down | |
| `Ctrl+d` | Half page down | |
| `Ctrl+u` | Half page up | |
| `Ctrl+e` | Scroll down one line | **[niv: other]** toggle file explorer |
| `Ctrl+y` | Scroll up one line | |
| `Ctrl+g` | Show file info | **[niv: other]** toggle git panel |
| `Ctrl+o` | Jump to older position | |
| `Ctrl+i` | Jump to newer position | |
| `Ctrl+r` | Redo | **[niv]** |
| `Ctrl+v` | Block visual mode | |
| `Ctrl+w` | Window commands prefix | **[niv: other]** switch focus to sidebar |
| `Ctrl+]` | Jump to tag | |
| `Ctrl+^` | Switch to alternate file | |
| `Ctrl+l` | Redraw screen | |
| `Ctrl+z` | Suspend vim | |

## niv-only Keybindings (not in vim)

| Key | Mode | Description |
|-----|------|-------------|
| `Ctrl+E` | Normal | Toggle file explorer sidebar |
| `Ctrl+G` | Normal | Toggle git panel |
| `Ctrl+W` / `Tab` | Normal | Switch focus to sidebar |
| `Ctrl+Space` | Insert | Trigger LSP completion |
| `gb` | Normal | Go back (jumplist) |
| `:git` | Command | Open git panel |
| `:lsp` | Command | Open LSP manager |
