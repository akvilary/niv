## Screen rendering pipeline
## Each component renders into its own ScreenBuffer for isolated clipping

import std/[strutils, os, unicode]
import types
import buffer
import git
import terminal
import viewport
import lsp_manager
import lsp_client
import lsp_types
import highlight
import git
import unicode_width
import path_manager
import screenbuffer

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
  colSearchBg = 0x3d4f7a
  colPurple   = 0x9d7cd8
  colBlue     = 0x7aa2f7
  colComment  = 0x565f89
  colTeal     = 0x73daca

# Persistent buffers (reused across renders to avoid allocation)
var sidebarBuf: ScreenBuffer
var editorBuf: ScreenBuffer
var gitBuf: ScreenBuffer
var statusBuf: ScreenBuffer

proc renderSidebar(buf: var ScreenBuffer, sb: var SidebarState, editorRows: int) =
  let w = sb.width
  let hScroll = sb.horizontalScroll

  # Header
  buf.move(0, 0)
  buf.setBg(colDarkBg)
  buf.setFg(colFg)
  buf.write(" FILE EXPLORER")
  buf.clearToEol()
  # Separator on header row
  buf.move(0, w)
  buf.resetColors()
  buf.setFg(colGutter)
  buf.write("\xe2\x94\x82")  # │
  buf.resetFg()

  # Tree entries
  for row in 1..<editorRows:
    let idx = sb.scrollOffset + row - 1

    if idx < sb.flatList.len:
      let node = sb.flatList[idx]
      let indent = spaces(node.depth * 2)
      let icon = if node.kind == fnkDirectory:
        if node.expanded: "\xF0\x9F\x93\x82 " else: "\xF0\x9F\x93\x81 "  # 📂 / 📁
      else:
        "  "
      let suffix = if node.kind == fnkDirectory: "/" else: ""

      buf.resetColors()
      if idx == sb.cursorIndex and sb.focused:
        buf.setBg(colCursorLn)

      # Write with left-edge clipping via negative column
      buf.move(row, -hScroll)

      let inPath = isPathSaved(node.path)
      if inPath:
        buf.setFg(colCyan)
        buf.write(indent & icon & node.name & suffix)
      elif node.kind == fnkDirectory:
        buf.setFg(colBlue)
        buf.write(indent & icon & node.name & suffix)
      else:
        # Multi-color: prefix, basename, extension
        buf.setFg(colFg)
        buf.write(indent & icon)
        let dotIdx = node.name.rfind('.')
        if dotIdx > 0:
          buf.setFg(colFg)
          buf.write(node.name[0..<dotIdx])
          buf.setFg(colTeal)
          buf.write(node.name[dotIdx..^1])
        else:
          buf.setFg(colComment)
          buf.write(node.name)

      # Fill rest of row (handles padding automatically)
      if buf.curCol < 0:
        buf.curCol = 0
      buf.clearToEol()
      buf.resetColors()
    else:
      buf.move(row, 0)
      buf.resetColors()
      buf.clearToEol()

    # Separator column
    buf.move(row, w)
    buf.setFg(colGutter)
    buf.resetBg()
    buf.write("\xe2\x94\x82")  # │
    buf.resetFg()

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

