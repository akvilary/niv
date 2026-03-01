## Git mode key handler

import std/strutils
import types
import buffer
import git

proc enterCommitInput*(state: var EditorState) =
  ## Save current buffer/cursor, create empty buffer for commit message
  var hasStaged = false
  for f in state.gitPanel.files:
    if f.isStaged:
      hasStaged = true
      break
  if not hasStaged:
    state.statusMessage = "No staged changes to commit"
    return
  state.gitPanel.savedBuffer = state.buffer
  state.gitPanel.savedCursor = state.cursor
  state.gitPanel.savedTopLine = state.viewport.topLine
  state.gitPanel.inCommitInput = true
  state.buffer = newBuffer("")
  state.buffer.lines = @[""]
  state.cursor = Position(line: 0, col: 0)
  state.viewport.topLine = 0
  state.viewport.leftCol = 0
  state.mode = mInsert

proc cancelCommitInput*(state: var EditorState) =
  ## Restore original buffer, cancel commit
  state.buffer = state.gitPanel.savedBuffer
  state.cursor = state.gitPanel.savedCursor
  state.viewport.topLine = state.gitPanel.savedTopLine
  state.viewport.leftCol = 0
  state.gitPanel.inCommitInput = false
  state.mode = mGit

proc executeCommitInput*(state: var EditorState) =
  ## Execute commit with buffer contents, restore original buffer
  let message = state.buffer.lines.join("\n").strip()
  if message.len == 0:
    state.statusMessage = "Empty commit message"
    return
  let (ok, msg) = gitCommit(message)
  # Restore original buffer
  state.buffer = state.gitPanel.savedBuffer
  state.cursor = state.gitPanel.savedCursor
  state.viewport.topLine = state.gitPanel.savedTopLine
  state.viewport.leftCol = 0
  state.gitPanel.inCommitInput = false
  state.mode = mGit
  if ok:
    state.statusMessage = "Committed"
    refreshGitFiles(state.gitPanel)
    state.gitDiffStat = "+0 -0"
  else:
    state.statusMessage = "Commit failed: " & msg

proc handleFilesView(state: var EditorState, key: InputKey) =
  state.statusMessage = ""

  case key.kind
  of kkEscape:
    closeGitPanel(state.gitPanel)
    state.mode = mNormal

  of kkChar:
    case key.ch
    of 'q':
      closeGitPanel(state.gitPanel)
      state.mode = mNormal
    of 'j':
      if state.gitPanel.files.len > 0 and state.gitPanel.cursorIndex < state.gitPanel.files.len - 1:
        inc state.gitPanel.cursorIndex
    of 'k':
      if state.gitPanel.cursorIndex > 0:
        dec state.gitPanel.cursorIndex
    of 's':
      if state.gitPanel.cursorIndex < state.gitPanel.files.len:
        let f = state.gitPanel.files[state.gitPanel.cursorIndex]
        if f.isStaged:
          if gitUnstage(f.path):
            refreshGitFiles(state.gitPanel)
        else:
          if gitStage(f.path):
            refreshGitFiles(state.gitPanel)
    of 'd':
      if state.gitPanel.cursorIndex < state.gitPanel.files.len:
        let f = state.gitPanel.files[state.gitPanel.cursorIndex]
        if not f.isStaged:
          state.gitPanel.confirmDiscard = true
          state.statusMessage = "Discard changes to " & f.path & "? (y/n)"
    of 'c':
      enterCommitInput(state)
    of 'l':
      state.gitPanel.logEntries = gitLog()
      state.gitPanel.logCursorIndex = 0
      state.gitPanel.logScrollOffset = 0
      state.gitPanel.view = gvLog
    of 'r':
      refreshGitFiles(state.gitPanel)
    else:
      discard

  of kkEnter:
    if state.gitPanel.cursorIndex < state.gitPanel.files.len:
      let f = state.gitPanel.files[state.gitPanel.cursorIndex]
      let diffText = if f.isUntracked:
        gitDiffUntracked(f.path)
      elif f.isStaged:
        gitDiff(f.path, staged = true)
      else:
        gitDiff(f.path, staged = false)
      state.gitPanel.diffLines = diffText.splitLines()
      state.gitPanel.diffScrollOffset = 0
      state.gitPanel.view = gvDiff

  of kkArrowDown:
    if state.gitPanel.files.len > 0 and state.gitPanel.cursorIndex < state.gitPanel.files.len - 1:
      inc state.gitPanel.cursorIndex
  of kkArrowUp:
    if state.gitPanel.cursorIndex > 0:
      dec state.gitPanel.cursorIndex

  else:
    discard

proc handleDiffView(state: var EditorState, key: InputKey) =
  state.statusMessage = ""

  case key.kind
  of kkEscape:
    state.gitPanel.view = gvFiles

  of kkChar:
    case key.ch
    of 'q':
      state.gitPanel.view = gvFiles
    of 'j':
      if state.gitPanel.diffScrollOffset < max(0, state.gitPanel.diffLines.len - 1):
        inc state.gitPanel.diffScrollOffset
    of 'k':
      if state.gitPanel.diffScrollOffset > 0:
        dec state.gitPanel.diffScrollOffset
    else:
      discard

  of kkArrowDown:
    if state.gitPanel.diffScrollOffset < max(0, state.gitPanel.diffLines.len - 1):
      inc state.gitPanel.diffScrollOffset
  of kkArrowUp:
    if state.gitPanel.diffScrollOffset > 0:
      dec state.gitPanel.diffScrollOffset

  else:
    discard

proc handleLogView(state: var EditorState, key: InputKey) =
  state.statusMessage = ""

  case key.kind
  of kkEscape:
    state.gitPanel.view = gvFiles

  of kkChar:
    case key.ch
    of 'q':
      state.gitPanel.view = gvFiles
    of 'j':
      if state.gitPanel.logEntries.len > 0 and state.gitPanel.logCursorIndex < state.gitPanel.logEntries.len - 1:
        inc state.gitPanel.logCursorIndex
    of 'k':
      if state.gitPanel.logCursorIndex > 0:
        dec state.gitPanel.logCursorIndex
    else:
      discard

  of kkArrowDown:
    if state.gitPanel.logEntries.len > 0 and state.gitPanel.logCursorIndex < state.gitPanel.logEntries.len - 1:
      inc state.gitPanel.logCursorIndex
  of kkArrowUp:
    if state.gitPanel.logCursorIndex > 0:
      dec state.gitPanel.logCursorIndex

  else:
    discard

proc handleGitMode*(state: var EditorState, key: InputKey) =
  # Confirm discard mode
  if state.gitPanel.confirmDiscard:
    case key.kind
    of kkChar:
      if key.ch == 'y':
        if state.gitPanel.cursorIndex < state.gitPanel.files.len:
          let f = state.gitPanel.files[state.gitPanel.cursorIndex]
          if gitDiscard(f.path, f.isUntracked):
            state.statusMessage = "Discarded: " & f.path
            refreshGitFiles(state.gitPanel)
          else:
            state.statusMessage = "Failed to discard"
        state.gitPanel.confirmDiscard = false
      else:
        state.gitPanel.confirmDiscard = false
        state.statusMessage = ""
    of kkEscape:
      state.gitPanel.confirmDiscard = false
      state.statusMessage = ""
    else:
      state.gitPanel.confirmDiscard = false
      state.statusMessage = ""
    return

  case state.gitPanel.view
  of gvFiles:
    handleFilesView(state, key)
  of gvDiff:
    handleDiffView(state, key)
  of gvLog:
    handleLogView(state, key)
