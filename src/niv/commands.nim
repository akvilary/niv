## Ex-command parsing and execution

import std/strutils
import types
import buffer
import fileio
import sidebar
import lsp_manager
import lsp_client
import lsp_protocol
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
    state.running = false

  of ecForceQuit:
    state.running = false

  of ecEdit:
    if arg.len > 0:
      # Close current document in LSP
      sendDidClose()
      clearSemanticTokens()
      state.buffer = newBuffer(arg)
      state.cursor = Position(line: 0, col: 0)
      state.viewport.topLine = 0
      state.viewport.leftCol = 0
      state.statusMessage = "\"" & arg & "\""
      # Open new file in LSP
      if lspIsActive():
        let text = state.buffer.lines.join("\n")
        lspDocumentUri = filePathToUri(arg)
        sendDidOpen(arg, text)
        if tokenLegend.len > 0:
          let stId = nextLspId()
          sendToLsp(buildSemanticTokensFull(stId, lspDocumentUri))
          addPendingRequest(stId, "textDocument/semanticTokens/full")
      else:
        tryAutoStartLsp(arg)
    elif state.buffer.filePath.len > 0:
      clearSemanticTokens()
      state.buffer = newBuffer(state.buffer.filePath)
      state.cursor = Position(line: 0, col: 0)
      state.viewport.topLine = 0
      state.viewport.leftCol = 0
      state.statusMessage = "\"" & state.buffer.filePath & "\" reloaded"
      # Re-send didOpen for reloaded file
      if lspIsActive():
        let text = state.buffer.lines.join("\n")
        sendDidOpen(state.buffer.filePath, text)
        if tokenLegend.len > 0:
          let stId = nextLspId()
          sendToLsp(buildSemanticTokensFull(stId, lspDocumentUri))
          addPendingRequest(stId, "textDocument/semanticTokens/full")
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
