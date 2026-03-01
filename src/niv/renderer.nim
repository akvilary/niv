## Screen rendering pipeline

import std/[strutils, os]
import types
import buffer
import terminal
import viewport
import lsp_manager
import lsp_client
import lsp_types
import highlight
import git

# Tokyo Night Storm palette
const
  colBg       = 0x24283b
  colFg       = 0xc0caf5
  colGutter   = 0x3b4261
  colDarkBg   = 0x1f2335
  colCursorLn = 0x292e42
  colError    = 0xdb4b4b
  colWarning  = 0xe0af68
  colGreen    = 0x9ece6a
  colRed      = 0xf7768e
  colYellow   = 0xe0af68
  colCyan     = 0x7dcfff

proc renderSidebar(state: EditorState, editorRows: int) =
  let sb = state.sidebar
  let w = sb.width
  let visibleRows = editorRows

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

proc renderGitCommitEditor(state: EditorState, startRow, panelHeight, totalWidth: int) =
  ## Render commit message editor in the git panel area
  let lnWidth = lineNumberWidth(state.buffer.lineCount)
  let textWidth = totalWidth - lnWidth
  let contentRows = panelHeight - 1  # -1 for help line

  # Separator with title
  moveCursor(startRow, 1)
  setColorFg(colGutter)
  let title = " Commit Message "
  let leftBorder = max(1, (totalWidth - title.len) div 2)
  let rightBorder = max(0, totalWidth - leftBorder - title.len)
  stdout.write("\xe2\x94\x80".repeat(leftBorder))  # ─
  setColorFg(colCyan)
  stdout.write(title)
  setColorFg(colGutter)
  stdout.write("\xe2\x94\x80".repeat(rightBorder))  # ─
  setThemeFg()

  # Render buffer lines
  for row in 0..<contentRows:
    moveCursor(startRow + 1 + row, 1)
    setThemeColors()
    clearLine()

    let lineNum = state.viewport.topLine + row
    if lineNum < state.buffer.lineCount:
      let numStr = $(lineNum + 1)
      let padding = lnWidth - numStr.len - 1
      setColorFg(colGutter)
      stdout.write(spaces(padding) & numStr & " ")
      setThemeFg()

      let line = state.buffer.lines[lineNum]
      let startCol = state.viewport.leftCol
      if startCol < line.len:
        let endCol = min(startCol + textWidth, line.len)
        stdout.write(line[startCol..<endCol])
    else:
      setColorFg(colGutter)
      stdout.write("~")
      setThemeFg()

  # Help line
  moveCursor(startRow + 1 + contentRows, 1)
  setThemeColors()
  clearLine()
  let modeHint = if state.mode == mInsert: "INSERT" else: "NORMAL"
  let helpLine = " " & modeHint & "  :wq commit  :q cancel"
  setColorFg(colGutter)
  let truncHelp = if helpLine.len > totalWidth: helpLine[0..<totalWidth] else: helpLine
  stdout.write(truncHelp)
  setThemeFg()