proc renderGitCommitEditor(buf: var ScreenBuffer, state: var EditorState, panelHeight: int) =
  let totalWidth = buf.width
  let lnWidth = lineNumberWidth(state.buffer.lineCount)
  let textWidth = totalWidth - lnWidth
  let contentRows = panelHeight - 1  # -1 for help line

  # Separator with title
  buf.move(0, 0)
  buf.setFg(colGutter)
  let title = " Commit Message "
  let leftBorder = max(1, (totalWidth - title.len) div 2)
  let rightBorder = max(0, totalWidth - leftBorder - title.len)
  buf.write("\xe2\x94\x80".repeat(leftBorder))  # ─
  buf.setFg(colCyan)
  buf.write(title)
  buf.setFg(colGutter)
  buf.write("\xe2\x94\x80".repeat(rightBorder))  # ─
  buf.resetFg()

  # Render buffer lines
  for row in 0..<contentRows:
    buf.move(1 + row, 0)
    buf.resetColors()

    let lineNum = state.viewport.topLine + row
    if lineNum < state.buffer.lineCount:
      let numStr = $(lineNum + 1)
      let padding = lnWidth - numStr.len - 1
      buf.setFg(colGutter)
      buf.write(spaces(padding) & numStr & " ")
      buf.resetFg()

      let line = state.buffer.getLine(lineNum)
      let startCol = state.viewport.leftCol
      if startCol < line.len:
        buf.write(line[startCol..^1])
    else:
      buf.setFg(colGutter)
      buf.write("~")
      buf.resetFg()
    buf.clearToEol()

  # Help line
  buf.move(1 + contentRows, 0)
  buf.resetColors()
  let modeHint = if state.mode == mInsert: "INSERT" else: "NORMAL"
  let helpLine = " " & modeHint & "  :wq commit  :q cancel"
  buf.setFg(colGutter)
  buf.write(helpLine)
  buf.clearToEol()
  buf.resetFg()

