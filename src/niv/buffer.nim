## Text buffer: seq[string] with edit operations

import std/strutils
import types
import fileio

proc newBuffer*(filePath: string = ""): Buffer =
  result.filePath = filePath
  if filePath.len == 0:
    result.lines = @[""]
    result.fullyLoaded = true
    result.modified = false
    return

  let (lines, bytesRead, totalSize, done, carry) = loadFileFirstChunk(filePath)
  result.lines = lines
  result.totalSize = totalSize
  result.loadedBytes = bytesRead
  result.fullyLoaded = done
  result.modified = false

  if not done:
    startFileLoader(filePath, bytesRead, carry)

proc lineCount*(buf: Buffer): int =
  buf.lines.len

proc lastLine*(buf: Buffer): int =
  buf.lines.len - 1

proc getLine*(buf: Buffer, lineNum: int): string =
  if lineNum >= 0 and lineNum < buf.lines.len:
    buf.lines[lineNum]
  else:
    ""

proc lineLen*(buf: Buffer, lineNum: int): int =
  if lineNum >= 0 and lineNum < buf.lines.len:
    buf.lines[lineNum].len
  else:
    0

proc insertChar*(buf: var Buffer, pos: Position, ch: char) =
  if pos.line >= 0 and pos.line < buf.lines.len:
    let col = clamp(pos.col, 0, buf.lines[pos.line].len)
    buf.lines[pos.line].insert($ch, col)
    buf.modified = true

proc deleteChar*(buf: var Buffer, pos: Position): char =
  ## Delete char at pos, return the deleted char
  if pos.line >= 0 and pos.line < buf.lines.len:
    if pos.col >= 0 and pos.col < buf.lines[pos.line].len:
      result = buf.lines[pos.line][pos.col]
      buf.lines[pos.line].delete(pos.col..pos.col)
      buf.modified = true

proc insertLine*(buf: var Buffer, lineNum: int, text: string = "") =
  let ln = clamp(lineNum, 0, buf.lines.len)
  buf.lines.insert(text, ln)
  buf.modified = true

proc deleteLine*(buf: var Buffer, lineNum: int): string =
  ## Delete line and return its content
  if lineNum >= 0 and lineNum < buf.lines.len and buf.lines.len > 1:
    result = buf.lines[lineNum]
    buf.lines.delete(lineNum)
    buf.modified = true
  elif buf.lines.len == 1:
    result = buf.lines[0]
    buf.lines[0] = ""
    buf.modified = true

proc splitLine*(buf: var Buffer, pos: Position) =
  ## Split line at cursor position (Enter key)
  if pos.line >= 0 and pos.line < buf.lines.len:
    let col = clamp(pos.col, 0, buf.lines[pos.line].len)
    let rest = buf.lines[pos.line][col..^1]
    buf.lines[pos.line] = buf.lines[pos.line][0..<col]
    buf.lines.insert(rest, pos.line + 1)
    buf.modified = true

proc joinLines*(buf: var Buffer, lineNum: int) =
  ## Join line with the next line
  if lineNum >= 0 and lineNum < buf.lines.len - 1:
    buf.lines[lineNum].add(buf.lines[lineNum + 1])
    buf.lines.delete(lineNum + 1)
    buf.modified = true

proc replaceLine*(buf: var Buffer, lineNum: int, text: string) =
  if lineNum >= 0 and lineNum < buf.lines.len:
    buf.lines[lineNum] = text
    buf.modified = true