proc renderGitPanel(state: EditorState, startRow, panelHeight, totalWidth: int) =
  let gp = state.gitPanel
  let contentWidth = totalWidth

  if gp.inCommitInput:
    renderGitCommitEditor(state, startRow, panelHeight, totalWidth)
    return

  # Separator line
  moveCursor(startRow, 1)
  setColorFg(colGutter)
  stdout.write("\xe2\x94\x80".repeat(contentWidth))  # ─
  setThemeFg()

  case gp.view
  of gvFiles:
    # Build display list: Staged section, then Changes section
    var displayLines: seq[tuple[text: string, isHeader: bool, fileIdx: int]] = @[]

    # Count staged and unstaged
    var stagedFiles: seq[int] = @[]
    var unstagedFiles: seq[int] = @[]
    for i, f in gp.files:
      if f.isStaged:
        stagedFiles.add(i)
      else:
        unstagedFiles.add(i)

    if stagedFiles.len > 0:
      displayLines.add((" Staged (" & $stagedFiles.len & "):", true, -1))
      for idx in stagedFiles:
        let f = gp.files[idx]
        displayLines.add(("   " & f.statusChar & "  " & f.path, false, idx))

    if unstagedFiles.len > 0:
      displayLines.add((" Changes (" & $unstagedFiles.len & "):", true, -1))
      for idx in unstagedFiles:
        let f = gp.files[idx]
        displayLines.add(("   " & f.statusChar & "  " & f.path, false, idx))

    if displayLines.len == 0:
      displayLines.add((" No changes", true, -1))

    # Help line
    let helpLine = " s:stage/unstage  d:discard  c:commit  l:log  Enter:diff  r:refresh  q:close"

    # Adjust scroll to keep cursor visible
    # Map cursorIndex to display line index
    var cursorDisplayIdx = -1
    for i, dl in displayLines:
      if dl.fileIdx == gp.cursorIndex:
        cursorDisplayIdx = i
        break

    let contentRows = panelHeight - 2  # minus separator and help line
    var scrollOff = gp.scrollOffset
    if cursorDisplayIdx >= 0:
      if cursorDisplayIdx < scrollOff:
        scrollOff = cursorDisplayIdx
      elif cursorDisplayIdx >= scrollOff + contentRows:
        scrollOff = cursorDisplayIdx - contentRows + 1

    for row in 0..<panelHeight - 1:
      moveCursor(startRow + 1 + row, 1)
      setThemeColors()
      clearLine()

      if row < contentRows:
        let idx = scrollOff + row
        if idx < displayLines.len:
          let dl = displayLines[idx]
          if dl.isHeader:
            setColorFg(colCyan)
            let truncated = if dl.text.len > contentWidth: dl.text[0..<contentWidth] else: dl.text
            stdout.write(truncated)
            setThemeFg()
          else:
            let isSelected = dl.fileIdx == gp.cursorIndex
            if isSelected:
              setColorBg(colCursorLn)

            let f = gp.files[dl.fileIdx]
            # Color the status char
            let prefix = "   "
            let statusCh = $f.statusChar
            let rest = "  " & f.path
            let fullLine = prefix & statusCh & rest
            let truncated = if fullLine.len > contentWidth: fullLine[0..<contentWidth] else: fullLine

            if f.isStaged:
              stdout.write(prefix)
              setColorFg(colGreen)
              stdout.write(statusCh)
              setThemeFg()
              stdout.write(rest)
            elif f.isUntracked:
              stdout.write(prefix)
              setColorFg(colYellow)
              stdout.write(statusCh)
              setThemeFg()
              stdout.write(rest)
            else:
              stdout.write(prefix)
              setColorFg(colRed)
              stdout.write(statusCh)
              setThemeFg()
              stdout.write(rest)

            # Pad to fill line if selected
            if isSelected:
              let written = truncated.len
              if written < contentWidth:
                stdout.write(spaces(contentWidth - written))
              setThemeColors()
      elif row == contentRows:
        # Help line
        setColorFg(colGutter)
        let truncHelp = if helpLine.len > contentWidth: helpLine[0..<contentWidth] else: helpLine
        stdout.write(truncHelp)
        setThemeFg()

  of gvDiff:
    let contentRows = panelHeight - 2  # minus separator and help line
    let helpLine = " q:back  j/k:scroll"

    for row in 0..<panelHeight - 1:
      moveCursor(startRow + 1 + row, 1)
      setThemeColors()
      clearLine()

      if row < contentRows:
        let lineIdx = gp.diffScrollOffset + row
        if lineIdx < gp.diffLines.len:
          let line = gp.diffLines[lineIdx]
          let truncated = if line.len > contentWidth: line[0..<contentWidth] else: line
          if line.len > 0 and line[0] == '+':
            setColorFg(colGreen)
            stdout.write(truncated)
            setThemeFg()
          elif line.len > 0 and line[0] == '-':
            setColorFg(colRed)
            stdout.write(truncated)
            setThemeFg()
          elif line.startsWith("@@"):
            setColorFg(colCyan)
            stdout.write(truncated)
            setThemeFg()
          elif line.startsWith("diff ") or line.startsWith("index ") or
               line.startsWith("---") or line.startsWith("+++"):
            setColorFg(colGutter)
            stdout.write(truncated)
            setThemeFg()
          else:
            stdout.write(truncated)
      elif row == contentRows:
        setColorFg(colGutter)
        let truncHelp = if helpLine.len > contentWidth: helpLine[0..<contentWidth] else: helpLine
        stdout.write(truncHelp)
        setThemeFg()

  of gvLog:
    let contentRows = panelHeight - 2  # minus separator and help line
    let helpLine = " q:back  j/k:scroll"

    # Adjust scroll to keep cursor visible
    var scrollOff = gp.logScrollOffset
    if gp.logCursorIndex < scrollOff:
      scrollOff = gp.logCursorIndex
    elif gp.logCursorIndex >= scrollOff + contentRows:
      scrollOff = gp.logCursorIndex - contentRows + 1

    for row in 0..<panelHeight - 1:
      moveCursor(startRow + 1 + row, 1)
      setThemeColors()
      clearLine()

      if row == 0 and scrollOff == 0:
        setColorFg(colCyan)
        stdout.write(" Recent commits:")
        setThemeFg()
      elif row < contentRows:
        let adjustedRow = if scrollOff == 0: row - 1 else: row
        let idx = scrollOff + adjustedRow
        if idx >= 0 and idx < gp.logEntries.len:
          let entry = gp.logEntries[idx]
          let isSelected = idx == gp.logCursorIndex

          if isSelected:
            setColorBg(colCursorLn)

          stdout.write("   ")
          setColorFg(colYellow)
          stdout.write(entry.hash)
          setThemeFg()
          stdout.write(" " & entry.message)

          if isSelected:
            let written = 3 + entry.hash.len + 1 + entry.message.len
            if written < contentWidth:
              stdout.write(spaces(contentWidth - written))
            setThemeColors()
      elif row == contentRows:
        setColorFg(colGutter)
        let truncHelp = if helpLine.len > contentWidth: helpLine[0..<contentWidth] else: helpLine
        stdout.write(truncHelp)
        setThemeFg()