proc renderGitPanel(buf: var ScreenBuffer, state: var EditorState, panelHeight: int) =
  template gp: untyped = state.gitPanel
  let contentWidth = buf.width

  if gp.inCommitInput:
    renderGitCommitEditor(buf, state, panelHeight)
    return

  # Separator line
  buf.move(0, 0)
  buf.setFg(colGutter)
  buf.write("\xe2\x94\x80".repeat(contentWidth))  # ─
  buf.resetFg()

  case gp.view
  of gvFiles:
    var displayLines: seq[tuple[text: string, isHeader: bool, fileIdx: int]] = @[]
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
        displayLines.add(("   " & $f.statusChar & "  " & f.path, false, idx))

    if unstagedFiles.len > 0:
      displayLines.add((" Changes (" & $unstagedFiles.len & "):", true, -1))
      for idx in unstagedFiles:
        let f = gp.files[idx]
        displayLines.add(("   " & $f.statusChar & "  " & f.path, false, idx))

    if displayLines.len == 0:
      displayLines.add((" No changes", true, -1))

    let helpLine = " s:stage/unstage  d:discard  c:commit  m:merge  b:branches  l:log  Enter:diff  r:refresh  q:close"

    var cursorDisplayIdx = -1
    for i, dl in displayLines:
      if dl.fileIdx == gp.cursorIndex:
        cursorDisplayIdx = i
        break

    let contentRows = panelHeight - 2
    var scrollOff = gp.scrollOffset
    if cursorDisplayIdx >= 0:
      if cursorDisplayIdx < scrollOff:
        scrollOff = cursorDisplayIdx
      elif cursorDisplayIdx >= scrollOff + contentRows:
        scrollOff = cursorDisplayIdx - contentRows + 1

    for row in 0..<panelHeight - 1:
      buf.move(1 + row, 0)
      buf.resetColors()

      if row < contentRows:
        let idx = scrollOff + row
        if idx < displayLines.len:
          let dl = displayLines[idx]
          if dl.isHeader:
            buf.setFg(colCyan)
            buf.write(dl.text)
            buf.resetFg()
          else:
            let isSelected = dl.fileIdx == gp.cursorIndex
            if isSelected:
              buf.setBg(colCursorLn)

            let f = gp.files[dl.fileIdx]
            let statusCh = $f.statusChar
            buf.write("   ")
            if f.isStaged:
              buf.setFg(colGreen)
            elif f.isUntracked:
              buf.setFg(colYellow)
            else:
              buf.setFg(colRed)
            buf.write(statusCh)
            buf.resetFg()
            buf.write("  " & f.path)

            if isSelected:
              buf.clearToEol()
              buf.resetColors()
      elif row == contentRows:
        buf.setFg(colGutter)
        buf.write(helpLine)
        buf.resetFg()
      buf.clearToEol()

  of gvDiff:
    let contentRows = panelHeight - 2
    let helpLine = " q:back  j/k:scroll"

    var lineNums: seq[int] = @[]
    var oldLine, newLine = 0
    for line in gp.diffLines:
      if line.startsWith("@@"):
        let plusIdx = line.find('+', 3)
        if plusIdx > 0:
          let commaIdx = line.find(',', plusIdx)
          let spaceIdx = line.find(' ', plusIdx)
          let endIdx = if commaIdx > 0 and commaIdx < spaceIdx: commaIdx
                       elif spaceIdx > 0: spaceIdx
                       else: line.len
          try: newLine = parseInt(line[plusIdx + 1..<endIdx])
          except ValueError: newLine = 0
          let minusStart = line.find('-', 3)
          if minusStart > 0:
            let mComma = line.find(',', minusStart)
            let mSpace = line.find(' ', minusStart)
            let mEnd = if mComma > 0 and mComma < mSpace: mComma
                        elif mSpace > 0: mSpace
                        else: line.len
            try: oldLine = parseInt(line[minusStart + 1..<mEnd])
            except ValueError: oldLine = 0
        lineNums.add(-1)
      elif line.len > 0 and line[0] == '+' and not line.startsWith("+++"):
        lineNums.add(newLine)
        inc newLine
      elif line.len > 0 and line[0] == '-' and not line.startsWith("---"):
        lineNums.add(oldLine)
        inc oldLine
      elif line.startsWith("diff ") or line.startsWith("index ") or
           line.startsWith("---") or line.startsWith("+++"):
        lineNums.add(-1)
      else:
        lineNums.add(newLine)
        inc oldLine
        inc newLine

    let lnW = 5
    let gutterW = lnW + 1

    for row in 0..<panelHeight - 1:
      buf.move(1 + row, 0)
      buf.resetColors()

      if row < contentRows:
        let lineIdx = gp.diffScrollOffset + row
        if lineIdx < gp.diffLines.len:
          let line = gp.diffLines[lineIdx]
          let num = if lineIdx < lineNums.len: lineNums[lineIdx] else: -1

          buf.setFg(colGutter)
          if num > 0:
            let s = $num
            buf.write(spaces(lnW - s.len) & s)
          else:
            buf.write(spaces(lnW))
          buf.write("\xe2\x94\x82")  # │
          buf.resetFg()

          if line.len > 0 and line[0] == '+' and not line.startsWith("+++"):
            buf.setFg(colGreen)
            buf.write(line)
            buf.resetFg()
          elif line.len > 0 and line[0] == '-' and not line.startsWith("---"):
            buf.setFg(colRed)
            buf.write(line)
            buf.resetFg()
          elif line.startsWith("@@"):
            buf.setFg(colCyan)
            buf.write(line)
            buf.resetFg()
          elif line.startsWith("diff ") or line.startsWith("index ") or
               line.startsWith("---") or line.startsWith("+++"):
            buf.setFg(colGutter)
            buf.write(line)
            buf.resetFg()
          else:
            buf.write(line)
      elif row == contentRows:
        buf.setFg(colGutter)
        buf.write(helpLine)
        buf.resetFg()
      buf.clearToEol()

  of gvLog:
    let contentRows = panelHeight - 2
    let helpLine = " q:back  j/k:scroll"

    var scrollOff = gp.logScrollOffset
    if gp.logCursorIndex < scrollOff:
      scrollOff = gp.logCursorIndex
    elif gp.logCursorIndex >= scrollOff + contentRows:
      scrollOff = gp.logCursorIndex - contentRows + 1

    for row in 0..<panelHeight - 1:
      buf.move(1 + row, 0)
      buf.resetColors()

      if row == 0 and scrollOff == 0:
        buf.setFg(colCyan)
        buf.write(" Recent commits:")
        buf.resetFg()
      elif row < contentRows:
        let adjustedRow = if scrollOff == 0: row - 1 else: row
        let idx = scrollOff + adjustedRow
        if idx >= 0 and idx < gp.logEntries.len:
          let entry = gp.logEntries[idx]
          let isSelected = idx == gp.logCursorIndex

          if isSelected:
            buf.setBg(colCursorLn)

          buf.write("   ")
          buf.setFg(colYellow)
          buf.write(entry.hash)
          buf.resetFg()
          buf.write(" " & entry.message)

          if isSelected:
            buf.clearToEol()
            buf.resetColors()
      elif row == contentRows:
        buf.setFg(colGutter)
        buf.write(helpLine)
        buf.resetFg()
      buf.clearToEol()

  of gvMergeConflicts:
    let contentRows = panelHeight - 2
    let helpLine = " o:ours  t:theirs  Enter:commit  q:abort"

    var scrollOff = gp.conflictScrollOffset
    if gp.conflictCursorIndex < scrollOff:
      scrollOff = gp.conflictCursorIndex
    elif gp.conflictCursorIndex >= scrollOff + contentRows:
      scrollOff = gp.conflictCursorIndex - contentRows + 1

    for row in 0..<panelHeight - 1:
      buf.move(1 + row, 0)
      buf.resetColors()

      if row == 0 and scrollOff == 0:
        buf.setFg(colCyan)
        buf.write(" Merge Conflicts:")
        buf.resetFg()
      elif row < contentRows:
        let adjustedRow = if scrollOff == 0: row - 1 else: row
        let idx = scrollOff + adjustedRow
        if idx >= 0 and idx < gp.conflictFiles.len:
          let cf = gp.conflictFiles[idx]
          let isSelected = idx == gp.conflictCursorIndex

          if isSelected:
            buf.setBg(colCursorLn)

          if cf.conflictCount > 0:
            buf.setFg(colRed)
            buf.write("  C ")
          else:
            buf.setFg(colGreen)
            buf.write("  \xe2\x9c\x93 ")  # ✓
          buf.resetFg()
          buf.write(cf.path)
          if cf.conflictCount > 0:
            buf.setFg(colGutter)
            buf.write(" (" & $cf.conflictCount & " conflicts)")
            buf.resetFg()

          if isSelected:
            buf.clearToEol()
            buf.resetColors()
      elif row == contentRows:
        buf.setFg(colGutter)
        buf.write(helpLine)
        buf.resetFg()
      buf.clearToEol()

  of gvBranches:
    let contentRows = panelHeight - 3
    let helpLine = " Enter:checkout  Ctrl+f:fetch  Ctrl+l:pull  Ctrl+p:push  Esc:back  \xe2\x86\x91\xe2\x86\x93:navigate"

    buf.renderSearchInput(1, $gp.branchQuery, colCyan, colGutter)

    var scrollOff = gp.branchScrollOffset
    if gp.branchCursorIndex < scrollOff:
      scrollOff = gp.branchCursorIndex
    elif gp.branchCursorIndex >= scrollOff + contentRows:
      scrollOff = gp.branchCursorIndex - contentRows + 1

    let currentBranch = gitCurrentBranch()
    for row in 0..<contentRows:
      buf.move(2 + row, 0)
      buf.resetColors()

      let idx = scrollOff + row
      if idx < gp.filteredBranches.len:
        let branch = gp.filteredBranches[idx]
        let isSelected = idx == gp.branchCursorIndex
        let isCurrent = branch == currentBranch

        if isSelected:
          buf.setBg(colCursorLn)

        if isCurrent:
          buf.setFg(colGreen)
          buf.write(" * ")
        else:
          buf.write("   ")

        buf.write(branch)

        if isSelected:
          buf.clearToEol()
          buf.resetColors()
        if isCurrent:
          buf.resetFg()
      buf.clearToEol()

    # Help line
    buf.move(2 + contentRows, 0)
    buf.resetColors()
    buf.setFg(colGutter)
    buf.write(helpLine)
    buf.clearToEol()
    buf.resetFg()

