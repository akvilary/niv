## Screen rendering pipeline

import std/strutils
import types
import buffer
import terminal
import viewport
import sidebar
import lsp_manager
import lsp_client
import lsp_types
import highlight

# Tokyo Night Storm palette
const
  colBg       = 0x24283b
  colFg       = 0xc0caf5
  colGutter   = 0x3b4261
  colDarkBg   = 0x1f2335
  colCursorLn = 0x292e42
  colError    = 0xdb4b4b
  colWarning  = 0xe0af68

proc renderSidebar(state: EditorState, height: int) =
  let sb = state.sidebar
  let w = sb.width
  let visibleRows = height - 2

  # Header
  moveCursor(1, 1)
  setColorBg(colDarkBg)
  setColorFg(colFg)
  let header = " FILE EXPLORER"
  let truncHeader = if header.len > w: header[0..<w] else: header
  stdout.write(truncHeader)
  if truncHeader.len < w:
    stdout.write(spaces(w - truncHeader.len))
  setThemeColors()

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
        setColorBg(colCursorLn)

      let truncated = if label.len > w: label[0..<w] else: label
      stdout.write(truncated)
      if truncated.len < w:
        stdout.write(spaces(w - truncated.len))

      if idx == sb.cursorIndex and sb.focused:
        setThemeColors()
    else:
      stdout.write(spaces(w))

  # Vertical separator
  for row in 1..visibleRows:
    moveCursor(row, w + 1)
    setColorFg(colGutter)
    stdout.write("\xe2\x94\x82")  # │ (U+2502)
    setThemeFg()

proc renderModalRow(startCol, innerWidth: int, line: string) =
  ## Render a single content row inside the modal: │ content │
  setColorFg(colGutter)
  stdout.write("\xe2\x94\x82")  # │
  setThemeFg()
  let truncated = if line.len > innerWidth: line[0..<innerWidth] else: line
  stdout.write(truncated)
  if truncated.len < innerWidth:
    stdout.write(spaces(innerWidth - truncated.len))
  setColorFg(colGutter)
  stdout.write("\xe2\x94\x82")  # │
  setThemeFg()

proc renderLspManagerModal(totalWidth, height: int) =
  let mgr = lspMgr
  if not mgr.visible:
    return

  let modalWidth = min(totalWidth - 4, max(60, totalWidth * 2 div 3))
  let hasStatus = mgr.statusMessage.len > 0
  let contentRows = mgr.servers.len + 3 + (if hasStatus: 1 else: 0)
  let modalHeight = min(contentRows + 2, height - 4)
  let startCol = (totalWidth - modalWidth) div 2 + 1
  let startRow = (height - modalHeight) div 2 + 1
  let innerWidth = modalWidth - 2

  for row in 0..<modalHeight:
    moveCursor(startRow + row, startCol)
    if row == 0:
      let title = " LSP Manager "
      let borderLen = modalWidth - 2 - title.len
      let leftBorder = max(0, borderLen div 2)
      let rightBorder = max(0, borderLen - leftBorder)
      setColorFg(colGutter)
      stdout.write("\xe2\x94\x8c")  # ┌
      stdout.write("\xe2\x94\x80".repeat(leftBorder))  # ─
      setThemeFg()
      stdout.write(title)
      setColorFg(colGutter)
      stdout.write("\xe2\x94\x80".repeat(rightBorder))  # ─
      stdout.write("\xe2\x94\x90")  # ┐
      setThemeFg()
    elif row == modalHeight - 1:
      setColorFg(colGutter)
      stdout.write("\xe2\x94\x94")  # └
      stdout.write("\xe2\x94\x80".repeat(modalWidth - 2))  # ─
      stdout.write("\xe2\x94\x98")  # ┘
      setThemeFg()
    else:
      let contentRow = row - 1

      if contentRow == 0:
        renderModalRow(startCol, innerWidth, "")
      elif contentRow >= 1 and contentRow <= mgr.servers.len:
        let idx = contentRow - 1
        let srv = mgr.servers[idx]
        let icon = if srv.installed: "\xe2\x97\x8f " else: "\xe2\x97\x8b "  # ● / ○
        let status = if srv.installed: " [installed]" else: ""
        let langs = " [" & srv.languages[0] & "]"
        let line = " " & icon & srv.name & langs & status

        if idx == mgr.cursorIndex:
          setColorBg(colCursorLn)
          setColorFg(colGutter)
          stdout.write("\xe2\x94\x82")  # │
          setThemeFg()
          let truncated = if line.len > innerWidth: line[0..<innerWidth] else: line
          stdout.write(truncated)
          if truncated.len < innerWidth:
            stdout.write(spaces(innerWidth - truncated.len))
          setColorFg(colGutter)
          stdout.write("\xe2\x94\x82")  # │
          setThemeColors()
        else:
          renderModalRow(startCol, innerWidth, line)
      elif contentRow == mgr.servers.len + 1:
        renderModalRow(startCol, innerWidth, "")
      elif contentRow == mgr.servers.len + 2:
        renderModalRow(startCol, innerWidth, " i:install X:uninstall q:close")
      elif contentRow == mgr.servers.len + 3 and hasStatus:
        let statusLine = " " & mgr.statusMessage
        renderModalRow(startCol, innerWidth, statusLine)

