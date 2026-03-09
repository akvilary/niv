## Cursor movement logic

import std/[strutils, unicode]
import types
import buffer

proc snapToRuneStart*(s: string, pos: int): int =
  ## Snap byte position to the start of the containing rune
  if pos <= 0: return 0
  var i = min(pos, s.len - 1)
  if i < 0: return 0
  while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
    dec i
  result = i

proc lastRuneStart*(s: string): int =
  ## Return byte offset of the last rune in s
  if s.len == 0: return 0
  snapToRuneStart(s, s.len - 1)

proc prevRuneStart*(s: string, pos: int): int =
  ## Return byte offset of the rune before the one at pos
  if pos <= 0: return 0
  var i = pos - 1
  while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
    dec i
  result = i

proc nextRuneStart*(s: string, pos: int): int =
  ## Return byte offset of the rune after the one at pos
  if pos >= s.len: return s.len
  let rl = runeLenAt(s, pos)
  result = min(pos + rl, s.len)

proc isWordCharAt*(s: string, pos: int): bool =
  ## Check if the rune at byte position pos is a word character
  if pos >= s.len: return false
  let b = ord(s[pos])
  if b < 0x80:
    return s[pos].isAlphaAscii or s[pos] == '_' or s[pos].isDigit
  else:
    let r = runeAt(s, pos)
    return r.isAlpha()

proc clampCursor*(buf: Buffer, pos: Position, mode: Mode): Position =
  result = pos
  # Clamp line
  if result.line < 0:
    result.line = 0
  elif result.line > buf.lastLine:
    result.line = buf.lastLine
  # Clamp column
  let lineL = buf.lineLen(result.line)
  if lineL == 0:
    result.col = 0
    return
  let line = buf.getLine(result.line)
  if mode == mInsert:
    if result.col < 0:
      result.col = 0
    elif result.col > lineL:
      result.col = lineL
    elif result.col > 0 and result.col < lineL:
      result.col = snapToRuneStart(line, result.col)
  else:
    let maxCol = lastRuneStart(line)
    if result.col < 0:
      result.col = 0
    elif result.col > maxCol:
      result.col = maxCol
    elif result.col > 0:
      result.col = snapToRuneStart(line, result.col)

proc moveLeft*(buf: Buffer, pos: Position): Position =
  result = pos
  if result.col > 0:
    let line = buf.getLine(result.line)
    result.col = prevRuneStart(line, result.col)

proc moveRight*(buf: Buffer, pos: Position, mode: Mode): Position =
  result = pos
  let lineL = buf.lineLen(result.line)
  if lineL == 0: return
  let line = buf.getLine(result.line)
  if mode == mInsert:
    if result.col < lineL:
      result.col = nextRuneStart(line, result.col)
  else:
    let maxCol = lastRuneStart(line)
    if result.col < maxCol:
      result.col = nextRuneStart(line, result.col)
      if result.col > maxCol:
        result.col = maxCol

proc moveUp*(buf: Buffer, pos: Position): Position =
  result = pos
  if result.line > 0:
    result.line -= 1
    let lineL = buf.lineLen(result.line)
    if lineL == 0:
      result.col = 0
    else:
      let line = buf.getLine(result.line)
      let maxCol = lastRuneStart(line)
      if result.col > maxCol:
        result.col = maxCol
      elif result.col > 0:
        result.col = snapToRuneStart(line, result.col)

proc moveDown*(buf: Buffer, pos: Position): Position =
  result = pos
  if result.line < buf.lastLine:
    result.line += 1
    let lineL = buf.lineLen(result.line)
    if lineL == 0:
      result.col = 0
    else:
      let line = buf.getLine(result.line)
      let maxCol = lastRuneStart(line)
      if result.col > maxCol:
        result.col = maxCol
      elif result.col > 0:
        result.col = snapToRuneStart(line, result.col)

proc moveToLineStart*(pos: Position): Position =
  result = pos
  result.col = 0

