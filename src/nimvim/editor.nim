## Editor: main loop and state management

import types
import buffer
import terminal
import viewport
import renderer
import sidebar
import mode_normal
import mode_insert
import mode_command
import mode_explore

proc newEditorState*(filePath: string = ""): EditorState =
  result.buffer = newBuffer(filePath)
  result.cursor = Position(line: 0, col: 0)
  result.mode = mNormal
  result.running = true
  result.sidebar = initSidebar()

proc run*(state: var EditorState) =
  enableRawMode()
  defer: disableRawMode()

  while state.running:
    # Update viewport dimensions
    let size = getTerminalSize()
    state.viewport.height = size.height - 2  # status + command lines
    state.viewport.width = size.width

    # Reduce editor width when sidebar is visible
    if state.sidebar.visible:
      state.viewport.width = size.width - state.sidebar.width - 1

    # Adjust viewport to keep cursor visible
    adjustViewport(state.viewport, state.cursor, state.buffer.lineCount)

    # Render
    render(state)

    # Read input
    let key = readKey()
    if key.kind == kkNone:
      continue

    # Dispatch to mode handler
    case state.mode
    of mNormal:
      handleNormalMode(state, key)
    of mInsert:
      handleInsertMode(state, key)
    of mCommand:
      handleCommandMode(state, key)
    of mExplore:
      handleExploreMode(state, key)
