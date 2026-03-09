## Explore mode (sidebar focused) key handler

import std/unicode
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
    sendDidOpen(filePath, state.buffer.data)
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
    of Rune(ord('j')):
      sidebarMoveDown(state.sidebar)
    of Rune(ord('k')):
      sidebarMoveUp(state.sidebar)
    of Rune(ord('l')):
      let filePath = sidebarExpandOrOpen(state.sidebar)
      if filePath.len > 0:
        openFileFromSidebar(state, filePath)
    of Rune(ord('h')):
      sidebarCollapse(state.sidebar)
    of Rune(ord('-')):
      sidebarCollapse(state.sidebar)
    of Rune(ord('q')):
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
    of Rune(ord('w')):
      state.sidebar.focused = false
      state.mode = mNormal
    of Rune(ord('e')):
      toggleSidebar(state.sidebar)
      if not state.sidebar.visible:
        state.sidebar.focused = false
        state.mode = mNormal
    else:
      discard

  else:
    discard
