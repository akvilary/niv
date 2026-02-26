## LSP Manager mode key handler

import types
import lsp_manager
import lsp_client
import lsp_types

proc closeLspManagerAndTryStart(state: var EditorState) =
  closeLspManager()
  state.mode = mNormal
  # Auto-start LSP if a .nim file is open and LSP is not running
  if lspState == lsOff and state.buffer.filePath.len > 0:
    tryAutoStartLsp(state.buffer.filePath)

proc handleLspManagerMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    closeLspManagerAndTryStart(state)

  of kkChar:
    case key.ch
    of 'q':
      closeLspManagerAndTryStart(state)
    of 'j':
      managerMoveDown()
    of 'k':
      managerMoveUp()
    of 'i':
      startInstall()
    of 'X':
      startUninstall()
    else:
      discard

  of kkArrowDown:
    managerMoveDown()
  of kkArrowUp:
    managerMoveUp()

  of kkEnter:
    startInstall()

  else:
    discard