proc writeWithSearchBg(buf: var ScreenBuffer, line: string, s, e: int,
                       matchRanges: seq[tuple[startCol, endCol: int]]) =
  ## Write line[s..<e] with search highlight bg on matched ranges
  let lineLen = line.len
  if matchRanges.len == 0 or s >= e:
    if s < e and s < lineLen:
      buf.write(line[s..<min(e, lineLen)])
    return
  var col = s
  for mr in matchRanges:
    if mr.endCol <= s: continue
    if mr.startCol >= e: break
    # Gap before match
    if col < mr.startCol:
      let gapEnd = min(mr.startCol, e)
      if col < gapEnd and col < lineLen:
        buf.write(line[col..<min(gapEnd, lineLen)])
      col = gapEnd
    # Match with highlight
    let ms = max(mr.startCol, col)
    let me = min(mr.endCol, e)
    if ms < me and ms < lineLen:
      buf.setBg(colSearchBg)
      buf.write(line[ms..<min(me, lineLen)])
      buf.setBg(colBg)
    col = max(col, me)
  # Trailing gap
  if col < e and col < lineLen:
    buf.write(line[col..<min(e, lineLen)])

proc renderEditor(buf: var ScreenBuffer, state: var EditorState,
                  renderBuffer: var Buffer, topLine, leftCol, lnWidth, textWidth,
                  editorRows: int, inCommit: bool) =
  let useLspHighlight = semanticLines.len > 0 and not inCommit

  for row in 0..<editorRows:
    buf.move(row, 0)
    buf.resetColors()

    let lineNum = topLine + row

    if lineNum < renderBuffer.lineCount:
      let numStr = $(lineNum + 1)
      let padding = lnWidth - numStr.len - 1

      # Color line number by diagnostic severity
      var diagSev = 0
      if not inCommit:
        for d in currentDiagnostics:
          if d.range.startLine == lineNum:
            if d.severity == dsError:
              diagSev = 1
              break
            elif d.severity == dsWarning and diagSev == 0:
              diagSev = 2

      if diagSev == 1:
        buf.setFg(colError)
      elif diagSev == 2:
        buf.setFg(colWarning)
      else:
        buf.setFg(colGutter)
      buf.write(spaces(padding) & numStr & " ")
      buf.resetFg()

      let line = renderBuffer.getLine(lineNum)
      let startCol = leftCol
      if startCol < line.len:
        # Use endCol for performance (avoid iterating entire long lines)
        let endCol = byteOffsetForWidth(line, startCol, textWidth)

        var lineMatchRanges: seq[tuple[startCol, endCol: int]]
        if state.searchQuery.len > 0 and state.searchMatches.len > 0 and not inCommit:
          for m in state.searchMatches:
            if m.line == lineNum:
              lineMatchRanges.add((m.col, m.col + state.searchQuery.len))

        if useLspHighlight and lineNum < semanticLines.len and semanticLines[lineNum].len > 0:
          let tokens = semanticLines[lineNum]
          var col = startCol
          for token in tokens:
            let tEnd = token.col + token.length
            if tEnd <= startCol: continue
            if token.col >= endCol: break
            if col < token.col:
              let gapEnd = min(token.col, endCol)
              if col < gapEnd:
                writeWithSearchBg(buf, line, col, gapEnd, lineMatchRanges)
              col = gapEnd
            let tStart = max(token.col, startCol)
            let tEndClamped = min(tEnd, endCol)
            if tStart < tEndClamped and tStart < line.len:
              let typeName = if token.tokenType < tokenLegend.len: tokenLegend[token.tokenType] else: ""
              let color = tokenColor(typeName)
              if color != 0: buf.setFg(color)
              writeWithSearchBg(buf, line, tStart, min(tEndClamped, line.len), lineMatchRanges)
              if color != 0: buf.resetFg()
            col = max(col, tEndClamped)
          if col < endCol:
            writeWithSearchBg(buf, line, col, endCol, lineMatchRanges)
        else:
          writeWithSearchBg(buf, line, startCol, endCol, lineMatchRanges)
    else:
      buf.setFg(colGutter)
      buf.write("~")
      buf.resetFg()
    buf.clearToEol()

