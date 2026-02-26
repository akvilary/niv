## Insert mode key handler

import types
import buffer
import cursor
import undo

proc handleInsertMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    # Commit undo group and return to Normal mode
    state.buffer.undo.commitGroup()
    state.mode = mNormal
    # Clamp cursor (in Normal, cursor can't be past last char)
    state.cursor = clampCursor(state.buffer, state.cursor, mNormal)

  of kkChar:
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsertChar,
      pos: state.cursor,
      text: $key.ch,
    ))
    state.buffer.insertChar(state.cursor, key.ch)
    state.cursor.col += 1

  of kkEnter:
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoSplitLine,
      pos: state.cursor,
    ))
    state.buffer.splitLine(state.cursor)
    state.cursor.line += 1
    state.cursor.col = 0

  of kkBackspace:
    if state.cursor.col > 0:
      state.cursor.col -= 1
      let ch = state.buffer.deleteChar(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDeleteChar,
        pos: state.cursor,
        text: $ch,
      ))
    elif state.cursor.line > 0:
      # Join with previous line
      let prevLineLen = state.buffer.lineLen(state.cursor.line - 1)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoJoinLines,
        pos: Position(line: state.cursor.line - 1, col: prevLineLen),
      ))
      state.buffer.joinLines(state.cursor.line - 1)
      state.cursor.line -= 1
      state.cursor.col = prevLineLen

  of kkDelete:
    if state.cursor.col < state.buffer.lineLen(state.cursor.line):
      let ch = state.buffer.deleteChar(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDeleteChar,
        pos: state.cursor,
        text: $ch,
      ))
    elif state.cursor.line < state.buffer.lastLine:
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoJoinLines,
        pos: state.cursor,
      ))
      state.buffer.joinLines(state.cursor.line)

  of kkTab:
    # Insert 2 spaces for tab
    for _ in 0..1:
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoInsertChar,
        pos: state.cursor,
        text: " ",
      ))
      state.buffer.insertChar(state.cursor, ' ')
      state.cursor.col += 1

  of kkArrowUp:
    state.cursor = moveUp(state.buffer, state.cursor)
  of kkArrowDown:
    state.cursor = moveDown(state.buffer, state.cursor)
  of kkArrowLeft:
    state.cursor = moveLeft(state.buffer, state.cursor)
  of kkArrowRight:
    state.cursor = moveRight(state.buffer, state.cursor, mInsert)
  of kkHome:
    state.cursor = moveToLineStart(state.cursor)
  of kkEnd:
    state.cursor = moveToLineEnd(state.buffer, state.cursor, mInsert)

  of kkCtrlKey:
    discard  # ignore ctrl keys in insert mode for now

  else:
    discard
