## Normal mode key handler

import std/unicode
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
import mode_git

proc handleNormalMode*(state: var EditorState, key: InputKey) =
  state.statusMessage = ""

  # In commit input mode, Escape from normal mode cancels the commit
  if state.gitPanel.inCommitInput and key.kind == kkEscape:
    cancelCommitInput(state)
    return

  # Escape clears search highlights
  if key.kind == kkEscape:
    if state.searchMatches.len > 0:
      state.searchQuery = ""
      state.searchMatches = @[]
      state.searchIndex = 0
    return

  # Sidebar keybindings (checked before input sequence parser)
  if key.kind == kkCtrlKey:
    case key.ctrl
    of Rune(ord('e')):
      toggleSidebar(state.sidebar)
      if state.sidebar.visible:
        state.sidebar.focused = true
        state.mode = mExplore
      return
    of Rune(ord('w')):
      if state.sidebar.visible:
        state.sidebar.focused = true
        state.mode = mExplore
        return
    of Rune(ord('g')):
      if state.gitPanel.visible:
        closeGitPanel(state.gitPanel)
        state.mode = mNormal
      else:
        openGitPanel(state.gitPanel)
        state.mode = mGit
      return
    of Rune(ord('b')):
      if not state.gitPanel.visible:
        openGitPanel(state.gitPanel)
      state.gitPanel.branchQuery = ""
      filterBranches(state.gitPanel)
      state.gitPanel.branchDirectOpen = true
      state.gitPanel.view = gvBranches
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
  of akGotoLine:
    let targetLine = max(0, min(ir.count - 1, state.buffer.lineCount - 1))
    state.cursor = Position(line: targetLine, col: 0)
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
      let line = state.buffer.getLine(state.cursor.line)
      let rl = runeLenAt(line, state.cursor.col)
      state.cursor.col += rl
    state.mode = mInsert
  of akInsertLineBelow:
    let lineNum = state.cursor.line
    let curIndent = state.buffer.getIndent(lineNum)
    let nextLine = lineNum + 1
    var indent = curIndent
    if nextLine < state.buffer.lineCount and state.buffer.lineLen(nextLine) > 0:
      let nextIndent = state.buffer.getIndent(nextLine)
      if nextIndent.len > curIndent.len:
        indent = nextIndent
    let insertText = indent & "\n"
    let insertOffset = if lineNum + 1 < state.buffer.lineIndex.len:
      state.buffer.lineIndex[lineNum + 1]
    else:
      state.buffer.data.len
    state.buffer.undo.ensureTokensCaptured(lineNum)
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsert,
      offset: insertOffset,
      text: insertText,
    ))
    state.buffer.insertLine(lineNum + 1, indent)
    insertSemanticLine(lineNum + 1)
    state.buffer.undo.trackLineInserted()
    state.cursor = Position(line: lineNum + 1, col: indent.len)
    state.mode = mInsert
  of akInsertLineAbove:
    let lineNum = state.cursor.line
    var indent = ""
    if state.buffer.lineLen(lineNum) > 0:
      indent = state.buffer.getIndent(lineNum)
    elif lineNum > 0 and state.buffer.lineLen(lineNum - 1) > 0:
      indent = state.buffer.getIndent(lineNum - 1)
    let insertText = indent & "\n"
    let insertOffset = state.buffer.lineIndex[lineNum]
    state.buffer.undo.ensureTokensCaptured(lineNum)
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoInsert,
      offset: insertOffset,
      text: insertText,
    ))
    state.buffer.insertLine(lineNum, indent)
    insertSemanticLine(lineNum)
    state.buffer.undo.trackLineInserted()
    state.cursor = Position(line: lineNum, col: indent.len)
    state.mode = mInsert

  # Editing
  of akDeleteChar:
    if state.buffer.lineLen(state.cursor.line) > 0:
      state.buffer.undo.ensureTokensCaptured(state.cursor.line)
      let delOffset = state.buffer.byteOffsetOf(state.cursor)
      let deleted = state.buffer.deleteRune(state.cursor)
      state.buffer.undo.pushUndo(UndoEntry(
        op: uoDelete,
        offset: delOffset,
        text: deleted,
      ))
      state.buffer.undo.commitGroup()
      state.cursor = clampCursor(state.buffer, state.cursor, mNormal)

  of akDeleteLine:
    let lineNum = state.cursor.line
    let lineText = state.buffer.getLine(lineNum)
    state.yankRegister = lineText
    state.yankIsLinewise = true
    # Include the \n in deleted bytes
    let s = state.buffer.lineIndex[lineNum]
    let e = if lineNum + 1 < state.buffer.lineIndex.len:
      state.buffer.lineIndex[lineNum + 1]
    else:
      state.buffer.data.len
    let deletedText = state.buffer.data[s..<e]
    state.buffer.undo.ensureTokensCaptured(lineNum)
    state.buffer.undo.pushUndo(UndoEntry(
      op: uoDelete,
      offset: s,
      text: deletedText,
    ))
    discard state.buffer.deleteLine(lineNum)
    deleteSemanticLine(lineNum)
    state.buffer.undo.trackLineRemoved()
    state.buffer.undo.commitGroup()
    state.cursor = clampCursor(state.buffer, state.cursor, mNormal)

  of akYankLine:
    let lineText = state.buffer.getLine(state.cursor.line)
    state.yankRegister = lineText
    state.yankIsLinewise = true
    state.statusMessage = "1 line yanked"

  of akPaste:
    if state.yankRegister.len > 0:
      if state.yankIsLinewise:
        let lineNum = state.cursor.line + 1
        let text = state.yankRegister
        let insertText = text & "\n"
        let insertOffset = if lineNum < state.buffer.lineIndex.len:
          state.buffer.lineIndex[lineNum]
        else:
          state.buffer.data.len
        state.buffer.undo.ensureTokensCaptured(state.cursor.line)
        state.buffer.undo.pushUndo(UndoEntry(
          op: uoInsert,
          offset: insertOffset,
          text: insertText,
        ))
        state.buffer.insertLine(lineNum, text)
        insertSemanticLine(lineNum)
        state.buffer.undo.trackLineInserted()
        state.buffer.undo.commitGroup()
        state.cursor = Position(line: lineNum, col: 0)

  of akPasteBefore:
    if state.yankRegister.len > 0:
      if state.yankIsLinewise:
        let lineNum = state.cursor.line
        let text = state.yankRegister
        let insertText = text & "\n"
        let insertOffset = state.buffer.lineIndex[lineNum]
        state.buffer.undo.ensureTokensCaptured(lineNum)
        state.buffer.undo.pushUndo(UndoEntry(
          op: uoInsert,
          offset: insertOffset,
          text: insertText,
        ))
        state.buffer.insertLine(lineNum, text)
        insertSemanticLine(lineNum)
        state.buffer.undo.trackLineInserted()
        state.buffer.undo.commitGroup()
        state.cursor = Position(line: lineNum, col: 0)

  of akUndo:
    let res = state.buffer.undo.undo(state.buffer)
    state.cursor = clampCursor(state.buffer, res.cursor, mNormal)
    # Restore pre-edit tokens from diff
    if res.tokenDiff.linesBefore.len > 0 or res.tokenDiff.linesAfter.len > 0:
      applyTokenDiff(res.tokenDiff.startLine, res.tokenDiff.linesAfter.len, res.tokenDiff.linesBefore)
    if lspState == lsRunning:
      sendDidChange(state.buffer.data)
      lspSyncedLines = state.buffer.lineCount
      resetViewportRangeCache()

  of akRedo:
    let res = state.buffer.undo.redo(state.buffer)
    state.cursor = clampCursor(state.buffer, res.cursor, mNormal)
    # Restore post-edit tokens from diff
    if res.tokenDiff.linesBefore.len > 0 or res.tokenDiff.linesAfter.len > 0:
      applyTokenDiff(res.tokenDiff.startLine, res.tokenDiff.linesBefore.len, res.tokenDiff.linesAfter)
    if lspState == lsRunning:
      sendDidChange(state.buffer.data)
      lspSyncedLines = state.buffer.lineCount
      resetViewportRangeCache()

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
          sendDidOpen(jump.filePath, state.buffer.data)
          lspSyncedLines = state.buffer.lineCount
          if lspHasSemanticTokensRange and tokenLegend.len > 0:
            sendSemanticTokensRange(0, min(state.buffer.lineCount - 1, 50))
            startBgHighlight(state.buffer.lineCount)
      state.cursor = jump.cursor
      state.viewport.topLine = jump.topLine
      state.viewport.leftCol = 0
    else:
      state.statusMessage = "No previous location"

  of akSearchForward:
    state.searchInput = true
    state.mode = mCommand
    state.commandLine = ""

  of akSearchNext:
    if state.searchMatches.len > 0:
      state.searchIndex = (state.searchIndex + 1) mod state.searchMatches.len
      let m = state.searchMatches[state.searchIndex]
      state.cursor = Position(line: m.line, col: m.col)
      state.statusMessage = $( state.searchIndex + 1) & "/" & $state.searchMatches.len
    elif state.searchQuery.len > 0:
      state.statusMessage = "Pattern not found: " & state.searchQuery
    else:
      state.statusMessage = "No previous search"

  of akSearchPrev:
    if state.searchMatches.len > 0:
      state.searchIndex = (state.searchIndex - 1 + state.searchMatches.len) mod state.searchMatches.len
      let m = state.searchMatches[state.searchIndex]
      state.cursor = Position(line: m.line, col: m.col)
      state.statusMessage = $(state.searchIndex + 1) & "/" & $state.searchMatches.len
    elif state.searchQuery.len > 0:
      state.statusMessage = "Pattern not found: " & state.searchQuery
    else:
      state.statusMessage = "No previous search"

  of akEnterCommand:
    state.mode = mCommand
    state.commandLine = ""

  of akNone:
    discard