proc renderStatusLine(buf: var ScreenBuffer, state: var EditorState, totalWidth: int) =
  let modeStr = case state.mode
    of mNormal: " NORMAL "
    of mInsert: " INSERT "
    of mCommand: " COMMAND "
    of mExplore: " EXPLORE "
    of mLspManager: " LSP "
    of mGit: " GIT "
    of mFind: " FIND "

  # Status line (row 0)
  buf.move(0, 0)
  buf.setBg(colDarkBg)
  buf.setFg(colFg)

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
  buf.write(leftPart & spaces(gap) & rightPart)
  buf.clearToEol()

  # Command / message line (row 1)
  buf.move(1, 0)
  buf.resetColors()
  if state.mode == mCommand:
    if state.searchInput:
      buf.write("/" & state.commandLine)
    else:
      buf.write(":" & state.commandLine)
  elif state.statusMessage.len > 0:
    buf.write(state.statusMessage)
  else:
    if state.gitBranch.len > 0:
      let gitLabel = " GIT "
      let pad = max(modeStr.len + 1 - gitLabel.len, 1)
      let branchLeft = gitLabel & spaces(pad) & state.gitBranch
      let diffRight = if state.gitDiffStat.len > 0: state.gitDiffStat & " " else: ""
      let cmdGap = max(totalWidth - branchLeft.len - diffRight.len, 0)
      buf.write(branchLeft & spaces(cmdGap) & diffRight)
  buf.clearToEol()

