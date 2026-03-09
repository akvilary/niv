## Viewport: scrolling calculations with byte offset

import types
import buffer

proc lineNumberWidth*(lineCount: int): int =
  ## How many columns line numbers need (including 1 space padding)
  var digits = 1
  var n = lineCount
  while n >= 10:
    n = n div 10
    digits += 1
  result = digits + 1  # +1 for space after number

proc topLine*(vp: Viewport, buf: Buffer): int =
  ## Derive current top line from topByte
  buf.byteToLine(vp.topByte)

proc adjustViewport*(vp: var Viewport, cursor: Position, buf: Buffer) =
  let curTopLine = buf.byteToLine(vp.topByte)

  # Vertical scrolling
  var newTopLine = curTopLine
  if cursor.line < newTopLine:
    newTopLine = cursor.line
  elif cursor.line >= newTopLine + vp.height:
    newTopLine = cursor.line - vp.height + 1

  # Update topByte from the resolved line
  if newTopLine != curTopLine:
    vp.topByte = buf.lineToByteOffset(newTopLine)

  # Horizontal scrolling
  let lnw = lineNumberWidth(buf.lineCount)
  let textWidth = vp.width - lnw
  if textWidth > 0:
    if cursor.col < vp.leftCol:
      vp.leftCol = cursor.col
    elif cursor.col >= vp.leftCol + textWidth:
      vp.leftCol = cursor.col - textWidth + 1
