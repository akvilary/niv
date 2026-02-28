## Ex-command parsing and execution

import std/[strutils, osproc]
import types
import buffer
import fileio
import sidebar
import lsp_manager
import lsp_client
import lsp_types
import highlight

type
  ExCommand* = enum
    ecWrite
    ecQuit
    ecWriteQuit
    ecForceQuit
    ecEdit
    ecNvimTree
    ecLsp
    ecUnknown

proc parseCommand*(input: string): (ExCommand, string) =
  let trimmed = input.strip()
  if trimmed == "w":
    return (ecWrite, "")
  elif trimmed == "q":
    return (ecQuit, "")
  elif trimmed == "wq":
    return (ecWriteQuit, "")
  elif trimmed == "q!":
    return (ecForceQuit, "")
  elif trimmed.startsWith("w "):
    return (ecWrite, trimmed[2..^1].strip())
  elif trimmed.startsWith("e "):
    return (ecEdit, trimmed[2..^1].strip())
  elif trimmed == "e":
    return (ecEdit, "")
  elif trimmed == "NvimTree":
    return (ecNvimTree, "")
  elif trimmed == "lsp":
    return (ecLsp, "")
  else:
    return (ecUnknown, trimmed)

proc updateGitDiffStat(state: var EditorState) =
  if state.gitBranch.len == 0:
    state.gitDiffStat = ""
    return
  try:
    let (diffOut, diffCode) = execCmdEx("git diff --numstat", options = {poUsePath})
    if diffCode == 0:
      var added, deleted = 0
      for line in diffOut.splitLines():
        if line.len == 0: continue
        let parts = line.split('\t')
        if parts.len >= 2:
          try:
            added += parseInt(parts[0])
            deleted += parseInt(parts[1])
          except ValueError:
            discard
      if added > 0 or deleted > 0:
        state.gitDiffStat = "+" & $added & " -" & $deleted
      else:
        state.gitDiffStat = ""
    else:
      state.gitDiffStat = ""
  except OSError:
    state.gitDiffStat = ""

proc executeCommand*(state: var EditorState, cmd: ExCommand, arg: string) =
  case cmd
  of ecWrite:
    let path = if arg.len > 0: arg else: state.buffer.filePath
    if path.len == 0:
      state.statusMessage = "No file name"
      return
    if arg.len > 0:
      state.buffer.filePath = arg
    saveFile(path, state.buffer.lines)
    state.buffer.modified = false
    state.statusMessage = "\"" & path & "\" written"
    updateGitDiffStat(state)

  of ecQuit:
    if state.buffer.modified:
      state.statusMessage = "No write since last change (add ! to override)"
    else:
      state.running = false

  of ecWriteQuit:
    let path = state.buffer.filePath
    if path.len == 0:
      state.statusMessage = "No file name"
      return
    saveFile(path, state.buffer.lines)
    state.buffer.modified = false
    updateGitDiffStat(state)
    state.running = false

  of ecForceQuit:
    state.running = false

  of ecEdit:
    if arg.len > 0:
      stopFileLoader()
      resetViewportRangeCache()
      state.buffer = newBuffer(arg)
      state.cursor = Position(line: 0, col: 0)
      state.viewport.topLine = 0
      state.viewport.leftCol = 0
      state.statusMessage = "\"" & arg & "\""
      switchLsp(arg)
      if lspState == lsRunning:
        let text = state.buffer.lines.join("\n")
        sendDidOpen(arg, text)
        lspSyncedLines = state.buffer.lineCount
        if tokenLegend.len > 0 and lspHasSemanticTokensRange:
          sendSemanticTokensRange(0, min(state.buffer.lineCount - 1, 50))
          startBgHighlight(state.buffer.lineCount)
    elif state.buffer.filePath.len > 0:
      stopFileLoader()
      resetViewportRangeCache()
      clearSemanticTokens()
      resetBgHighlight()
      state.buffer = newBuffer(state.buffer.filePath)
      state.cursor = Position(line: 0, col: 0)
      state.viewport.topLine = 0
      state.viewport.leftCol = 0
      state.statusMessage = "\"" & state.buffer.filePath & "\" reloaded"
      if lspIsActive():
        let text = state.buffer.lines.join("\n")
        sendDidOpen(state.buffer.filePath, text)
        lspSyncedLines = state.buffer.lineCount
        if tokenLegend.len > 0 and lspHasSemanticTokensRange:
          sendSemanticTokensRange(0, min(state.buffer.lineCount - 1, 50))
          startBgHighlight(state.buffer.lineCount)
    else:
      state.statusMessage = "No file name"

  of ecNvimTree:
    toggleSidebar(state.sidebar)
    if state.sidebar.visible:
      state.sidebar.focused = true
      state.mode = mExplore

  of ecLsp:
    openLspManager()
    state.mode = mLspManager

  of ecUnknown:
    state.statusMessage = "Not an editor command: " & arg
