## Normal mode key handler

import std/strutils
import types
import buffer
import cursor
import input
import undo
import sidebar
import lsp_types
import lsp_client
import lsp_protocol
import highlight
import fileio
import jumplist
import git

proc handleNormalMode*(state: var EditorState, key: InputKey) =
  state.statusMessage = ""

  # Sidebar keybindings (checked before input sequence parser)
  if key.kind == kkCtrlKey:
    case key.ctrl
    of 'b':
      toggleSidebar(state.sidebar)
      if state.sidebar.visible:
        state.sidebar.focused = true
        state.mode = mExplore
      return
    of 'w':
      if state.sidebar.visible:
        state.sidebar.focused = true
        state.mode = mExplore
        return
    of 'g':
      if state.gitPanel.visible:
        closeGitPanel(state.gitPanel)
        state.mode = mNormal
      else:
        openGitPanel(state.gitPanel)
        state.mode = mGit
      return
    else:
      discard

  if key.kind == kkTab:
    if state.sidebar.visible:
      state.sidebar.focused = true
      state.mode = mExplore
      return

  let ir = processNormalKey(state.pendingKeys, key)
  if not ir.complete:
    return

  # Block editing operations while file is loading — cursor movement always works
  const loadingBlocked = {akInsertBefore, akInsertAfter, akInsertLineBelow,
    akInsertLineAbove, akDeleteChar, akDeleteLine, akPaste, akPasteBefore,
    akUndo, akRedo, akGotoDefinition}
  if ir.action in loadingBlocked and not state.buffer.fullyLoaded:
    state.statusMessage = "File still loading..."
    return

  case ir.action
  # Movement
  of akMoveLeft:
    state.cursor = moveLeft(state.buffer, state.cursor)
  of akMoveRight:
    state.cursor = moveRight(state.buffer, state.cursor, mNormal)
  of akMoveUp:
    state.cursor = moveUp(state.buffer, state.cursor)
  of akMoveDown:
    state.cursor = moveDown(state.buffer, state.cursor)
  of akMoveWordForward:
    state.cursor = moveWordForward(state.buffer, state.cursor)
  of akMoveWordBackward:
    state.cursor = moveWordBackward(state.buffer, state.cursor)
  of akMoveWordEnd:
    state.cursor = moveWordEnd(state.buffer, state.cursor)
  of akMoveLineStart:
    state.cursor = moveToLineStart(state.cursor)
  of akMoveLineEnd:
    state.cursor = moveToLineEnd(state.buffer, state.cursor, mNormal)
  of akMoveToTop:
    state.cursor = moveToTop()
  of akMoveToBottom:
    state.cursor = moveToBottom(state.buffer)
  of akPageUp:
    for _ in 0..<state.viewport.height:
      state.cursor = moveUp(state.buffer, state.cursor)
  of akPageDown:
    for _ in 0..<state.viewport.height:
      state.cursor = moveDown(state.buffer, state.cursor)

  # Enter insert mode
  of akInsertBefore:
    state.mode = mInsert
  of akInsertAfter:
    if state.buffer.lineLen(state.cursor.line) > 0:
      state.cursor.col += 1
    state.mode = mInsert
  of akInsertLineBelow:
    let lineNum = state.cursor.line
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsertLine,
      pos: Position(line: lineNum + 1, col: 0),
      text: "",
    ))
    state.buffer.undo.commitGroup()
    state.buffer.insertLine(lineNum + 1, "")
    state.cursor = Position(line: lineNum + 1, col: 0)
    state.mode = mInsert
  of akInsertLineAbove:
    let lineNum = state.cursor.line
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsertLine,
      pos: Position(line: lineNum, col: 0),
      text: "",
    ))
    state.buffer.undo.commitGroup()
    state.buffer.insertLine(lineNum, "")
    state.cursor = Position(line: lineNum, col: 0)
    state.mode = mInsert

  # Editing
  of akDeleteChar:
    if state.buffer.lineLen(state.cursor.line) > 0:
      let ch = state.buffer.deleteChar(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDeleteChar,
        pos: state.cursor,
        text: $ch,
      ))
      state.buffer.undo.commitGroup()
      state.cursor = clampCursor(state.buffer, state.cursor, mNormal)

  of akDeleteLine:
    let lineText = state.buffer.getLine(state.cursor.line)
    state.yankRegister = @[lineText]
    state.yankIsLinewise = true
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoDeleteLine,
      pos: Position(line: state.cursor.line, col: 0),
      text: lineText,
    ))
    state.buffer.undo.commitGroup()
    discard state.buffer.deleteLine(state.cursor.line)
    state.cursor = clampCursor(state.buffer, state.cursor, mNormal)

  of akYankLine:
    let lineText = state.buffer.getLine(state.cursor.line)
    state.yankRegister = @[lineText]
    state.yankIsLinewise = true
    state.statusMessage = "1 line yanked"

  of akPaste:
    if state.yankRegister.len > 0:
      if state.yankIsLinewise:
        let lineNum = state.cursor.line + 1
        let text = state.yankRegister[0]
        state.buffer.undo.pushUndo(UndoEntry(
          op: uoInsertLine,
          pos: Position(line: lineNum, col: 0),
          text: text,
        ))
        state.buffer.undo.commitGroup()
        state.buffer.insertLine(lineNum, text)
        state.cursor = Position(line: lineNum, col: 0)

  of akPasteBefore:
    if state.yankRegister.len > 0:
      if state.yankIsLinewise:
        let lineNum = state.cursor.line
        let text = state.yankRegister[0]
        state.buffer.undo.pushUndo(UndoEntry(
          op: uoInsertLine,
          pos: Position(line: lineNum, col: 0),
          text: text,
        ))
        state.buffer.undo.commitGroup()
        state.buffer.insertLine(lineNum, text)
        state.cursor = Position(line: lineNum, col: 0)

  of akUndo:
    let pos = state.buffer.undo.undo(state.buffer)
    state.cursor = clampCursor(state.buffer, pos, mNormal)

  of akRedo:
    let pos = state.buffer.undo.redo(state.buffer)
    state.cursor = clampCursor(state.buffer, pos, mNormal)

  of akGotoDefinition:
    if lspState == lsRunning and lspDocumentUri.len > 0:
      let id = nextLspId()
      sendToLsp(buildDefinition(id, lspDocumentUri, state.cursor.line, state.cursor.col))
      addPendingRequest(id, "textDocument/definition")
      state.statusMessage = "LSP: goto definition..."
    else:
      state.statusMessage = "LSP not active"

  of akGoBack:
    let (hasJump, jump) = popJump()
    if hasJump:
      if jump.filePath != state.buffer.filePath:
        stopFileLoader()
        resetViewportRangeCache()
        state.buffer = newBuffer(jump.filePath)
        switchLsp(jump.filePath)
        if lspState == lsRunning:
          let text = state.buffer.lines.join("\n")
          sendDidOpen(jump.filePath, text)
          lspSyncedLines = state.buffer.lineCount
          if lspHasSemanticTokensRange and tokenLegend.len > 0:
            sendSemanticTokensRange(0, min(state.buffer.lineCount - 1, 50))
            startBgHighlight(state.buffer.lineCount)
      state.cursor = jump.cursor
      state.viewport.topLine = jump.topLine
      state.viewport.leftCol = 0
    else:
      state.statusMessage = "No previous location"

  of akEnterCommand:
    state.mode = mCommand
    state.commandLine = ""

  of akNone:
    discard
