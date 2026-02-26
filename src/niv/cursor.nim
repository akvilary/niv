## Cursor movement logic

import std/strutils
import types
import buffer

proc clampCursor*(buf: Buffer, pos: Position, mode: Mode): Position =
  result = pos
  # Clamp line
  if result.line < 0:
    result.line = 0
  elif result.line > buf.lastLine:
    result.line = buf.lastLine
  # Clamp column
  let maxCol = if mode == mInsert:
    buf.lineLen(result.line)  # can be at end of line
  else:
    max(buf.lineLen(result.line) - 1, 0)  # last char, not past it
  if result.col < 0:
    result.col = 0
  elif result.col > maxCol:
    result.col = maxCol

proc moveLeft*(buf: Buffer, pos: Position): Position =
  result = pos
  if result.col > 0:
    result.col -= 1

proc moveRight*(buf: Buffer, pos: Position, mode: Mode): Position =
  result = pos
  let maxCol = if mode == mInsert:
    buf.lineLen(result.line)
  else:
    max(buf.lineLen(result.line) - 1, 0)
  if result.col < maxCol:
    result.col += 1

proc moveUp*(buf: Buffer, pos: Position): Position =
  result = pos
  if result.line > 0:
    result.line -= 1
    let maxCol = max(buf.lineLen(result.line) - 1, 0)
    if result.col > maxCol:
      result.col = maxCol

proc moveDown*(buf: Buffer, pos: Position): Position =
  result = pos
  if result.line < buf.lastLine:
    result.line += 1
    let maxCol = max(buf.lineLen(result.line) - 1, 0)
    if result.col > maxCol:
      result.col = maxCol

proc moveToLineStart*(pos: Position): Position =
  result = pos
  result.col = 0

proc moveToLineEnd*(buf: Buffer, pos: Position, mode: Mode): Position =
  result = pos
  let lineL = buf.lineLen(result.line)
  if mode == mInsert:
    result.col = lineL
  else:
    result.col = max(lineL - 1, 0)

proc moveToTop*(): Position =
  Position(line: 0, col: 0)

proc moveToBottom*(buf: Buffer): Position =
  Position(line: buf.lastLine, col: 0)

proc isWordChar(c: char): bool =
  c.isAlphaAscii or c == '_' or c.isDigit

proc moveWordForward*(buf: Buffer, pos: Position): Position =
  result = pos
  let line = buf.getLine(result.line)
  let lineL = line.len
  if lineL == 0:
    # Move to next line
    if result.line < buf.lastLine:
      result.line += 1
      result.col = 0
    return

  # Skip current word
  var col = result.col
  if col < lineL and isWordChar(line[col]):
    while col < lineL and isWordChar(line[col]):
      col += 1
  elif col < lineL:
    while col < lineL and not isWordChar(line[col]) and line[col] != ' ':
      col += 1

  # Skip whitespace
  while col < lineL and line[col] == ' ':
    col += 1

  if col >= lineL:
    # Move to next line
    if result.line < buf.lastLine:
      result.line += 1
      result.col = 0
    else:
      result.col = max(lineL - 1, 0)
  else:
    result.col = col

proc moveWordBackward*(buf: Buffer, pos: Position): Position =
  result = pos
  if result.col == 0:
    if result.line > 0:
      result.line -= 1
      result.col = max(buf.lineLen(result.line) - 1, 0)
    return

  let line = buf.getLine(result.line)
  var col = result.col - 1

  # Skip whitespace
  while col > 0 and line[col] == ' ':
    col -= 1

  # Skip word
  if col >= 0 and isWordChar(line[col]):
    while col > 0 and isWordChar(line[col - 1]):
      col -= 1
  elif col >= 0:
    while col > 0 and not isWordChar(line[col - 1]) and line[col - 1] != ' ':
      col -= 1

  result.col = col

proc moveWordEnd*(buf: Buffer, pos: Position): Position =
  result = pos
  let line = buf.getLine(result.line)
  let lineL = line.len
  if lineL == 0:
    if result.line < buf.lastLine:
      result.line += 1
      result.col = max(buf.lineLen(result.line) - 1, 0)
    return

  var col = result.col + 1
  if col >= lineL:
    if result.line < buf.lastLine:
      result.line += 1
      let nextLine = buf.getLine(result.line)
      col = 0
      while col < nextLine.len and nextLine[col] == ' ':
        col += 1
      if col < nextLine.len and isWordChar(nextLine[col]):
        while col < nextLine.len - 1 and isWordChar(nextLine[col + 1]):
          col += 1
      elif col < nextLine.len:
        while col < nextLine.len - 1 and not isWordChar(nextLine[col + 1]) and nextLine[col + 1] != ' ':
          col += 1
      result.col = col
    return

  # Skip whitespace
  while col < lineL and line[col] == ' ':
    col += 1

  # Skip to end of word
  if col < lineL and isWordChar(line[col]):
    while col < lineL - 1 and isWordChar(line[col + 1]):
      col += 1
  elif col < lineL:
    while col < lineL - 1 and not isWordChar(line[col + 1]) and line[col + 1] != ' ':
      col += 1

  result.col = col
