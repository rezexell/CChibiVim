# CChibiVim

A Vim-like editor for ComputerCraft (CC:Tweaked), a Minecraft mod. Tested on CraftOS. To use it, run the `cchibivim.lua` file.

## Usage

Movement uses Vim-style motions, including `h`/`j`/`k`/`l` and others.

To enter Normal mode, press `j` followed by `k`. Currently, this shortcut works whenever you press these keys in sequence.  
Note: standard Vim uses `Esc` or `Ctrl-[` for this.

### Basic Vim motions

| Key / motion | Action |
|---|---|
| `h` | Move left |
| `j` | Move down |
| `k` | Move up |
| `l` | Move right |
| `w` | Move to the next word |
| `b` | Move to the previous word |
| `e` | Move to the end of the current/next word |
| `0` | Move to the beginning of the line |
| `^` | Move to the first non-blank character of the line |
| `$` | Move to the end of the line |
| `gg` | Move to the first line |
| `G` | Move to the last line |
| `{count}{motion}` | Repeat a motion, e.g. `5j` moves down 5 lines |

### Common Vim commands often used with motions

| Command | Action |
|---|---|
| `i` | Insert before the cursor |
| `a` | Insert after the cursor |
| `o` | Open a new line below |
| `O` | Open a new line above |
| `x` | Delete the character under the cursor |
| `dd` | Delete the current line |
| `yy` | Yank the current line |
| `p` | Paste |
| `u` | Undo |

### Available commands (Command mode is accessible by pressing :)
| Command | Action |
|---|---|
| `w` | Save the file |
| `q` | Quit the file |
| `x` | Save and quit |
| `q!` | Quit the file without saving |

---

AI was used during development.
