## Explore mode (sidebar focused) key handler

import std/strutils
import types
import buffer
import sidebar
import lsp_client
import lsp_types
import highlight
import fileio

proc openFileFromSidebar(state: var EditorState, filePath: string) =
  ## Open a file from the sidebar with proper LSP integration
  stopFileLoader()
  resetViewportRangeCache()

  state.buffer = newBuffer(filePath)
  state.cursor = Position(line: 0, col: 0)
  state.viewport.topLine = 0
  state.viewport.leftCol = 0
  state.sidebar.focused = false
  state.mode = mNormal
  state.statusMessage = "\"" & filePath & "\""

  switchLsp(filePath)
  if lspState == lsRunning:
    let text = state.buffer.lines.join("\n")
    sendDidOpen(filePath, text)
    lspSyncedLines = state.buffer.lineCount
    if tokenLegend.len > 0 and lspHasSemanticTokensRange:
      sendSemanticTokensRange(0, min(state.buffer.lineCount - 1, 50))
      startBgHighlight(state.buffer.lineCount)

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
