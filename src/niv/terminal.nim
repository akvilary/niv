## Terminal I/O: raw mode, ANSI escape output, key reading

import std/posix
import posix/termios as ptermios
import types

var origTermios: ptermios.Termios
var rawModeEnabled = false

proc getTerminalSize*(): tuple[width, height: int] =
  var ws: IOctl_WinSize
  if ioctl(STDOUT_FILENO, TIOCGWINSZ, addr ws) == 0:
    result = (int(ws.ws_col), int(ws.ws_row))
  else:
    result = (80, 24)

proc enableRawMode*() =
  if rawModeEnabled:
    return
  discard tcGetAttr(STDIN_FILENO, addr origTermios)

  var raw = origTermios
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not OPOST
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  raw.c_cc[VMIN] = 0.char
  raw.c_cc[VTIME] = 1.char  # 100ms timeout

  discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr raw)
  rawModeEnabled = true

  # Alternate screen buffer + Tokyo Night Storm theme + clear
  stdout.write("\e[?1049h\e[38;2;192;202;245m\e[48;2;36;40;59m\e[2J\e[H")
  stdout.flushFile()

proc disableRawMode*() =
  if not rawModeEnabled:
    return
  # Show cursor + leave alternate screen
  stdout.write("\e[?25h")
  stdout.write("\e[?1049l")
  stdout.flushFile()

  discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr origTermios)
  rawModeEnabled = false

proc readByte(): int =
  ## Read a single byte from stdin. Returns -1 on no input.
  var c: char
  let n = read(STDIN_FILENO, addr c, 1)
  if n == 1:
    result = ord(c)
  else:
    result = -1

proc readKey*(): InputKey =
  let b = readByte()
  if b == -1:
    return noKey()

  # Enter
  if b == 13:
    return specialKey(kkEnter)

  # Backspace
  if b == 127:
    return specialKey(kkBackspace)

  # Tab
  if b == 9:
    return specialKey(kkTab)

  # Ctrl keys (1-26, except 9=Tab, 13=Enter)
  if b >= 1 and b <= 26 and b != 9 and b != 13:
    return ctrlKey(chr(b + ord('a') - 1))

  # Escape or escape sequence
  if b == 27:
    let b2 = readByte()
    if b2 == -1:
      return specialKey(kkEscape)

    if b2 == ord('['):
      let b3 = readByte()
      if b3 == -1:
        return specialKey(kkEscape)

      case chr(b3)
      of 'A': return specialKey(kkArrowUp)
      of 'B': return specialKey(kkArrowDown)
      of 'C': return specialKey(kkArrowRight)
      of 'D': return specialKey(kkArrowLeft)
      of 'H': return specialKey(kkHome)
      of 'F': return specialKey(kkEnd)
      of '3':
        let b4 = readByte()
        if b4 == ord('~'):
          return specialKey(kkDelete)
        return specialKey(kkEscape)
      of '5':
        let b4 = readByte()
        if b4 == ord('~'):
          return specialKey(kkPageUp)
        return specialKey(kkEscape)
      of '6':
        let b4 = readByte()
        if b4 == ord('~'):
          return specialKey(kkPageDown)
        return specialKey(kkEscape)
      else:
        return specialKey(kkEscape)

    elif b2 == ord('O'):
      let b3 = readByte()
      if b3 == -1:
        return specialKey(kkEscape)
      case chr(b3)
      of 'H': return specialKey(kkHome)
      of 'F': return specialKey(kkEnd)
      else:
        return specialKey(kkEscape)

    else:
      return specialKey(kkEscape)

  # Printable characters
  if b >= 32 and b <= 126:
    return charKey(chr(b))

  return noKey()

# ANSI escape helpers
proc moveCursor*(row, col: int) =
  ## Move cursor to (row, col), 1-indexed
  stdout.write("\e[" & $row & ";" & $col & "H")

proc clearScreen*() =
  stdout.write("\e[2J")
  stdout.write("\e[H")

proc clearLine*() =
  ## Clear from cursor to end of line
  stdout.write("\e[K")

proc hideCursor*() =
  stdout.write("\e[?25l")

proc showCursor*() =
  stdout.write("\e[?25h")

proc setInverseVideo*() =
  stdout.write("\e[7m")

proc setDim*() =
  stdout.write("\e[2m")

proc setFg*(ansiCode: int) =
  ## Set foreground color using ANSI code (e.g. 31=red, 33=yellow, 32=green)
  stdout.write("\e[" & $ansiCode & "m")

proc setUnderline*() =
  stdout.write("\e[4m")

proc resetAttributes*() =
  stdout.write("\e[0m")

proc flushOut*() =
  stdout.flushFile()

# 24-bit true color support (Tokyo Night Storm)
proc setColorFg*(color: int) =
  ## Set foreground from 0xRRGGBB
  let r = (color shr 16) and 0xFF
  let g = (color shr 8) and 0xFF
  let b = color and 0xFF
  stdout.write("\e[38;2;" & $r & ";" & $g & ";" & $b & "m")

proc setColorBg*(color: int) =
  ## Set background from 0xRRGGBB
  let r = (color shr 16) and 0xFF
  let g = (color shr 8) and 0xFF
  let b = color and 0xFF
  stdout.write("\e[48;2;" & $r & ";" & $g & ";" & $b & "m")

proc setThemeColors*() =
  ## Reset and apply Tokyo Night Storm: #c0caf5 on #24283b
  stdout.write("\e[0m\e[38;2;192;202;245m\e[48;2;36;40;59m")

proc setThemeFg*() =
  ## Restore default theme foreground (#c0caf5)
  stdout.write("\e[38;2;192;202;245m")
