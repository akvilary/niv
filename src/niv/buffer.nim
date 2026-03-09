## Text buffer: raw bytes with line offset index

import std/strutils
import types
import fileio

# ---------------------------------------------------------------------------
# Line index helpers
# ---------------------------------------------------------------------------

proc buildLineIndex*(buf: var Buffer) =
  ## Rebuild lineIndex by scanning data for \n
  buf.lineIndex = @[0]
  for i in 0..<buf.data.len:
    if buf.data[i] == '\n':
      buf.lineIndex.add(i + 1)
  # If data ends with \n, remove phantom empty last line
  if buf.data.len > 0 and buf.data[^1] == '\n' and buf.lineIndex.len > 1:
    buf.lineIndex.setLen(buf.lineIndex.len - 1)

proc extendLineIndex*(buf: var Buffer, fromByte: int) =
  ## Extend lineIndex for newly appended bytes starting at fromByte
  for i in fromByte..<buf.data.len:
    if buf.data[i] == '\n':
      buf.lineIndex.add(i + 1)
  # If data ends with \n, ensure no phantom line
  if buf.data.len > 0 and buf.data[^1] == '\n' and
     buf.lineIndex.len > 1 and buf.lineIndex[^1] >= buf.data.len:
    buf.lineIndex.setLen(buf.lineIndex.len - 1)

proc byteToLine*(buf: Buffer, byteOffset: int): int =
  ## Binary search: find line containing byteOffset
  if buf.lineIndex.len == 0: return 0
  var lo = 0
  var hi = buf.lineIndex.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if buf.lineIndex[mid] <= byteOffset:
      lo = mid
    else:
      hi = mid - 1
  return lo

proc lineToByteOffset*(buf: Buffer, line: int): int =
  ## Get byte offset of line start
  if line >= 0 and line < buf.lineIndex.len:
    buf.lineIndex[line]
  elif buf.lineIndex.len > 0:
    buf.lineIndex[^1]
  else:
    0

proc byteOffsetOf*(buf: Buffer, pos: Position): int =
  ## Convert (line, col) to byte offset
  buf.lineToByteOffset(pos.line) + pos.col

proc positionOf*(buf: Buffer, byteOffset: int): Position =
  ## Convert byte offset to (line, col)
  let line = buf.byteToLine(byteOffset)
  Position(line: line, col: byteOffset - buf.lineToByteOffset(line))

# ---------------------------------------------------------------------------
# Line access (read-only, may allocate)
# ---------------------------------------------------------------------------

proc lineCount*(buf: Buffer): int =
  buf.lineIndex.len

proc lastLine*(buf: Buffer): int =
  buf.lineIndex.len - 1

proc lineEndByte*(buf: Buffer, lineNum: int): int =
  ## Byte offset past last content byte of line (before \n or at data.len)
  if lineNum + 1 < buf.lineIndex.len:
    # Next line starts after \n, so content ends at lineIndex[lineNum+1] - 1
    buf.lineIndex[lineNum + 1] - 1
  else:
    buf.data.len

proc getLine*(buf: Buffer, lineNum: int): string =
  if lineNum >= 0 and lineNum < buf.lineIndex.len:
    let s = buf.lineIndex[lineNum]
    let e = buf.lineEndByte(lineNum)
    if e > s:
      buf.data[s..<e]
    else:
      ""
  else:
    ""

proc lineLen*(buf: Buffer, lineNum: int): int =
  if lineNum >= 0 and lineNum < buf.lineIndex.len:
    buf.lineEndByte(lineNum) - buf.lineIndex[lineNum]
  else:
    0

proc getIndent*(buf: Buffer, lineNum: int): string =
  if lineNum >= 0 and lineNum < buf.lineIndex.len:
    let s = buf.lineIndex[lineNum]
    let e = buf.lineEndByte(lineNum)
    for i in s..<e:
      if buf.data[i] != ' ' and buf.data[i] != '\t':
        return buf.data[s..<i]
    return buf.data[s..<e]
  return ""

# ---------------------------------------------------------------------------
# lineIndex update after edits
# ---------------------------------------------------------------------------

proc shiftLineIndex(buf: var Buffer, fromLine: int, delta: int) =
  ## Shift all lineIndex entries from fromLine onwards by delta bytes
  for i in fromLine..<buf.lineIndex.len:
    buf.lineIndex[i] += delta

# ---------------------------------------------------------------------------
# Edit operations
# ---------------------------------------------------------------------------

proc insertChar*(buf: var Buffer, pos: Position, ch: char) =
  if pos.line >= 0 and pos.line < buf.lineIndex.len:
    let byteOff = buf.lineIndex[pos.line] + clamp(pos.col, 0, buf.lineLen(pos.line))
    buf.data.insert($ch, byteOff)
    buf.modified = true
    # If inserting \n, add new line entry
    if ch == '\n':
      buf.lineIndex.insert(byteOff + 1, pos.line + 1)
      buf.shiftLineIndex(pos.line + 2, 1)
    else:
      buf.shiftLineIndex(pos.line + 1, 1)

