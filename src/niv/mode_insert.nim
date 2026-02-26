## Insert mode key handler

import std/strutils
import types
import buffer
import cursor
import undo
import lsp_types
import lsp_client
import lsp_protocol
import highlight
import ts_highlight

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
        op: uoDeleteChar,
        pos: state.cursor,
        text: $ch,
      ))

  # Insert the completion text
  for ch in insertText:
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsertChar,
      pos: state.cursor,
      text: $ch,
    ))
    state.buffer.insertChar(state.cursor, ch)
    state.cursor.col += 1

  completionState.active = false
  completionState.items = @[]

proc closeCompletion*() =
  completionState.active = false
  completionState.items = @[]

proc handleInsertMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    closeCompletion()
    # Commit undo group and return to Normal mode
    state.buffer.undo.commitGroup()
    state.mode = mNormal
    # Clamp cursor (in Normal, cursor can't be past last char)
    state.cursor = clampCursor(state.buffer, state.cursor, mNormal)
    # Notify LSP of buffer changes
    if lspIsActive() and state.buffer.filePath.len > 0:
      sendDidChange(state.buffer.lines.join("\n"))
      # Re-request semantic tokens
      if tokenLegend.len > 0:
        let stId = nextLspId()
        sendToLsp(buildSemanticTokensFull(stId, lspDocumentUri))
        addPendingRequest(stId, "textDocument/semanticTokens/full")
    # Re-highlight with tree-sitter (if active)
    if tsState.active and state.buffer.filePath.len > 0:
      tsParseAndHighlight(state.buffer.lines.join("\n"), state.buffer.lineCount)

  of kkChar:
    if completionState.active:
      closeCompletion()
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsertChar,
      pos: state.cursor,
      text: $key.ch,
    ))
    state.buffer.insertChar(state.cursor, key.ch)
    state.cursor.col += 1

  of kkEnter:
    if completionState.active:
      acceptCompletion(state)
    else:
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoSplitLine,
        pos: state.cursor,
      ))
      state.buffer.splitLine(state.cursor)
      state.cursor.line += 1
      state.cursor.col = 0

  of kkBackspace:
    if completionState.active:
      closeCompletion()
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
    if completionState.active:
      closeCompletion()
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
    if completionState.active:
      acceptCompletion(state)
    else:
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
        sendDidChange(state.buffer.lines.join("\n"))
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
