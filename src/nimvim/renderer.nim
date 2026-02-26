## Screen rendering pipeline

import std/strutils
import types
import buffer
import terminal
import viewport
import sidebar

proc renderSidebar(state: EditorState, height: int) =
  let sb = state.sidebar
  let w = sb.width
  let visibleRows = height - 2

  # Header
  moveCursor(1, 1)
  setInverseVideo()
  let header = " FILE EXPLORER"
  let truncHeader = if header.len > w: header[0..<w] else: header
  stdout.write(truncHeader)
  if truncHeader.len < w:
    stdout.write(spaces(w - truncHeader.len))
  resetAttributes()

  # Tree entries
  for row in 1..<visibleRows:
    moveCursor(row + 1, 1)
    let idx = sb.scrollOffset + row - 1

    if idx < sb.flatList.len:
      let node = sb.flatList[idx]
      let indent = spaces(node.depth * 2)
      let icon = if node.kind == fnkDirectory:
        if node.expanded: "v " else: "> "
      else:
        "  "
      let suffix = if node.kind == fnkDirectory: "/" else: ""
      let label = indent & icon & node.name & suffix

      if idx == sb.cursorIndex and sb.focused:
        setInverseVideo()

      let truncated = if label.len > w: label[0..<w] else: label
      stdout.write(truncated)
      if truncated.len < w:
        stdout.write(spaces(w - truncated.len))

      if idx == sb.cursorIndex and sb.focused:
        resetAttributes()
    else:
      stdout.write(spaces(w))

  # Vertical separator
  for row in 1..visibleRows:
    moveCursor(row, w + 1)
    setDim()
    stdout.write("\xe2\x94\x82")  # │ (U+2502)
    resetAttributes()

proc render*(state: EditorState) =
  let size = getTerminalSize()
  let totalWidth = size.width
  let height = size.height

  let sidebarVisible = state.sidebar.visible
  let colOffset = if sidebarVisible: state.sidebar.width + 1 else: 0
  let editorWidth = totalWidth - colOffset

  let lnWidth = lineNumberWidth(state.buffer.lineCount)
  let textWidth = editorWidth - lnWidth

  hideCursor()

  # Draw sidebar
  if sidebarVisible:
    var sb = state.sidebar
    adjustSidebarScroll(sb, height - 3)
    renderSidebar(state, height)

  # Draw editor buffer
  for row in 0..<height - 2:
    moveCursor(row + 1, colOffset + 1)
    clearLine()

    let lineNum = state.viewport.topLine + row

    if lineNum < state.buffer.lineCount:
      let numStr = $(lineNum + 1)
      let padding = lnWidth - numStr.len - 1
      setDim()
      stdout.write(spaces(padding) & numStr & " ")
      resetAttributes()

      let line = state.buffer.lines[lineNum]
      let startCol = state.viewport.leftCol
      if startCol < line.len:
        let endCol = min(startCol + textWidth, line.len)
        stdout.write(line[startCol..<endCol])
    else:
      setDim()
      stdout.write("~")
      resetAttributes()

  # Status line
  moveCursor(height - 1, 1)
  clearLine()
  setInverseVideo()

  let modeStr = case state.mode
    of mNormal: " NORMAL "
    of mInsert: " INSERT "
    of mCommand: " COMMAND "
    of mExplore: " EXPLORE "

  let filename = if state.buffer.filePath.len > 0:
    state.buffer.filePath
  else:
    "[No Name]"

  let modFlag = if state.buffer.modified: " [+]" else: ""
  let leftPart = modeStr & " " & filename & modFlag
  let rightPart = " " & $(state.cursor.line + 1) & ":" & $(state.cursor.col + 1) & " "

  let gap = max(totalWidth - leftPart.len - rightPart.len, 0)
  stdout.write(leftPart & spaces(gap) & rightPart)
  resetAttributes()

  # Command / message line
  moveCursor(height, 1)
  clearLine()
  if state.mode == mCommand:
    stdout.write(":" & state.commandLine)
  elif state.statusMessage.len > 0:
    stdout.write(state.statusMessage)

  # Position cursor
  if state.mode == mExplore:
    hideCursor()
  else:
    let screenRow = state.cursor.line - state.viewport.topLine + 1
    let screenCol = state.cursor.col - state.viewport.leftCol + lnWidth + colOffset + 1
    moveCursor(screenRow, screenCol)
    showCursor()

  flushOut()
