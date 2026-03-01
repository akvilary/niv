## Git mode key handler

import std/strutils
import types
import git

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
      var hasStaged = false
      for f in state.gitPanel.files:
        if f.isStaged:
          hasStaged = true
          break
      if hasStaged:
        state.gitPanel.inCommitInput = true
        state.gitPanel.commitMessage = ""
      else:
        state.statusMessage = "No staged changes to commit"
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
  # Commit input mode
  if state.gitPanel.inCommitInput:
    case key.kind
    of kkEscape:
      state.gitPanel.inCommitInput = false
      state.gitPanel.commitMessage = ""
      state.statusMessage = ""
    of kkEnter:
      if state.gitPanel.commitMessage.len > 0:
        let (ok, msg) = gitCommit(state.gitPanel.commitMessage)
        if ok:
          state.statusMessage = "Committed: " & state.gitPanel.commitMessage
          refreshGitFiles(state.gitPanel)
          state.gitDiffStat = ""
        else:
          state.statusMessage = "Commit failed: " & msg
      else:
        state.statusMessage = "Empty commit message"
      state.gitPanel.inCommitInput = false
      state.gitPanel.commitMessage = ""
    of kkBackspace:
      if state.gitPanel.commitMessage.len > 0:
        state.gitPanel.commitMessage.setLen(state.gitPanel.commitMessage.len - 1)
    of kkChar:
      state.gitPanel.commitMessage.add(key.ch)
    else:
      discard
    return

  # Confirm discard mode
  if state.gitPanel.confirmDiscard:
    case key.kind
    of kkChar:
      if key.ch == 'y':
        if state.gitPanel.cursorIndex < state.gitPanel.files.len:
          let f = state.gitPanel.files[state.gitPanel.cursorIndex]
          if gitDiscard(f.path):
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
