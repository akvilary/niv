## Undo/redo history management

import types
import buffer
import highlight

proc pushUndo*(hist: var UndoHistory, entry: UndoEntry) =
  hist.current.entries.add(entry)
  hist.redoStack.setLen(0)  # new edit clears redo

proc commitGroup*(hist: var UndoHistory) =
  if hist.current.entries.len > 0:
    hist.undoStack.add(hist.current)
    hist.current = UndoGroup()

proc undoOne(entry: UndoEntry, buf: var Buffer): Position =
  result = entry.pos
  case entry.op
  of uoInsertChar:
    discard buf.deleteChar(entry.pos)
    shiftTokensLeft(entry.pos.line, entry.pos.col, 1)
  of uoDeleteChar:
    buf.insertChar(entry.pos, entry.text[0])
    shiftTokensRight(entry.pos.line, entry.pos.col, 1)
  of uoInsertLine:
    discard buf.deleteLine(entry.pos.line)
    deleteSemanticLine(entry.pos.line)
  of uoDeleteLine:
    buf.insertLine(entry.pos.line, entry.text)
    insertSemanticLine(entry.pos.line)
  of uoReplaceLine:
    buf.replaceLine(entry.pos.line, entry.text)
  of uoSplitLine:
    buf.joinLines(entry.pos.line)
    joinSemanticLines(entry.pos.line, entry.pos.col)
  of uoJoinLines:
    buf.splitLine(entry.pos)
    splitSemanticLine(entry.pos.line, entry.pos.col)

proc undo*(hist: var UndoHistory, buf: var Buffer): Position =
  commitGroup(hist)  # commit any pending edits
  if hist.undoStack.len == 0:
    return Position(line: 0, col: 0)
  let group = hist.undoStack.pop()
  hist.redoStack.add(group)
  # Apply entries in reverse order
  for i in countdown(group.entries.len - 1, 0):
    result = undoOne(group.entries[i], buf)

proc redoOne(entry: UndoEntry, buf: var Buffer): Position =
  result = entry.pos
  case entry.op
  of uoInsertChar:
    buf.insertChar(entry.pos, entry.text[0])
    shiftTokensRight(entry.pos.line, entry.pos.col, 1)
    result.col += 1
  of uoDeleteChar:
    discard buf.deleteChar(entry.pos)
    shiftTokensLeft(entry.pos.line, entry.pos.col, 1)
  of uoInsertLine:
    buf.insertLine(entry.pos.line, entry.text)
    insertSemanticLine(entry.pos.line)
  of uoDeleteLine:
    discard buf.deleteLine(entry.pos.line)
    deleteSemanticLine(entry.pos.line)
  of uoReplaceLine:
    let old = buf.getLine(entry.pos.line)
    buf.replaceLine(entry.pos.line, entry.lines[0])
    discard old
  of uoSplitLine:
    buf.splitLine(entry.pos)
    splitSemanticLine(entry.pos.line, entry.pos.col)
  of uoJoinLines:
    buf.joinLines(entry.pos.line)
    joinSemanticLines(entry.pos.line, entry.pos.col)

proc redo*(hist: var UndoHistory, buf: var Buffer): Position =
  if hist.redoStack.len == 0:
    return Position(line: 0, col: 0)
  let group = hist.redoStack.pop()
  hist.undoStack.add(group)
  for entry in group.entries:
    result = redoOne(entry, buf)
