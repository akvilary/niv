## Git mode key handler

import std/[strutils, unicode]
import types
import buffer
import git

const batchSize = 40

proc loadMoreLog(panel: var GitPanelState) =
  if not panel.logHasMore: return
  let more = gitLog(batchSize, panel.logLoadedCount)
  panel.logEntries.add(more)
  panel.logLoadedCount += more.len
  if more.len < batchSize:
    panel.logHasMore = false

proc loadMoreBranches(panel: var GitPanelState) =
  if not panel.branchHasMore: return
  let more = gitBranches(batchSize, panel.branchLoadedCount, panel.branchSearch.text)
  panel.filteredBranches.add(more)
  panel.branchLoadedCount += more.len
  if more.len < batchSize:
    panel.branchHasMore = false

proc filterBranches*(panel: var GitPanelState) =
  panel.filteredBranches = gitBranches(batchSize, query = panel.branchSearch.text)
  panel.branchLoadedCount = panel.filteredBranches.len
  panel.branchHasMore = panel.filteredBranches.len >= batchSize
  panel.branchCursorIndex = 0
  panel.branchScrollOffset = 0

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
  state.cursor = Position(line: 0, col: 0)
  state.viewport.topLine = 0
  state.viewport.leftCol = 0
  state.mode = mInsert

proc cancelCommitInput*(state: var EditorState) =
  ## Restore original buffer, cancel commit
  if state.gitPanel.isMergeCommit:
    discard gitMergeAbort()
  state.buffer = state.gitPanel.savedBuffer
  state.cursor = state.gitPanel.savedCursor
  state.viewport.topLine = state.gitPanel.savedTopLine
  state.viewport.leftCol = 0
  state.gitPanel.inCommitInput = false
  state.gitPanel.isMergeCommit = false
  state.mode = mGit

proc executeCommitInput*(state: var EditorState) =
  ## Execute commit with buffer contents, restore original buffer
  let message = state.buffer.data.strip()
  if message.len == 0:
    state.statusMessage = "Empty commit message"
    return
  let isMerge = state.gitPanel.isMergeCommit
  let (ok, msg) = if isMerge: gitMergeCommit(message) else: gitCommit(message)
  # Restore original buffer
  state.buffer = state.gitPanel.savedBuffer
  state.cursor = state.gitPanel.savedCursor
  state.viewport.topLine = state.gitPanel.savedTopLine
  state.viewport.leftCol = 0
  state.gitPanel.inCommitInput = false
  state.gitPanel.isMergeCommit = false
  state.mode = mGit
  if ok:
    state.statusMessage = if isMerge: "Merged" else: "Committed"
    refreshGitFiles(state.gitPanel)
    state.gitDiffStat = "+0 -0"
  else:
    state.statusMessage = (if isMerge: "Merge commit failed: " else: "Commit failed: ") & msg

proc enterMergeInput*(state: var EditorState) =
  state.gitPanel.inMergeInput = true
  state.gitPanel.mergeInputBranch = ""
  state.statusMessage = "Merge branch: "

proc executeMerge*(state: var EditorState) =
  let branch = state.gitPanel.mergeInputBranch.strip()
  state.gitPanel.inMergeInput = false
  if branch.len == 0:
    state.statusMessage = ""
    return
  let (ok, output) = gitMerge(branch)
  if ok:
    # Merge succeeded without conflicts — enter commit message editor
    let currentBranch = gitCurrentBranch()
    state.gitPanel.savedBuffer = state.buffer
    state.gitPanel.savedCursor = state.cursor
    state.gitPanel.savedTopLine = state.viewport.topLine
    state.gitPanel.inCommitInput = true
    state.gitPanel.isMergeCommit = true
    state.buffer = newBuffer("Merge branch '" & branch & "' into " & currentBranch)
    state.cursor = Position(line: 0, col: state.buffer.getLine(0).len)
    state.viewport.topLine = 0
    state.viewport.leftCol = 0
    state.mode = mInsert
  else:
    # Check for conflicts
    let conflicts = getConflictFiles()
    if conflicts.len > 0:
      state.gitPanel.conflictFiles = conflicts
      state.gitPanel.conflictCursorIndex = 0
      state.gitPanel.conflictScrollOffset = 0
      state.gitPanel.view = gvMergeConflicts
      state.statusMessage = $conflicts.len & " file(s) with conflicts"
    else:
      state.statusMessage = "Merge failed: " & output

