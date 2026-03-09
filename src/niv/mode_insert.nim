## Insert mode key handler

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
  let deleteCount = state.cursor.col - completionState.triggerCol
  if deleteCount > 0:
    for i in 0..<deleteCount:
      state.cursor.col -= 1
      let ch = state.buffer.deleteChar(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDelete,
        offset: state.buffer.byteOffsetOf(state.cursor),
        text: $ch,
      ))

  # Insert the completion text
  for ch in insertText:
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsert,
      offset: state.buffer.byteOffsetOf(state.cursor),
      text: $ch,
    ))
    state.buffer.insertChar(state.cursor, ch)
    state.cursor.col += 1

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
    # Commit undo group and return to Normal mode
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
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsert,
      offset: state.buffer.byteOffsetOf(state.cursor),
      text: $key.ch,
    ))
    state.buffer.insertChar(state.cursor, key.ch)
    state.cursor.col += 1
    # Shift tokens right from insertion point
    shiftTokensRight(state.cursor.line, state.cursor.col - 1, 1)
    sendEditUpdate(state, state.cursor.line, state.cursor.line)

  of kkEnter:
    if completionState.active:
      acceptCompletion(state)
    else:
      let splitCol = state.cursor.col
      let indent = state.buffer.getIndent(state.cursor.line)
      let insertText = "\n" & indent
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
      # Auto-indent: insert indentation at start of new line
      if indent.len > 0:
        for i, ch in indent:
          state.buffer.insertChar(Position(line: state.cursor.line, col: i), ch)
        state.cursor.col = indent.len
      sendEditUpdate(state, state.cursor.line - 1, state.cursor.line)

  of kkBackspace:
    if completionState.active:
      closeCompletion()
    if state.cursor.col > 0:
      state.cursor.col -= 1
      let ch = state.buffer.deleteChar(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDelete,
        offset: state.buffer.byteOffsetOf(state.cursor),
        text: $ch,
      ))
      # Shift tokens left from deletion point
      shiftTokensLeft(state.cursor.line, state.cursor.col, 1)
      sendEditUpdate(state, state.cursor.line, state.cursor.line)
    elif state.cursor.line > 0:
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
      sendEditUpdate(state, state.cursor.line, state.cursor.line)

  of kkDelete:
    if completionState.active:
      closeCompletion()
    if state.cursor.col < state.buffer.lineLen(state.cursor.line):
      let delOffset = state.buffer.byteOffsetOf(state.cursor)
      let ch = state.buffer.deleteChar(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDelete,
        offset: delOffset,
        text: $ch,
      ))
      # Shift tokens left from deletion point
      shiftTokensLeft(state.cursor.line, state.cursor.col, 1)
      sendEditUpdate(state, state.cursor.line, state.cursor.line)
    elif state.cursor.line < state.buffer.lastLine:
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
      sendEditUpdate(state, state.cursor.line, state.cursor.line)

  of kkTab:
    if completionState.active:
      acceptCompletion(state)
    else:
      let tabSize = if activeLspLanguageId == "python": 4 else: 2
      for _ in 0..<tabSize:
        state.buffer.undo.pushUndo(UndoEntry(
          op: uoInsert,
          offset: state.buffer.byteOffsetOf(state.cursor),
          text: " ",
        ))
        state.buffer.insertChar(state.cursor, ' ')
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
    of ' ':
      # Ctrl-Space: trigger completion
      if lspState == lsRunning and lspDocumentUri.len > 0:
        # Send latest text first
        sendDidChange(state.buffer.data)
        # Send completion request
        let id = nextLspId()
        sendToLsp(buildCompletion(id, lspDocumentUri, state.cursor.line, state.cursor.col))
        addPendingRequest(id, "textDocument/completion")
        completionState.triggerCol = state.cursor.col
    of 'n':
      # Ctrl-N: next completion item
      if completionState.active and completionState.items.len > 0:
        completionState.selectedIndex = (completionState.selectedIndex + 1) mod completionState.items.len
    of 'p':
      # Ctrl-P: previous completion item
      if completionState.active and completionState.items.len > 0:
        completionState.selectedIndex = (completionState.selectedIndex - 1 + completionState.items.len) mod completionState.items.len
    else:
      discard

  else:
    discard
