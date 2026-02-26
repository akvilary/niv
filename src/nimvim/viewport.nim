## Viewport: scrolling calculations

import types

proc lineNumberWidth*(lineCount: int): int =
  ## How many columns line numbers need (including 1 space padding)
  var digits = 1
  var n = lineCount
  while n >= 10:
    n = n div 10
    digits += 1
  result = digits + 1  # +1 for space after number

proc adjustViewport*(vp: var Viewport, cursor: Position, lineCount: int) =
  # Vertical scrolling
  if cursor.line < vp.topLine:
    vp.topLine = cursor.line
  elif cursor.line >= vp.topLine + vp.height:
    vp.topLine = cursor.line - vp.height + 1

  # Horizontal scrolling
  let lnw = lineNumberWidth(lineCount)
  let textWidth = vp.width - lnw
  if textWidth > 0:
    if cursor.col < vp.leftCol:
      vp.leftCol = cursor.col
    elif cursor.col >= vp.leftCol + textWidth:
      vp.leftCol = cursor.col - textWidth + 1
