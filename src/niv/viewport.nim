## Viewport: scrolling calculations

import types
import buffer
import unicode_width

proc lineNumberWidth*(lineCount: int): int =
  ## How many columns line numbers need (including 1 space padding)
  var digits = 1
  var n = lineCount
  while n >= 10:
    n = n div 10
    digits += 1
  result = digits + 1  # +1 for space after number

proc adjustViewport*(vp: var Viewport, cursor: Position, buf: Buffer) =
  # Vertical scrolling
  if cursor.line < vp.topLine:
    vp.topLine = cursor.line
  elif cursor.line >= vp.topLine + vp.height:
    vp.topLine = cursor.line - vp.height + 1

  # Horizontal scrolling (cursor.col is byte offset, textWidth is display columns)
  let lnw = lineNumberWidth(buf.lineCount)
  let textWidth = vp.width - lnw
  if textWidth > 0:
    let line = buf.getLine(cursor.line)
    let rightEdgeByte = byteOffsetForWidth(line, vp.leftCol, textWidth)
    if cursor.col < vp.leftCol:
      vp.leftCol = cursor.col
    elif cursor.col >= rightEdgeByte:
      vp.leftCol = byteOffsetBackward(line, cursor.col, textWidth - 1)
