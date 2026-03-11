## Screen buffer for component-isolated rendering
## Each UI component renders into its own buffer with automatic clipping

import std/unicode
import terminal
import unicode_width

const
  defaultFg* = 0xc0caf5  # Tokyo Night Storm foreground
  defaultBg* = 0x24283b  # Tokyo Night Storm background

type
  Cell* = object
    ch*: string    # UTF-8 character (single rune)
    fg*: int       # foreground color 0xRRGGBB, -1 = theme default
    bg*: int       # background color 0xRRGGBB, -1 = theme default
    wide*: bool    # second column of a wide character

  ScreenBuffer* = object
    width*, height*: int
    cells*: seq[Cell]  # flat row-major: cells[row * width + col]
    curRow*, curCol*: int
    curFg*, curBg*: int

const emptyCell = Cell(ch: " ", fg: -1, bg: -1)

proc initScreenBuffer*(w, h: int): ScreenBuffer =
  result.width = w
  result.height = h
  result.cells = newSeq[Cell](w * h)
  result.curFg = -1
  result.curBg = -1
  for i in 0..<result.cells.len:
    result.cells[i] = emptyCell

proc resize*(buf: var ScreenBuffer, w, h: int) =
  buf.width = w
  buf.height = h
  buf.cells.setLen(w * h)
  buf.curRow = 0
  buf.curCol = 0
  buf.curFg = -1
  buf.curBg = -1
  for i in 0..<buf.cells.len:
    buf.cells[i] = emptyCell

proc clear*(buf: var ScreenBuffer) =
  buf.curRow = 0
  buf.curCol = 0
  buf.curFg = -1
  buf.curBg = -1
  for i in 0..<buf.cells.len:
    buf.cells[i] = emptyCell

proc move*(buf: var ScreenBuffer, row, col: int) =
  buf.curRow = row
  buf.curCol = col

proc setFg*(buf: var ScreenBuffer, color: int) =
  buf.curFg = color

proc setBg*(buf: var ScreenBuffer, color: int) =
  buf.curBg = color

proc resetFg*(buf: var ScreenBuffer) =
  buf.curFg = -1

proc resetBg*(buf: var ScreenBuffer) =
  buf.curBg = -1

proc resetColors*(buf: var ScreenBuffer) =
  buf.curFg = -1
  buf.curBg = -1

proc write*(buf: var ScreenBuffer, s: string) =
  ## Write string at cursor position. Clips at buffer boundaries automatically.
  ## Supports negative curCol for horizontal scroll (left-edge clipping).
  var i = 0
  while i < s.len:
    if buf.curRow < 0 or buf.curRow >= buf.height:
      return
    if buf.curCol >= buf.width:
      return

    var r: Rune
    fastRuneAt(s, i, r)

    let dw = runeDisplayWidth(r)

    # Left clipping: skip characters starting before column 0
    if buf.curCol < 0:
      buf.curCol += dw
      continue

    # Right clipping: wide char partially outside
    if buf.curCol + dw > buf.width:
      return

    let idx = buf.curRow * buf.width + buf.curCol
    buf.cells[idx] = Cell(ch: $r, fg: buf.curFg, bg: buf.curBg)
    if dw == 2 and buf.curCol + 1 < buf.width:
      buf.cells[idx + 1] = Cell(ch: "", fg: buf.curFg, bg: buf.curBg, wide: true)
    buf.curCol += dw

proc clearToEol*(buf: var ScreenBuffer) =
  ## Fill remaining columns in current row with spaces using current colors.
  if buf.curRow < 0 or buf.curRow >= buf.height:
    return
  let startCol = max(0, buf.curCol)
  for col in startCol..<buf.width:
    let idx = buf.curRow * buf.width + col
    buf.cells[idx] = Cell(ch: " ", fg: buf.curFg, bg: buf.curBg)
  buf.curCol = buf.width

proc blit*(buf: ScreenBuffer, screenRow, screenCol: int) =
  ## Output buffer contents to terminal at given screen position (1-indexed).
  for row in 0..<buf.height:
    moveCursor(screenRow + row, screenCol)

    var batch = ""
    var batchFg = -2  # impossible value to force first color set
    var batchBg = -2

    for col in 0..<buf.width:
      let cell = buf.cells[row * buf.width + col]
      if cell.wide:
        continue  # skip second column of wide char

      let fg = if cell.fg < 0: defaultFg else: cell.fg
      let bg = if cell.bg < 0: defaultBg else: cell.bg

      if fg != batchFg or bg != batchBg:
        if batch.len > 0:
          stdout.write(batch)
          batch = ""
        if fg != batchFg:
          setColorFg(fg)
          batchFg = fg
        if bg != batchBg:
          setColorBg(bg)
          batchBg = bg

      batch.add(cell.ch)

    if batch.len > 0:
      stdout.write(batch)
