## Insert mode key handler

import std/unicode
import types
import buffer
import cursor
import undo
import lsp_types
import lsp_client
import lsp_protocol
import highlight

proc acceptCompletion(state: var EditorState) =
  ## Accept the currently selected completion item
  if not completionState.active or completionState.items.len == 0:
    return
  let item = completionState.items[completionState.selectedIndex]
  let insertText = if item.insertText.len > 0: item.insertText else: item.label

  # Delete from triggerCol to cursor.col (the partial typed text)
  while state.cursor.col > completionState.triggerCol:
    let line = state.buffer.getLine(state.cursor.line)
    state.cursor.col = prevRuneStart(line, state.cursor.col)
    let deleted = state.buffer.deleteRune(state.cursor)
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoDelete,
      offset: state.buffer.byteOffsetOf(state.cursor),
      text: deleted,
    ))

  # Insert the completion text
  for r in insertText.runes:
    let text = $r
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsert,
      offset: state.buffer.byteOffsetOf(state.cursor),
      text: text,
    ))
    state.buffer.insertRune(state.cursor, r)
    state.cursor.col += text.len

  completionState.active = false
  completionState.items = @[]

proc closeCompletion*() =
  completionState.active = false
  completionState.items = @[]

proc sendEditUpdate(state: EditorState, startLine, endLine: int) =
  ## Send didChange + request range tokens for edited lines
  if lspState != lsRunning or state.buffer.filePath.len == 0:
    return
  sendDidChange(state.buffer.data)
  lspSyncedLines = state.buffer.lineCount
  resetViewportRangeCache()
  if tokenLegend.len > 0 and lspHasSemanticTokensRange:
    sendSemanticTokensRange(startLine, endLine, isEdit = true)