proc cancelMergeInput*(state: var EditorState) =
  state.gitPanel.inMergeInput = false
  state.gitPanel.mergeInputBranch = ""
  state.statusMessage = ""

proc handleFilesView(state: var EditorState, key: InputKey) =
  state.statusMessage = ""

  case key.kind
  of kkEscape:
    closeGitPanel(state.gitPanel)
    state.mode = mNormal

  of kkChar:
    case key.ch
    of Rune(ord('q')):
      closeGitPanel(state.gitPanel)
      state.mode = mNormal
    of Rune(ord('j')):
      if state.gitPanel.files.len > 0 and state.gitPanel.cursorIndex < state.gitPanel.files.len - 1:
        inc state.gitPanel.cursorIndex
    of Rune(ord('k')):
      if state.gitPanel.cursorIndex > 0:
        dec state.gitPanel.cursorIndex
    of Rune(ord('s')):
      if state.gitPanel.cursorIndex < state.gitPanel.files.len:
        let f = state.gitPanel.files[state.gitPanel.cursorIndex]
        if f.isStaged:
          if gitUnstage(f.path):
            refreshGitFiles(state.gitPanel)
        else:
          if gitStage(f.path):
            refreshGitFiles(state.gitPanel)
    of Rune(ord('d')):
      if state.gitPanel.cursorIndex < state.gitPanel.files.len:
        let f = state.gitPanel.files[state.gitPanel.cursorIndex]
        if not f.isStaged:
          state.gitPanel.confirmDiscard = true
          state.statusMessage = "Discard changes to " & f.path & "? (y/n)"
    of Rune(ord('c')):
      enterCommitInput(state)
    of Rune(ord('l')):
      state.gitPanel.logEntries = gitLog(batchSize)
      state.gitPanel.logLoadedCount = state.gitPanel.logEntries.len
      state.gitPanel.logHasMore = state.gitPanel.logEntries.len >= batchSize
      state.gitPanel.logCursorIndex = 0
      state.gitPanel.logScrollOffset = 0
      state.gitPanel.view = gvLog
    of Rune(ord('m')):
      enterMergeInput(state)
    of Rune(ord('b')):
      state.gitPanel.branchSearch.clear()
      filterBranches(state.gitPanel)
      state.gitPanel.view = gvBranches
    of Rune(ord('r')):
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
      state.gitPanel.diffReturnView = gvFiles
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
    state.gitPanel.view = state.gitPanel.diffReturnView

  of kkChar:
    case key.ch
    of Rune(ord('q')):
      state.gitPanel.view = state.gitPanel.diffReturnView
    of Rune(ord('j')):
      if state.gitPanel.diffScrollOffset < max(0, state.gitPanel.diffLines.len - 1):
        inc state.gitPanel.diffScrollOffset
    of Rune(ord('k')):
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
    of Rune(ord('q')):
      state.gitPanel.view = gvFiles
    of Rune(ord('j')):
      if state.gitPanel.logEntries.len > 0 and state.gitPanel.logCursorIndex < state.gitPanel.logEntries.len - 1:
        inc state.gitPanel.logCursorIndex
      elif state.gitPanel.logCursorIndex == state.gitPanel.logEntries.len - 1:
        loadMoreLog(state.gitPanel)
    of Rune(ord('k')):
      if state.gitPanel.logCursorIndex > 0:
        dec state.gitPanel.logCursorIndex
    else:
      discard

  of kkEnter:
    if state.gitPanel.logCursorIndex < state.gitPanel.logEntries.len:
      let entry = state.gitPanel.logEntries[state.gitPanel.logCursorIndex]
      let diffText = gitShowCommit(entry.hash)
      state.gitPanel.diffLines = diffText.splitLines()
      state.gitPanel.diffScrollOffset = 0
      state.gitPanel.diffReturnView = gvLog
      state.gitPanel.view = gvDiff

  of kkArrowDown:
    if state.gitPanel.logEntries.len > 0 and state.gitPanel.logCursorIndex < state.gitPanel.logEntries.len - 1:
      inc state.gitPanel.logCursorIndex
    elif state.gitPanel.logCursorIndex == state.gitPanel.logEntries.len - 1:
      loadMoreLog(state.gitPanel)
  of kkArrowUp:
    if state.gitPanel.logCursorIndex > 0:
      dec state.gitPanel.logCursorIndex

  else:
    discard

