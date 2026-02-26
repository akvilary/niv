## Explore mode (sidebar focused) key handler

import std/strutils
import types
import buffer
import sidebar
import lsp_client
import lsp_types
import lsp_protocol
import highlight

proc openFileFromSidebar(state: var EditorState, filePath: string) =
  ## Open a file from the sidebar with proper LSP integration
  # Close old document in LSP
  if lspState == lsRunning:
    sendDidClose()
  clearSemanticTokens()

  state.buffer = newBuffer(filePath)
  state.cursor = Position(line: 0, col: 0)
  state.viewport.topLine = 0
  state.viewport.leftCol = 0
  state.sidebar.focused = false
  state.mode = mNormal
  state.statusMessage = "\"" & filePath & "\""

  # Open in LSP + request semantic tokens
  if lspState == lsRunning:
    let text = state.buffer.lines.join("\n")
    lspDocumentUri = filePathToUri(filePath)
    sendDidOpen(filePath, text)
    if tokenLegend.len > 0:
      let stId = nextLspId()
      sendToLsp(buildSemanticTokensFull(stId, lspDocumentUri))
      addPendingRequest(stId, "textDocument/semanticTokens/full")
  elif lspState == lsOff:
    tryAutoStartLsp(filePath)

proc handleExploreMode*(state: var EditorState, key: InputKey) =
  state.statusMessage = ""

  case key.kind
  of kkEscape:
    state.sidebar.focused = false
    state.mode = mNormal

  of kkTab:
    state.sidebar.focused = false
    state.mode = mNormal

  of kkChar:
    case key.ch
    of 'j':
      sidebarMoveDown(state.sidebar)
    of 'k':
      sidebarMoveUp(state.sidebar)
    of 'l':
      let filePath = sidebarExpandOrOpen(state.sidebar)
      if filePath.len > 0:
        openFileFromSidebar(state, filePath)
    of 'h':
      sidebarCollapse(state.sidebar)
    of '-':
      sidebarCollapse(state.sidebar)
    of 'q':
      state.sidebar.visible = false
      state.sidebar.focused = false
      state.mode = mNormal
    else:
      discard

  of kkEnter:
    let filePath = sidebarExpandOrOpen(state.sidebar)
    if filePath.len > 0:
      openFileFromSidebar(state, filePath)

  of kkArrowDown:
    sidebarMoveDown(state.sidebar)
  of kkArrowUp:
    sidebarMoveUp(state.sidebar)

  of kkCtrlKey:
    case key.ctrl
    of 'w':
      state.sidebar.focused = false
      state.mode = mNormal
    of 'b':
      toggleSidebar(state.sidebar)
      if not state.sidebar.visible:
        state.sidebar.focused = false
        state.mode = mNormal
    else:
      discard

  else:
    discard