proc handleInsertMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    closeCompletion()
    # Finish token capture and commit undo group
    state.buffer.undo.finishTokenCapture()
    state.buffer.undo.commitGroup()
    state.mode = mNormal
    # Clamp cursor (in Normal, cursor can't be past last char)
    state.cursor = clampCursor(state.buffer, state.cursor, mNormal)
    # Final LSP sync
    if lspIsActive() and state.buffer.filePath.len > 0:
      sendDidChange(state.buffer.data)
      lspSyncedLines = state.buffer.lineCount

  of kkChar:
    if completionState.active:
      closeCompletion()
    let text = $key.ch
    state.buffer.undo.ensureTokensCaptured(state.cursor.line)
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsert,
      offset: state.buffer.byteOffsetOf(state.cursor),
      text: text,
    ))
    state.buffer.insertRune(state.cursor, key.ch)
    state.cursor.col += text.len
    # Shift tokens right from insertion point
    shiftTokensRight(state.cursor.line, state.cursor.col - text.len, text.len)
    sendEditUpdate(state, state.cursor.line, state.cursor.line)

  of kkEnter:
    if completionState.active:
      acceptCompletion(state)
    else:
      let splitCol = state.cursor.col
      let indent = state.buffer.getIndent(state.cursor.line)
      let insertText = "\n" & indent
      state.buffer.undo.ensureTokensCaptured(state.cursor.line)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoInsert,
        offset: state.buffer.byteOffsetOf(state.cursor),
        text: insertText,
      ))
      state.buffer.splitLine(state.cursor)
      state.cursor.line += 1
      state.cursor.col = 0
      # Split semantic tokens at the split point
      splitSemanticLine(state.cursor.line - 1, splitCol)
      state.buffer.undo.trackLineInserted()
      # Auto-indent: insert indentation at start of new line
      if indent.len > 0:
        for r in indent.runes:
          state.buffer.insertRune(Position(line: state.cursor.line, col: state.cursor.col), r)
          state.cursor.col += ($r).len
      sendEditUpdate(state, state.cursor.line - 1, state.cursor.line)

  of kkBackspace:
    if completionState.active:
      closeCompletion()
    if state.cursor.col > 0:
      state.buffer.undo.ensureTokensCaptured(state.cursor.line)
      let line = state.buffer.getLine(state.cursor.line)
      state.cursor.col = prevRuneStart(line, state.cursor.col)
      let deleted = state.buffer.deleteRune(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDelete,
        offset: state.buffer.byteOffsetOf(state.cursor),
        text: deleted,
      ))
      # Shift tokens left from deletion point
      shiftTokensLeft(state.cursor.line, state.cursor.col, deleted.len)
      sendEditUpdate(state, state.cursor.line, state.cursor.line)
    elif state.cursor.line > 0:
      # Capture both lines before join
      state.buffer.undo.ensureTokensCaptured(state.cursor.line - 1)
      state.buffer.undo.ensureTokensCaptured(state.cursor.line)
      # Join with previous line
      let prevLineLen = state.buffer.lineLen(state.cursor.line - 1)
      let joinOffset = state.buffer.byteOffsetOf(Position(line: state.cursor.line - 1, col: prevLineLen))
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDelete,
        offset: joinOffset,
        text: "\n",
      ))
      state.buffer.joinLines(state.cursor.line - 1)
      state.cursor.line -= 1
      state.cursor.col = prevLineLen
      # Merge semantic tokens from joined line
      joinSemanticLines(state.cursor.line, state.cursor.col)
      state.buffer.undo.trackLineRemoved()
      sendEditUpdate(state, state.cursor.line, state.cursor.line)

  of kkDelete:
    if completionState.active:
      closeCompletion()
    if state.cursor.col < state.buffer.lineLen(state.cursor.line):
      state.buffer.undo.ensureTokensCaptured(state.cursor.line)
      let delOffset = state.buffer.byteOffsetOf(state.cursor)
      let deleted = state.buffer.deleteRune(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDelete,
        offset: delOffset,
        text: deleted,
      ))
      # Shift tokens left from deletion point
      shiftTokensLeft(state.cursor.line, state.cursor.col, deleted.len)
      sendEditUpdate(state, state.cursor.line, state.cursor.line)
    elif state.cursor.line < state.buffer.lastLine:
      # Capture both lines before join
      state.buffer.undo.ensureTokensCaptured(state.cursor.line)
      state.buffer.undo.ensureTokensCaptured(state.cursor.line + 1)
      let joinCol = state.buffer.lineLen(state.cursor.line)
      let joinOffset = state.buffer.byteOffsetOf(Position(line: state.cursor.line, col: joinCol))
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDelete,
        offset: joinOffset,
        text: "\n",
      ))
      state.buffer.joinLines(state.cursor.line)
      # Merge semantic tokens from joined line
      joinSemanticLines(state.cursor.line, joinCol)
      state.buffer.undo.trackLineRemoved()
      sendEditUpdate(state, state.cursor.line, state.cursor.line)

  of kkTab:
    if completionState.active:
      acceptCompletion(state)
    else:
      state.buffer.undo.ensureTokensCaptured(state.cursor.line)
      let tabSize = if activeLspLanguageId == "python": 4 else: 2
      for _ in 0..<tabSize:
        state.buffer.undo.pushUndo(UndoEntry(
          op: uoInsert,
          offset: state.buffer.byteOffsetOf(state.cursor),
          text: " ",
        ))
        state.buffer.insertRune(state.cursor, Rune(ord(' ')))
        state.cursor.col += 1
      shiftTokensRight(state.cursor.line, state.cursor.col - tabSize, tabSize)
      sendEditUpdate(state, state.cursor.line, state.cursor.line)

  of kkArrowUp:
    if completionState.active:
      closeCompletion()
    state.cursor = moveUp(state.buffer, state.cursor)
  of kkArrowDown:
    if completionState.active:
      closeCompletion()
    state.cursor = moveDown(state.buffer, state.cursor)
  of kkArrowLeft:
    if completionState.active:
      closeCompletion()
    state.cursor = moveLeft(state.buffer, state.cursor)
  of kkArrowRight:
    if completionState.active:
      closeCompletion()
    state.cursor = moveRight(state.buffer, state.cursor, mInsert)
  of kkHome:
    state.cursor = moveToLineStart(state.cursor)
  of kkEnd:
    state.cursor = moveToLineEnd(state.buffer, state.cursor, mInsert)

  of kkCtrlKey:
    case key.ctrl
    of Rune(ord(' ')):
      # Ctrl-Space: trigger completion
      if lspState == lsRunning and lspDocumentUri.len > 0:
        # Send latest text first
        sendDidChange(state.buffer.data)
        # Send completion request
        let id = nextLspId()
        sendToLsp(buildCompletion(id, lspDocumentUri, state.cursor.line, state.cursor.col))
        addPendingRequest(id, "textDocument/completion")
        completionState.triggerCol = state.cursor.col
    of Rune(ord('n')):
      # Ctrl-N: next completion item
      if completionState.active and completionState.items.len > 0:
        completionState.selectedIndex = (completionState.selectedIndex + 1) mod completionState.items.len
    of Rune(ord('p')):
      # Ctrl-P: previous completion item
      if completionState.active and completionState.items.len > 0:
        completionState.selectedIndex = (completionState.selectedIndex - 1 + completionState.items.len) mod completionState.items.len
    else:
      discard

  else:
    discard