proc closeBranchesView(state: var EditorState) =
  if state.gitPanel.branchDirectOpen:
    state.gitPanel.branchDirectOpen = false
    closeGitPanel(state.gitPanel)
    state.mode = mNormal
  else:
    state.gitPanel.view = gvFiles
  state.statusMessage = ""

proc handleBranchesView(state: var EditorState, key: InputKey) =
  let branchCount = state.gitPanel.filteredBranches.len

  case key.kind
  of kkEscape:
    closeBranchesView(state)

  of kkChar:
    state.gitPanel.branchSearch.addChar(key.ch)
    filterBranches(state.gitPanel)

  of kkBackspace:
    if state.gitPanel.branchSearch.query.len > 0:
      state.gitPanel.branchSearch.backspace()
      filterBranches(state.gitPanel)

  of kkDelete:
    if state.gitPanel.branchSearch.cursor < state.gitPanel.branchSearch.query.len:
      state.gitPanel.branchSearch.deleteChar()
      filterBranches(state.gitPanel)

  of kkEnter:
    if state.gitPanel.branchCursorIndex < branchCount:
      var branch = state.gitPanel.filteredBranches[state.gitPanel.branchCursorIndex]
      if branch.startsWith("origin/"):
        branch = branch[7..^1]
      let (ok, output) = gitCheckout(branch)
      if ok:
        state.gitBranch = branch
        state.statusMessage = "Switched to " & branch
        if state.gitPanel.branchDirectOpen:
          state.gitPanel.branchDirectOpen = false
          closeGitPanel(state.gitPanel)
          state.mode = mNormal
        else:
          refreshGitFiles(state.gitPanel)
          state.gitPanel.view = gvFiles
      else:
        state.statusMessage = "Checkout failed: " & output

  of kkCtrlKey:
    if key.ctrl == Rune(ord('f')):
      state.statusMessage = "Fetching..."
      let (ok, _) = gitFetch()
      if ok:
        filterBranches(state.gitPanel)
        state.statusMessage = "Fetched"
      else:
        state.statusMessage = "Fetch failed"
    elif key.ctrl == Rune(ord('l')):
      state.statusMessage = "Pulling..."
      let (ok, output) = gitPull()
      if ok:
        state.statusMessage = "Pulled"
        filterBranches(state.gitPanel)
        refreshGitFiles(state.gitPanel)
      else:
        state.statusMessage = "Pull failed: " & output
    elif key.ctrl == Rune(ord('p')):
      state.statusMessage = "Pushing..."
      let (ok, output) = gitPush()
      if ok:
        state.statusMessage = "Pushed"
      else:
        state.statusMessage = "Push failed: " & output

  of kkArrowDown:
    if branchCount > 0 and state.gitPanel.branchCursorIndex < branchCount - 1:
      inc state.gitPanel.branchCursorIndex
    elif state.gitPanel.branchCursorIndex == branchCount - 1 and state.gitPanel.branchHasMore:
      loadMoreBranches(state.gitPanel)
      if state.gitPanel.filteredBranches.len > branchCount:
        inc state.gitPanel.branchCursorIndex
  of kkArrowUp:
    if state.gitPanel.branchCursorIndex > 0:
      dec state.gitPanel.branchCursorIndex

  of kkArrowLeft:
    state.gitPanel.branchSearch.moveLeft()
  of kkArrowRight:
    state.gitPanel.branchSearch.moveRight()
  of kkHome:
    state.gitPanel.branchSearch.moveHome()
  of kkEnd:
    state.gitPanel.branchSearch.moveEnd()

  else:
    discard