var findBuf: ScreenBuffer

proc renderFind(buf: var ScreenBuffer, fs: var FindState, totalWidth, totalHeight: int) =
  let queryStr = $fs.query
  let listWidth = min(totalWidth div 3, 60)
  let previewWidth = totalWidth - listWidth - 1
  let contentRows = totalHeight - 3  # search + separator + help
  let helpLine = " Enter:open/toggle  \xe2\x86\x91\xe2\x86\x93:navigate  Ctrl+s:match case  Ctrl+d:dir scope  Esc:close"

  var hint = ""
  if fs.caseSensitive: hint.add("Aa")
  if fs.searchDir.len > 0:
    if hint.len > 0: hint.add("  ")
    hint.add("dir scope")
  if fs.results.len > 0:
    if hint.len > 0: hint.add("  ")
    hint.add($fs.results.len & " matches")
  buf.renderSearchInput(0, queryStr, colCyan, colGutter, hint)

  # Adjust scroll to keep cursor visible
  var scrollOff = fs.scrollOffset
  if fs.cursorIndex < scrollOff:
    scrollOff = fs.cursorIndex
  elif fs.cursorIndex >= scrollOff + contentRows:
    scrollOff = fs.cursorIndex - contentRows + 1

  let queryMatch = if fs.caseSensitive: queryStr else: queryStr.toLower()

  # Get current match index for preview highlight
  var curMatchIdx = -1
  if fs.displayItems.len > 0 and fs.cursorIndex < fs.displayItems.len:
    let curItem = fs.displayItems[fs.cursorIndex]
    if curItem.kind == fdkMatch:
      curMatchIdx = curItem.matchIdx

  for row in 0..<contentRows:
    let idx = scrollOff + row

    # Left pane: tree
    buf.move(1 + row, 0)
    buf.resetColors()

    if idx < fs.displayItems.len:
      let item = fs.displayItems[idx]
      let isSelected = idx == fs.cursorIndex

      if isSelected:
        buf.setBg(colCursorLn)

      let indent = spaces(item.depth * 2)
      let arrow = if item.kind in {fdkDir, fdkFile}:
        (if item.expanded: "\xe2\x96\xbc " else: "\xe2\x96\xb6 ")  # ▼ / ▶
      else: ""

      if item.kind == fdkDir:
        buf.write(indent)
        buf.setFg(colGutter)
        buf.write(arrow)
        buf.setFg(colBlue)
        buf.write(item.name)
        buf.resetFg()
      elif item.kind == fdkFile:
        buf.write(indent)
        buf.setFg(colGutter)
        buf.write(arrow)
        buf.setFg(colFg)
        buf.write(item.name)
        buf.resetFg()
      else:
        let m = fs.results[item.matchIdx]
        buf.write(indent)
        buf.setFg(colGutter)
        buf.write("  " & $(m.line + 1) & ": ")
        buf.resetFg()
        let prefixLen = buf.curCol
        let maxText = listWidth - prefixLen
        let text = m.lineText.strip()
        if text.len > maxText and maxText > 0:
          buf.write(text[0..<maxText])
        else:
          buf.write(text)

      if isSelected:
        while buf.curCol < listWidth:
          buf.write(" ")
        buf.resetColors()

    while buf.curCol < listWidth:
      buf.write(" ")

    # Separator
    buf.move(1 + row, listWidth)
    buf.resetColors()
    buf.setFg(colGutter)
    buf.write("\xe2\x94\x82")  # │
    buf.resetFg()

    # Right pane: preview
    buf.move(1 + row, listWidth + 1)
    buf.resetColors()

    if fs.previewLines.len > 0 and curMatchIdx >= 0 and row < fs.previewLines.len:
      let fileLine = fs.previewStartLine + row
      let isMatchLine = fileLine == fs.results[curMatchIdx].line

      # Line number
      let lnStr = $(fileLine + 1)
      let lnPad = 5 - lnStr.len
      if isMatchLine:
        buf.setFg(colCyan)
      else:
        buf.setFg(colGutter)
      buf.write(spaces(max(0, lnPad)) & lnStr & " ")
      buf.resetFg()

      if isMatchLine:
        buf.setBg(colCursorLn)

      # Content with search highlight
      let pLine = fs.previewLines[row]
      let maxChars = previewWidth - 7
      let displayLine = if pLine.len > maxChars: pLine[0..<maxChars] else: pLine

      if queryMatch.len > 0:
        let lineSearch = if fs.caseSensitive: displayLine else: displayLine.toLower()
        var searchPos = 0
        while searchPos < lineSearch.len:
          let found = lineSearch.find(queryMatch, searchPos)
          if found < 0:
            buf.write(displayLine[searchPos..^1])
            break
          if found > searchPos:
            buf.write(displayLine[searchPos..<found])
          buf.setBg(colSearchBg)
          buf.write(displayLine[found..<found + queryMatch.len])
          if isMatchLine: buf.setBg(colCursorLn) else: buf.resetBg()
          searchPos = found + queryMatch.len
      else:
        buf.write(displayLine)

      buf.clearToEol()
      buf.resetColors()
    else:
      buf.clearToEol()

  # Separator line
  buf.move(1 + contentRows, 0)
  buf.resetColors()
  buf.setFg(colGutter)
  for c in 0..<totalWidth:
    buf.write("\xe2\x94\x80")  # ─
  buf.resetFg()

  # Help line
  buf.move(2 + contentRows, 0)
  buf.resetColors()
  buf.setFg(colGutter)
  buf.write(helpLine)
  buf.clearToEol()
  buf.resetFg()

