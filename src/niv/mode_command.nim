## Command-line mode handler

import types
import commands

proc handleCommandMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    state.mode = mNormal
    state.commandLine = ""

  of kkEnter:
    let (cmd, arg) = parseCommand(state.commandLine)
    executeCommand(state, cmd, arg)
    if state.mode == mCommand:
      state.mode = mNormal
    state.commandLine = ""

  of kkBackspace:
    if state.commandLine.len > 0:
      state.commandLine.setLen(state.commandLine.len - 1)
    else:
      state.mode = mNormal

  of kkChar:
    state.commandLine.add(key.ch)

  else:
    discard