proc render*(state: EditorState) =
  let size = getTerminalSize()
  let totalWidth = size.width
  let height = size.height

  let sidebarVisible = state.sidebar.visible
  let colOffset = if sidebarVisible: state.sidebar.width + 1 else: 0
  let editorWidth = totalWidth - colOffset

  let lnWidth = lineNumberWidth(state.buffer.lineCount)
  let textWidth = editorWidth - lnWidth
  let useLspHighlight = semanticLines.len > 0

  hideCursor()
  setThemeColors()

  # Draw sidebar
  if sidebarVisible:
    var sb = state.sidebar
    adjustSidebarScroll(sb, height - 3)
    renderSidebar(state, height)
    setThemeColors()

  # Draw editor buffer
  for row in 0..<height - 2:
    moveCursor(row + 1, colOffset + 1)
    clearLine()

    let lineNum = state.viewport.topLine + row

    if lineNum < state.buffer.lineCount:
      let numStr = $(lineNum + 1)
      let padding = lnWidth - numStr.len - 1

      # Color line number by diagnostic severity
      var diagSev = 0  # 0=none, 1=error, 2=warning
      for d in currentDiagnostics:
        if d.range.startLine == lineNum:
          if d.severity == dsError:
            diagSev = 1
            break
          elif d.severity == dsWarning and diagSev == 0:
            diagSev = 2

      if diagSev == 1:
        setColorFg(colError)
      elif diagSev == 2:
        setColorFg(colWarning)
      else:
        setColorFg(colGutter)
      stdout.write(spaces(padding) & numStr & " ")
      setThemeFg()

      let line = state.buffer.lines[lineNum]
      let startCol = state.viewport.leftCol
      if startCol < line.len:
        let endCol = min(startCol + textWidth, line.len)
        if useLspHighlight and lineNum < semanticLines.len and semanticLines[lineNum].len > 0:
          # LSP semantic tokens (highest priority)
          let tokens = semanticLines[lineNum]
          var col = startCol
          for token in tokens:
            let tEnd = token.col + token.length
            if tEnd <= startCol: continue
            if token.col >= endCol: break
            if col < token.col:
              let gapEnd = min(token.col, endCol)
              if col < gapEnd: stdout.write(line[col..<gapEnd])
              col = gapEnd
            let tStart = max(token.col, startCol)
            let tEndClamped = min(tEnd, endCol)
            if tStart < tEndClamped and tStart < line.len:
              let typeName = if token.tokenType < tokenLegend.len: tokenLegend[token.tokenType] else: ""
              let color = tokenColor(typeName)
              if color != 0: setColorFg(color)
              stdout.write(line[tStart..<min(tEndClamped, line.len)])
              if color != 0: setThemeFg()
            col = max(col, tEndClamped)
          if col < endCol: stdout.write(line[col..<endCol])
        else:
          stdout.write(line[startCol..<endCol])
    else:
      setColorFg(colGutter)
      stdout.write("~")
      setThemeFg()

  # Status line
  moveCursor(height - 1, 1)
  resetAttributes()
  setColorBg(colDarkBg)
  setColorFg(colFg)
  clearLine()

  let modeStr = case state.mode
    of mNormal: " NORMAL "
    of mInsert: " INSERT "
    of mCommand: " COMMAND "
    of mExplore: " EXPLORE "
    of mLspManager: " LSP "

  let filename = if state.buffer.filePath.len > 0:
    state.buffer.filePath
  else:
    "[No Name]"

  let modFlag = if state.buffer.modified: " [+]" else: ""
  let lspIndicator = if not lspIsActive(): ""
    elif tokenLegend.len > 0 and state.buffer.lineCount > 0:
      let highlighted = if bgHighlightNextLine >= 0: bgHighlightNextLine
                        elif bgHighlightTotalLines > 0: bgHighlightTotalLines
                        else: 0
      let pct = min(100, highlighted * 100 div state.buffer.lineCount)
      " [LSP|" & $pct & "%]"
    else: " [LSP]"
  let loadingIndicator = if not state.buffer.fullyLoaded and state.buffer.totalSize > 0:
    let pct = int(state.buffer.loadedBytes * 100 div state.buffer.totalSize)
    " [Loading " & $pct & "%]"
  else:
    ""
  let leftPart = modeStr & " " & filename & modFlag & lspIndicator & loadingIndicator

  # Diagnostic counts for status bar
  var errCount, warnCount = 0
  for d in currentDiagnostics:
    if d.severity == dsError: inc errCount
    elif d.severity == dsWarning: inc warnCount
  let diagPart = if errCount > 0 or warnCount > 0:
    "E:" & $errCount & " W:" & $warnCount & "  "
  else:
    ""
  let rightPart = diagPart & $(state.cursor.line + 1) & ":" & $(state.cursor.col + 1) & " "

  let gap = max(totalWidth - leftPart.len - rightPart.len, 0)
  stdout.write(leftPart & spaces(gap) & rightPart)

  # Command / message line
  moveCursor(height, 1)
  setThemeColors()
  clearLine()
  if state.mode == mCommand:
    stdout.write(":" & state.commandLine)
  elif state.statusMessage.len > 0:
    stdout.write(state.statusMessage)

  # Modal overlays
  if state.mode == mLspManager:
    setThemeColors()
    renderLspManagerModal(totalWidth, height)
    hideCursor()
    flushOut()
    return
  # Completion popup overlay (drawn after main content)
  if completionState.active and completionState.items.len > 0 and state.mode == mInsert:
    let maxItems = min(10, completionState.items.len)
    let maxWidth = 40
    let screenRow = state.cursor.line - state.viewport.topLine + 2  # one row below cursor
    let screenCol = completionState.triggerCol - state.viewport.leftCol + lnWidth + colOffset + 1

    for i in 0..<maxItems:
      let popupRow = screenRow + i
      if popupRow >= height - 1:
        break  # Don't draw over status line
      moveCursor(popupRow, screenCol)

      let item = completionState.items[i]
      let label = if item.label.len > maxWidth: item.label[0..<maxWidth]
                  else: item.label
      let padded = label & spaces(max(0, maxWidth - label.len))

      if i == completionState.selectedIndex:
        setColorBg(colCursorLn)
        stdout.write(padded)
        setThemeColors()
      else:
        setColorBg(colDarkBg)
        setColorFg(colFg)
        stdout.write(padded)
        setThemeColors()

  # Position cursor
  if state.mode == mExplore:
    hideCursor()
  else:
    let screenRow = state.cursor.line - state.viewport.topLine + 1
    let screenCol = state.cursor.col - state.viewport.leftCol + lnWidth + colOffset + 1
    moveCursor(screenRow, screenCol)
    showCursor()

  flushOut()