proc deleteChar*(buf: var Buffer, pos: Position): char =
  if pos.line >= 0 and pos.line < buf.lineIndex.len:
    let byteOff = buf.lineIndex[pos.line] + pos.col
    if byteOff < buf.data.len:
      result = buf.data[byteOff]
      buf.data.delete(byteOff..byteOff)
      buf.modified = true
      if result == '\n':
        # Merging two lines: remove lineIndex entry for next line
        if pos.line + 1 < buf.lineIndex.len:
          buf.lineIndex.delete(pos.line + 1)
        buf.shiftLineIndex(pos.line + 1, -1)
      else:
        buf.shiftLineIndex(pos.line + 1, -1)

proc insertLine*(buf: var Buffer, lineNum: int, text: string = "") =
  let ln = clamp(lineNum, 0, buf.lineIndex.len)
  let insertText = text & "\n"
  let byteOff = if ln < buf.lineIndex.len:
    buf.lineIndex[ln]
  else:
    buf.data.len
  buf.data.insert(insertText, byteOff)
  buf.lineIndex.insert(byteOff, ln)
  buf.shiftLineIndex(ln + 1, insertText.len)
  buf.modified = true

proc deleteLine*(buf: var Buffer, lineNum: int): string =
  if lineNum >= 0 and lineNum < buf.lineIndex.len and buf.lineIndex.len > 1:
    let s = buf.lineIndex[lineNum]
    # Include the \n delimiter
    let e = if lineNum + 1 < buf.lineIndex.len:
      buf.lineIndex[lineNum + 1]
    else:
      buf.data.len
    result = buf.data[s..<buf.lineEndByte(lineNum)]
    let deleteLen = e - s
    buf.data.delete(s..<e)
    buf.lineIndex.delete(lineNum)
    buf.shiftLineIndex(lineNum, -deleteLen)
    buf.modified = true
  elif buf.lineIndex.len == 1:
    result = buf.getLine(0)
    let s = buf.lineIndex[0]
    let e = buf.data.len
    if e > s:
      buf.data.delete(s..<e)
    buf.modified = true

proc splitLine*(buf: var Buffer, pos: Position) =
  if pos.line >= 0 and pos.line < buf.lineIndex.len:
    let byteOff = buf.lineIndex[pos.line] + clamp(pos.col, 0, buf.lineLen(pos.line))
    buf.data.insert("\n", byteOff)
    buf.lineIndex.insert(byteOff + 1, pos.line + 1)
    buf.shiftLineIndex(pos.line + 2, 1)
    buf.modified = true

proc joinLines*(buf: var Buffer, lineNum: int) =
  if lineNum >= 0 and lineNum + 1 < buf.lineIndex.len:
    # Delete the \n at end of lineNum
    let nlPos = buf.lineIndex[lineNum + 1] - 1
    if nlPos >= 0 and nlPos < buf.data.len and buf.data[nlPos] == '\n':
      buf.data.delete(nlPos..nlPos)
      buf.lineIndex.delete(lineNum + 1)
      buf.shiftLineIndex(lineNum + 1, -1)
      buf.modified = true

proc replaceLine*(buf: var Buffer, lineNum: int, text: string) =
  if lineNum >= 0 and lineNum < buf.lineIndex.len:
    let s = buf.lineIndex[lineNum]
    let e = buf.lineEndByte(lineNum)
    let oldLen = e - s
    let delta = text.len - oldLen
    if oldLen > 0:
      buf.data[s..<e] = text
    else:
      buf.data.insert(text, s)
    buf.shiftLineIndex(lineNum + 1, delta)
    buf.modified = true

# ---------------------------------------------------------------------------
# Byte-range edit (for undo system)
# ---------------------------------------------------------------------------

proc insertBytes*(buf: var Buffer, offset: int, text: string) =
  ## Insert raw bytes at offset, rebuild lineIndex for affected region
  buf.data.insert(text, offset)
  buf.modified = true
  # Rebuild lineIndex entirely (simple, correct)
  buf.buildLineIndex()

proc deleteBytes*(buf: var Buffer, offset: int, length: int) =
  ## Delete length bytes at offset, rebuild lineIndex
  if offset >= 0 and offset + length <= buf.data.len:
    buf.data.delete(offset..<(offset + length))
    buf.modified = true
    buf.buildLineIndex()

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

proc newBuffer*(filePath: string = ""): Buffer =
  result.filePath = filePath
  if filePath.len == 0:
    result.data = ""
    result.lineIndex = @[0]
    result.fullyLoaded = true
    result.modified = false
    result.encoding = "UTF-8"
    return

  let (data, bytesRead, totalSize, done, encoding) = loadFileFirstChunk(filePath)
  result.data = data
  result.totalSize = totalSize
  result.loadedBytes = bytesRead
  result.fullyLoaded = done
  result.modified = false
  result.encoding = encoding
  result.buildLineIndex()
  if bytesRead > 0 and result.lineIndex.len > 0:
    result.estimatedTotalLines = int(totalSize * int64(result.lineIndex.len) div bytesRead)
  else:
    result.estimatedTotalLines = result.lineIndex.len

  if not done:
    startFileLoader(filePath, bytesRead, totalSize - bytesRead)
