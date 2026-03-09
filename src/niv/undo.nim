## Undo/redo history management — byte-range operations

import std/strutils
import types
import buffer
import highlight

proc pushUndo*(hist: var UndoHistory, entry: UndoEntry) =
  hist.current.entries.add(entry)
  hist.redoStack.setLen(0)  # new edit clears redo

proc ensureTokensCaptured*(hist: var UndoHistory, line: int) =
  ## Lazily capture "before" tokens for a line about to be modified.
  ## Must be called BEFORE modifying tokens on that line.
  if not hist.captureActive:
    hist.captureActive = true
    hist.captureMinLine = line
    hist.captureMaxLine = line + 1
    hist.captureAfterEndLine = line + 1
    hist.current.tokenDiff.startLine = line
    hist.current.tokenDiff.linesBefore = captureTokenLines(line, line + 1)
  elif line < hist.captureMinLine:
    let extra = captureTokenLines(line, hist.captureMinLine)
    hist.current.tokenDiff.linesBefore = extra & hist.current.tokenDiff.linesBefore
    hist.captureMinLine = line
    hist.current.tokenDiff.startLine = line
  elif line >= hist.captureMaxLine and line >= hist.captureAfterEndLine:
    let extra = captureTokenLines(hist.captureMaxLine, line + 1)
    hist.current.tokenDiff.linesBefore.add(extra)
    hist.captureMaxLine = line + 1
    hist.captureAfterEndLine = line + 1

proc trackLineInserted*(hist: var UndoHistory) =
  if hist.captureActive:
    hist.captureAfterEndLine += 1

proc trackLineRemoved*(hist: var UndoHistory) =
  if hist.captureActive:
    hist.captureAfterEndLine -= 1

proc finishTokenCapture*(hist: var UndoHistory) =
  if hist.captureActive:
    hist.current.tokenDiff.linesAfter = captureTokenLines(
      hist.captureMinLine, hist.captureAfterEndLine)
    hist.captureActive = false

proc commitGroup*(hist: var UndoHistory) =
  if hist.current.entries.len > 0:
    if hist.captureActive:
      finishTokenCapture(hist)
    hist.undoStack.add(hist.current)
    hist.current = UndoGroup()

proc undoOne(entry: UndoEntry, buf: var Buffer): Position =
  case entry.op
  of uoInsert:
    let pos = buf.positionOf(entry.offset)
    buf.deleteBytes(entry.offset, entry.text.len)
    result = pos
  of uoDelete:
    buf.insertBytes(entry.offset, entry.text)
    result = buf.positionOf(entry.offset)

type UndoResult* = object
  cursor*: Position
  minLine*: int
  maxLine*: int
  tokenDiff*: TokenDiff

proc undo*(hist: var UndoHistory, buf: var Buffer): UndoResult =
  commitGroup(hist)  # commit any pending edits
  if hist.undoStack.len == 0:
    return UndoResult(cursor: Position(line: 0, col: 0), minLine: 0, maxLine: 0)
  let group = hist.undoStack.pop()
  hist.redoStack.add(group)
  result.tokenDiff = group.tokenDiff
  result.minLine = int.high
  result.maxLine = 0
  # Apply entries in reverse order
  for i in countdown(group.entries.len - 1, 0):
    let pos = undoOne(group.entries[i], buf)
    result.cursor = pos
    let entryLines = group.entries[i].text.count('\n')
    result.minLine = min(result.minLine, pos.line)
    result.maxLine = max(result.maxLine, pos.line + entryLines)
  result.maxLine = min(result.maxLine, buf.lineCount - 1)
  if result.minLine == int.high:
    result.minLine = 0

proc redoOne(entry: UndoEntry, buf: var Buffer): Position =
  case entry.op
  of uoInsert:
    buf.insertBytes(entry.offset, entry.text)
    result = buf.positionOf(entry.offset + entry.text.len)
  of uoDelete:
    let pos = buf.positionOf(entry.offset)
    buf.deleteBytes(entry.offset, entry.text.len)
    result = pos

proc redo*(hist: var UndoHistory, buf: var Buffer): UndoResult =
  if hist.redoStack.len == 0:
    return UndoResult(cursor: Position(line: 0, col: 0), minLine: 0, maxLine: 0)
  let group = hist.redoStack.pop()
  hist.undoStack.add(group)
  result.tokenDiff = group.tokenDiff
  result.minLine = int.high
  result.maxLine = 0
  for entry in group.entries:
    let pos = redoOne(entry, buf)
    result.cursor = pos
    let entryLines = entry.text.count('\n')
    result.minLine = min(result.minLine, pos.line)
    result.maxLine = max(result.maxLine, pos.line + entryLines)
  result.maxLine = min(result.maxLine, buf.lineCount - 1)
  if result.minLine == int.high:
    result.minLine = 0