proc render*(state: var EditorState) =
  let size = getTerminalSize()
  let totalWidth = size.width
  let height = size.height

  # Find mode: full-screen takeover
  if state.mode == mFind:
    hideCursor()
    findBuf.resize(totalWidth, height)
    renderFind(findBuf, state.findState, totalWidth, height)
    findBuf.blit(1, 1)
    hideCursor()
    flushOut()
    return

  let sidebarVisible = state.sidebar.visible
  let colOffset = if sidebarVisible: state.sidebar.width + 1 else: 0
  let editorWidth = totalWidth - colOffset

  let gitPanelVisible = state.gitPanel.visible
  let panelHeight = if gitPanelVisible: state.gitPanel.height else: 0
  let editorRows = height - 2 - (if gitPanelVisible: panelHeight + 1 else: 0)
  let inCommit = state.gitPanel.inCommitInput

  var renderBuffer = if inCommit: state.gitPanel.savedBuffer else: state.buffer
  let vpTopLine = state.viewport.topLine
  let renderTopLine = if inCommit: state.gitPanel.savedTopLine
  else: vpTopLine
  let renderLeftCol = if inCommit: 0 else: state.viewport.leftCol

  let lnWidth = lineNumberWidth(renderBuffer.lineCount)
  let textWidth = editorWidth - lnWidth

  hideCursor()

  # Resize and clear buffers
  editorBuf.resize(editorWidth, editorRows)
  statusBuf.resize(totalWidth, 2)

  # Render editor
  renderEditor(editorBuf, state, renderBuffer, renderTopLine, renderLeftCol,
               lnWidth, textWidth, editorRows, inCommit)
  editorBuf.blit(1, colOffset + 1)

  # Render sidebar
  if sidebarVisible and not inCommit:
    sidebarBuf.resize(state.sidebar.width + 1, editorRows)  # +1 for separator
    renderSidebar(sidebarBuf, state.sidebar, editorRows)
    sidebarBuf.blit(1, 1)

  # Render git panel
  if gitPanelVisible:
    gitBuf.resize(totalWidth, panelHeight + 1)  # +1 for separator
    renderGitPanel(gitBuf, state, panelHeight + 1)
    gitBuf.blit(editorRows + 1, 1)

  # Render status line + command line
  renderStatusLine(statusBuf, state, totalWidth)
  statusBuf.blit(height - 1, 1)

  # Modal overlays (drawn directly to stdout, on top of buffers)
  if state.mode == mLspManager:
    setThemeColors()
    renderLspManagerModal(totalWidth, height)
    hideCursor()
    flushOut()
    return

  # Completion popup overlay
  if completionState.active and completionState.items.len > 0 and state.mode == mInsert:
    let maxItems = min(10, completionState.items.len)
    let maxWidth = 40
    let screenRow = state.cursor.line - vpTopLine + 2
    let screenCol = completionState.triggerCol - state.viewport.leftCol + lnWidth + colOffset + 1

    for i in 0..<maxItems:
      let popupRow = screenRow + i
      if popupRow >= height - 1:
        break
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
    let commitLnWidth = lineNumberWidth(state.buffer.lineCount)
    let panelStartRow = editorRows + 1
    let screenRow = panelStartRow + 1 + (state.cursor.line - vpTopLine)
    let screenCol = state.cursor.col - state.viewport.leftCol + commitLnWidth + 1
    moveCursor(screenRow, screenCol)
    if state.mode == mInsert: setCursorBlinkingBar() else: setCursorBlock()
    showCursor()
  elif state.mode == mCommand:
    moveCursor(height, 1 + state.commandLine.len + 1)
    setCursorBlinkingBar()
    showCursor()
  else:
    let screenRow = state.cursor.line - vpTopLine + 1
    let screenCol = state.cursor.col - state.viewport.leftCol + lnWidth + colOffset + 1
    moveCursor(screenRow, screenCol)
    if state.mode == mInsert: setCursorBlinkingBar() else: setCursorBlock()
    showCursor()

  flushOut()