proc moveToLineEnd*(buf: Buffer, pos: Position, mode: Mode): Position =
  result = pos
  let lineL = buf.lineLen(result.line)
  if mode == mInsert:
    result.col = lineL
  else:
    if lineL == 0:
      result.col = 0
    else:
      let line = buf.getLine(result.line)
      result.col = lastRuneStart(line)

proc moveToTop*(): Position =
  Position(line: 0, col: 0)

proc moveToBottom*(buf: Buffer): Position =
  Position(line: buf.lastLine, col: 0)

proc moveWordForward*(buf: Buffer, pos: Position): Position =
  result = pos
  let line = buf.getLine(result.line)
  let lineL = line.len
  if lineL == 0:
    if result.line < buf.lastLine:
      result.line += 1
      result.col = 0
    return

  var col = result.col

  # Skip current word/non-word
  if col < lineL and isWordCharAt(line, col):
    while col < lineL and isWordCharAt(line, col):
      col = nextRuneStart(line, col)
  elif col < lineL and line[col] != ' ':
    while col < lineL and not isWordCharAt(line, col) and line[col] != ' ':
      col = nextRuneStart(line, col)

  # Skip whitespace
  while col < lineL and line[col] == ' ':
    col += 1

  if col >= lineL:
    if result.line < buf.lastLine:
      result.line += 1
      result.col = 0
    else:
      result.col = lastRuneStart(line)
  else:
    result.col = col

proc moveWordBackward*(buf: Buffer, pos: Position): Position =
  result = pos
  if result.col == 0:
    if result.line > 0:
      result.line -= 1
      let newLineL = buf.lineLen(result.line)
      if newLineL == 0:
        result.col = 0
      else:
        let newLine = buf.getLine(result.line)
        result.col = lastRuneStart(newLine)
    return

  let line = buf.getLine(result.line)
  var col = prevRuneStart(line, result.col)

  # Skip whitespace
  while col > 0 and line[col] == ' ':
    col = prevRuneStart(line, col)

  # Skip word/non-word
  if col < line.len and isWordCharAt(line, col):
    while col > 0:
      let prev = prevRuneStart(line, col)
      if not isWordCharAt(line, prev): break
      col = prev
  elif col < line.len:
    while col > 0:
      let prev = prevRuneStart(line, col)
      if isWordCharAt(line, prev) or line[prev] == ' ': break
      col = prev

  result.col = col

proc moveWordEnd*(buf: Buffer, pos: Position): Position =
  result = pos
  let line = buf.getLine(result.line)
  let lineL = line.len
  if lineL == 0:
    if result.line < buf.lastLine:
      result.line += 1
      let newLine = buf.getLine(result.line)
      if newLine.len == 0:
        result.col = 0
      else:
        result.col = lastRuneStart(newLine)
    return

  var col = nextRuneStart(line, result.col)
  if col >= lineL:
    if result.line < buf.lastLine:
      result.line += 1
      let nextLine = buf.getLine(result.line)
      col = 0
      while col < nextLine.len and nextLine[col] == ' ':
        col += 1
      if col < nextLine.len:
        if isWordCharAt(nextLine, col):
          var nxt = nextRuneStart(nextLine, col)
          while nxt < nextLine.len and isWordCharAt(nextLine, nxt):
            col = nxt
            nxt = nextRuneStart(nextLine, nxt)
        else:
          var nxt = nextRuneStart(nextLine, col)
          while nxt < nextLine.len and not isWordCharAt(nextLine, nxt) and nextLine[nxt] != ' ':
            col = nxt
            nxt = nextRuneStart(nextLine, nxt)
      result.col = col
    return

  # Skip whitespace
  while col < lineL and line[col] == ' ':
    col += 1

  # Skip to end of word
  if col < lineL and isWordCharAt(line, col):
    var nxt = nextRuneStart(line, col)
    while nxt < lineL and isWordCharAt(line, nxt):
      col = nxt
      nxt = nextRuneStart(line, nxt)
  elif col < lineL:
    var nxt = nextRuneStart(line, col)
    while nxt < lineL and not isWordCharAt(line, nxt) and line[nxt] != ' ':
      col = nxt
      nxt = nextRuneStart(line, nxt)

  result.col = col
