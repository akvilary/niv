## Ex-command parsing and execution

import std/strutils
import types
import buffer
import fileio
import sidebar

type
  ExCommand* = enum
    ecWrite
    ecQuit
    ecWriteQuit
    ecForceQuit
    ecEdit
    ecNvimTree
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
      state.buffer = newBuffer(arg)
      state.cursor = Position(line: 0, col: 0)
      state.viewport.topLine = 0
      state.viewport.leftCol = 0
      state.statusMessage = "\"" & arg & "\""
    elif state.buffer.filePath.len > 0:
      state.buffer = newBuffer(state.buffer.filePath)
      state.cursor = Position(line: 0, col: 0)
      state.viewport.topLine = 0
      state.viewport.leftCol = 0
      state.statusMessage = "\"" & state.buffer.filePath & "\" reloaded"
    else:
      state.statusMessage = "No file name"

  of ecNvimTree:
    toggleSidebar(state.sidebar)
    if state.sidebar.visible:
      state.sidebar.focused = true
      state.mode = mExplore

  of ecUnknown:
    state.statusMessage = "Not an editor command: " & arg