proc render*(state: EditorState) =
  let size = getTerminalSize()
  let totalWidth = size.width
  let height = size.height

  let sidebarVisible = state.sidebar.visible
  let colOffset = if sidebarVisible: state.sidebar.width + 1 else: 0
  let editorWidth = totalWidth - colOffset

  # Calculate git panel height
  let gitPanelVisible = state.gitPanel.visible
  let panelHeight = if gitPanelVisible: state.gitPanel.height else: 0
  let editorRows = height - 2 - (if gitPanelVisible: panelHeight + 1 else: 0)  # +1 for separator
  let inCommit = state.gitPanel.inCommitInput

  # Choose which buffer to render in the editor area
  let renderBuffer = if inCommit: state.gitPanel.savedBuffer else: state.buffer
  let renderTopLine = if inCommit: state.gitPanel.savedTopLine else: state.viewport.topLine
  let renderLeftCol = if inCommit: 0 else: state.viewport.leftCol

  let lnWidth = lineNumberWidth(renderBuffer.lineCount)
  let textWidth = editorWidth - lnWidth
  let useLspHighlight = semanticLines.len > 0 and not inCommit

  hideCursor()
  setThemeColors()

  # Draw sidebar
  if sidebarVisible and not inCommit:
    renderSidebar(state, editorRows)
    setThemeColors()

  # Draw editor buffer (frozen when in commit mode)
  for row in 0..<editorRows:
    moveCursor(row + 1, colOffset + 1)
    clearLine()

    let lineNum = renderTopLine + row

    if lineNum < renderBuffer.lineCount:
      let numStr = $(lineNum + 1)
      let padding = lnWidth - numStr.len - 1

      # Color line number by diagnostic severity
      var diagSev = 0  # 0=none, 1=error, 2=warning
      if not inCommit:
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

      let line = renderBuffer.lines[lineNum]
      let startCol = renderLeftCol
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

  # Draw git panel
  if gitPanelVisible:
    let panelStartRow = editorRows + 1
    setThemeColors()
    renderGitPanel(state, panelStartRow, panelHeight + 1, totalWidth)

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
    of mGit: " GIT "

  let filename = if state.buffer.filePath.len > 0:
    extractFilename(state.buffer.filePath)
  else:
    "[No Name]"

  let modFlag = if state.buffer.modified: " [+]" else: ""
  let lspIndicator = if not lspIsActive(): ""
    elif tokenLegend.len > 0 and state.buffer.lineCount > 0:
      let highlighted = if bgHighlightNextLine >= 0: bgHighlightNextLine
                        elif bgHighlightTotalLines > 0: bgHighlightTotalLines
                        else: 0
      let pct = min(100, highlighted * 100 div state.buffer.lineCount)
      if pct == 100: " LSP:" & activeLspLanguageId
      else: " LSP:" & $pct & "%"
    else: " LSP"
  let leftPart = modeStr & " " & filename & modFlag

  # Diagnostic counts for status bar
  var errCount, warnCount = 0
  for d in currentDiagnostics:
    if d.severity == dsError: inc errCount
    elif d.severity == dsWarning: inc warnCount
  let diagPart = if errCount > 0 or warnCount > 0:
    "E:" & $errCount & " W:" & $warnCount & "  "
  else:
    ""
  let positionPart = if not state.buffer.fullyLoaded and state.buffer.estimatedTotalLines > 0:
    let loadPct = min(99, state.buffer.lineCount * 100 div state.buffer.estimatedTotalLines)
    $loadPct & "%:1"
  else:
    $(state.cursor.line + 1) & "/" & $state.buffer.lineCount & ":" & $(state.cursor.col + 1)
  let rightPart = lspIndicator & " " & state.buffer.encoding & " " & diagPart & positionPart & " "

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
  else:
    if state.gitBranch.len > 0:
      let gitLabel = " GIT "
      let pad = max(modeStr.len + 1 - gitLabel.len, 1)
      let branchLeft = gitLabel & spaces(pad) & state.gitBranch
      let diffRight = if state.gitDiffStat.len > 0: state.gitDiffStat & " " else: ""
      let cmdGap = max(totalWidth - branchLeft.len - diffRight.len, 0)
      stdout.write(branchLeft & spaces(cmdGap) & diffRight)

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
  if state.mode == mExplore or (state.mode == mGit and not inCommit):
    hideCursor()
  elif inCommit and state.mode != mCommand:
    # Place cursor in the git panel commit editor area
    let commitLnWidth = lineNumberWidth(state.buffer.lineCount)
    let panelStartRow = editorRows + 1  # separator row
    let screenRow = panelStartRow + 1 + (state.cursor.line - state.viewport.topLine)
    let screenCol = state.cursor.col - state.viewport.leftCol + commitLnWidth + 1
    moveCursor(screenRow, screenCol)
    showCursor()
  elif state.mode == mCommand:
    # Command line cursor
    moveCursor(height, 1 + state.commandLine.len + 1)
    showCursor()
  else:
    let screenRow = state.cursor.line - state.viewport.topLine + 1
    let screenCol = state.cursor.col - state.viewport.leftCol + lnWidth + colOffset + 1
    moveCursor(screenRow, screenCol)
    showCursor()

  flushOut()
