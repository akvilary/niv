## Undo/redo history management — byte-range operations

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
  case entry.op
  of uoInsert:
    # Undo insert = delete the inserted bytes
    let pos = buf.positionOf(entry.offset)
    buf.deleteBytes(entry.offset, entry.text.len)
    # Update semantic tokens
    if entry.text == "\n":
      joinSemanticLines(pos.line, pos.col)
    elif entry.text.len == 1:
      shiftTokensLeft(pos.line, pos.col, 1)
    result = pos
  of uoDelete:
    # Undo delete = re-insert the deleted bytes
    buf.insertBytes(entry.offset, entry.text)
    let pos = buf.positionOf(entry.offset)
    # Update semantic tokens
    if entry.text == "\n":
      splitSemanticLine(pos.line, pos.col)
    elif entry.text.len == 1:
      shiftTokensRight(pos.line, pos.col, 1)
    result = pos

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
  case entry.op
  of uoInsert:
    # Redo insert = re-insert the bytes
    buf.insertBytes(entry.offset, entry.text)
    let pos = buf.positionOf(entry.offset + entry.text.len)
    if entry.text == "\n":
      splitSemanticLine(pos.line - 1, 0)
    elif entry.text.len == 1:
      let insPos = buf.positionOf(entry.offset)
      shiftTokensRight(insPos.line, insPos.col, 1)
    result = pos
  of uoDelete:
    # Redo delete = delete again
    let pos = buf.positionOf(entry.offset)
    buf.deleteBytes(entry.offset, entry.text.len)
    if entry.text == "\n":
      joinSemanticLines(pos.line, pos.col)
    elif entry.text.len == 1:
      shiftTokensLeft(pos.line, pos.col, 1)
    result = pos

proc redo*(hist: var UndoHistory, buf: var Buffer): Position =
  if hist.redoStack.len == 0:
    return Position(line: 0, col: 0)
  let group = hist.redoStack.pop()
  hist.undoStack.add(group)
  for entry in group.entries:
    result = redoOne(entry, buf)