proc handleConflictsView(state: var EditorState, key: InputKey) =
  state.statusMessage = ""
  let fileCount = state.gitPanel.conflictFiles.len

  case key.kind
  of kkEscape:
    discard gitMergeAbort()
    state.statusMessage = "Merge aborted"
    refreshGitFiles(state.gitPanel)
    state.gitPanel.view = gvFiles

  of kkChar:
    case key.ch
    of Rune(ord('q')):
      discard gitMergeAbort()
      state.statusMessage = "Merge aborted"
      refreshGitFiles(state.gitPanel)
      state.gitPanel.view = gvFiles
    of Rune(ord('j')):
      if fileCount > 0 and state.gitPanel.conflictCursorIndex < fileCount - 1:
        inc state.gitPanel.conflictCursorIndex
    of Rune(ord('k')):
      if state.gitPanel.conflictCursorIndex > 0:
        dec state.gitPanel.conflictCursorIndex
    of Rune(ord('o')):
      # Accept ours for current conflict in selected file
      if state.gitPanel.conflictCursorIndex < fileCount:
        var cf = state.gitPanel.conflictFiles[state.gitPanel.conflictCursorIndex]
        if cf.conflictCount > 0:
          if resolveConflict(cf.path, ccOurs, cf.cursorIndex):
            dec cf.conflictCount
            if cf.cursorIndex >= cf.conflictCount:
              cf.cursorIndex = max(0, cf.conflictCount - 1)
            state.gitPanel.conflictFiles[state.gitPanel.conflictCursorIndex] = cf
            if cf.conflictCount == 0:
              discard gitStage(cf.path)
              state.statusMessage = "Resolved: " & cf.path
    of Rune(ord('t')):
      # Accept theirs for current conflict in selected file
      if state.gitPanel.conflictCursorIndex < fileCount:
        var cf = state.gitPanel.conflictFiles[state.gitPanel.conflictCursorIndex]
        if cf.conflictCount > 0:
          if resolveConflict(cf.path, ccTheirs, cf.cursorIndex):
            dec cf.conflictCount
            if cf.cursorIndex >= cf.conflictCount:
              cf.cursorIndex = max(0, cf.conflictCount - 1)
            state.gitPanel.conflictFiles[state.gitPanel.conflictCursorIndex] = cf
            if cf.conflictCount == 0:
              discard gitStage(cf.path)
              state.statusMessage = "Resolved: " & cf.path
    else:
      discard

  of kkEnter:
    # All conflicts resolved? → enter commit message editor
    var allResolved = true
    for cf in state.gitPanel.conflictFiles:
      if cf.conflictCount > 0:
        allResolved = false
        break
    if allResolved:
      let currentBranch = gitCurrentBranch()
      state.gitPanel.savedBuffer = state.buffer
      state.gitPanel.savedCursor = state.cursor
      state.gitPanel.savedTopLine = state.viewport.topLine
      state.gitPanel.inCommitInput = true
      state.gitPanel.isMergeCommit = true
      state.buffer = newBuffer("Merge conflict resolution on " & currentBranch)
      state.cursor = Position(line: 0, col: state.buffer.getLine(0).len)
      state.viewport.topLine = 0
      state.viewport.leftCol = 0
      state.mode = mInsert
    else:
      state.statusMessage = "Resolve all conflicts first"

  of kkArrowDown:
    if fileCount > 0 and state.gitPanel.conflictCursorIndex < fileCount - 1:
      inc state.gitPanel.conflictCursorIndex
  of kkArrowUp:
    if state.gitPanel.conflictCursorIndex > 0:
      dec state.gitPanel.conflictCursorIndex

  else:
    discard

proc handleGitMode*(state: var EditorState, key: InputKey) =
  # Merge branch input mode
  if state.gitPanel.inMergeInput:
    case key.kind
    of kkChar:
      state.gitPanel.mergeInputBranch.add($key.ch)
      state.statusMessage = "Merge branch: " & state.gitPanel.mergeInputBranch
    of kkBackspace:
      if state.gitPanel.mergeInputBranch.len > 0:
        state.gitPanel.mergeInputBranch = state.gitPanel.mergeInputBranch[0..^2]
      state.statusMessage = "Merge branch: " & state.gitPanel.mergeInputBranch
    of kkEnter:
      executeMerge(state)
    of kkEscape:
      cancelMergeInput(state)
    else:
      discard
    return

  # Confirm discard mode
  if state.gitPanel.confirmDiscard:
    case key.kind
    of kkChar:
      if key.ch == Rune(ord('y')):
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
  of gvMergeConflicts:
    handleConflictsView(state, key)
  of gvBranches:
    handleBranchesView(state, key)
