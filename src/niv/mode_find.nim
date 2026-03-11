## Find mode: search for text across files in the project

import std/[unicode, osproc, strutils, os]
import types
import buffer
import lsp_client
import lsp_types
import highlight
import fileio

proc runFind(state: var EditorState) =
  ## Run grep to find matches across files
  let query = $state.findState.query
  if query.len < 2:
    state.findState.results = @[]
    state.findState.searched = query.len > 0
    return

  state.findState.results = @[]
  state.findState.cursorIndex = 0
  state.findState.scrollOffset = 0
  state.findState.searched = true

  # Use grep: -r recursive, -n line numbers, -I skip binary, -i case-insensitive
  # --include common text file types to avoid noise
  let searchPath = if state.findState.searchDir.len > 0:
    quoteShell(state.findState.searchDir)
  else: "."
  let caseFlag = if state.findState.caseSensitive: "" else: "i"
  let cmd = "grep -rnI" & caseFlag & " --color=never --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=__pycache__ --exclude-dir=.venv -- " & quoteShell(query) & " " & searchPath & " 2>/dev/null"
  let (output, exitCode) = execCmdEx(cmd, options = {poUsePath})
  if exitCode != 0 and output.len == 0:
    return

  let maxResults = 5000
  var count = 0
  for line in output.splitLines():
    if line.len == 0: continue
    if count >= maxResults: break
    # Format: ./path/to/file:linenum:content
    let firstColon = line.find(':')
    if firstColon < 0: continue
    let secondColon = line.find(':', firstColon + 1)
    if secondColon < 0: continue

    var filePath = line[0..<firstColon]
    if filePath.startsWith("./"):
      filePath = filePath[2..^1]

    var lineNum = 0
    var valid = true
    for i in firstColon + 1..<secondColon:
      if line[i] in {'0'..'9'}:
        lineNum = lineNum * 10 + (ord(line[i]) - ord('0'))
      else:
        valid = false
        break
    if not valid: continue

    let lineText = line[secondColon + 1..^1]

    # Find column
    let col = if state.findState.caseSensitive:
      lineText.find(query)
    else:
      lineText.toLower().find(query.toLower())

    state.findState.results.add(FindMatch(
      filePath: filePath,
      line: lineNum - 1,  # convert to 0-indexed
      col: max(0, col),
      lineText: lineText,
    ))
    inc count

proc loadPreview(state: var EditorState) =
  ## Load preview lines for the currently selected match
  state.findState.previewLines = @[]
  state.findState.previewStartLine = 0
  if state.findState.results.len == 0: return
  if state.findState.cursorIndex >= state.findState.results.len: return

  let match = state.findState.results[state.findState.cursorIndex]
  let fullPath = if match.filePath.isAbsolute: match.filePath
                 else: getCurrentDir() / match.filePath

  if not fileExists(fullPath): return

  try:
    let content = readFile(fullPath)
    let lines = content.splitLines()
    # Show context around the match: 5 lines before, rest fills viewport
    let contextBefore = 5
    let startLine = max(0, match.line - contextBefore)
    state.findState.previewStartLine = startLine
    for i in startLine..<lines.len:
      state.findState.previewLines.add(lines[i])
  except IOError:
    discard

proc openFindResult(state: var EditorState) =
  ## Open the selected find result in the editor
  if state.findState.results.len == 0: return
  if state.findState.cursorIndex >= state.findState.results.len: return

  let match = state.findState.results[state.findState.cursorIndex]
  let fullPath = if match.filePath.isAbsolute: match.filePath
                 else: getCurrentDir() / match.filePath

  if not fileExists(fullPath): return

  stopFileLoader()
  resetViewportRangeCache()

  state.buffer = newBuffer(fullPath)
  state.cursor = Position(line: match.line, col: match.col)
  state.viewport.topLine = max(0, match.line - 5)
  state.viewport.leftCol = 0
  state.mode = mNormal
  state.statusMessage = "\"" & match.filePath & "\""

  switchLsp(fullPath)
  if lspState == lsRunning:
    sendDidOpen(fullPath, state.buffer.data)
    lspSyncedLines = state.buffer.lineCount
    if tokenLegend.len > 0 and lspHasSemanticTokensRange:
      sendSemanticTokensRange(0, min(state.buffer.lineCount - 1, 50))
      startBgHighlight(state.buffer.lineCount)

proc adjustFindScroll(state: var EditorState, viewportHeight: int) =
  ## Keep cursor visible in the results list
  let contentRows = viewportHeight - 3
  if contentRows <= 0: return
  if state.findState.cursorIndex < state.findState.scrollOffset:
    state.findState.scrollOffset = state.findState.cursorIndex
  elif state.findState.cursorIndex >= state.findState.scrollOffset + contentRows:
    state.findState.scrollOffset = state.findState.cursorIndex - contentRows + 1

proc handleFindMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    state.mode = mNormal
    state.statusMessage = ""

  of kkEnter:
    if state.findState.results.len > 0:
      openFindResult(state)
    elif state.findState.query.len > 0:
      runFind(state)
      if state.findState.results.len > 0:
        loadPreview(state)

  of kkBackspace:
    if state.findState.query.len > 0:
      state.findState.query.setLen(state.findState.query.len - 1)
      runFind(state)
      if state.findState.results.len > 0:
        loadPreview(state)

  of kkChar:
    state.findState.query.add(key.ch)
    runFind(state)
    if state.findState.results.len > 0:
      loadPreview(state)

  of kkArrowDown:
    if state.findState.results.len > 0:
      state.findState.cursorIndex = min(state.findState.cursorIndex + 1,
                                         state.findState.results.len - 1)
      loadPreview(state)

  of kkArrowUp:
    if state.findState.cursorIndex > 0:
      dec state.findState.cursorIndex
      loadPreview(state)

  of kkArrowLeft:
    inc state.findState.listHScroll

  of kkArrowRight:
    if state.findState.listHScroll > 0:
      dec state.findState.listHScroll

  of kkCtrlKey:
    case key.ctrl
    of Rune(ord('n')):
      if state.findState.results.len > 0:
        state.findState.cursorIndex = min(state.findState.cursorIndex + 1,
                                           state.findState.results.len - 1)
        loadPreview(state)
    of Rune(ord('p')):
      if state.findState.cursorIndex > 0:
        dec state.findState.cursorIndex
        loadPreview(state)
    of Rune(ord('f')):
      state.mode = mNormal
      state.statusMessage = ""
    of Rune(ord('s')):
      state.findState.caseSensitive = not state.findState.caseSensitive
      if state.findState.query.len >= 2:
        runFind(state)
        if state.findState.results.len > 0:
          loadPreview(state)
    of Rune(ord('d')):
      # Toggle: search in current file's directory / whole project
      if state.findState.searchDir.len > 0:
        state.findState.searchDir = ""
      else:
        let dir = if state.buffer.filePath.len > 0:
          parentDir(state.buffer.filePath)
        else:
          getCurrentDir()
        state.findState.searchDir = relativePath(dir, getCurrentDir())
      if state.findState.query.len >= 2:
        runFind(state)
        if state.findState.results.len > 0:
          loadPreview(state)
    else:
      discard

  of kkPageDown:
    if state.findState.results.len > 0:
      state.findState.cursorIndex = min(state.findState.cursorIndex + 20,
                                         state.findState.results.len - 1)
      loadPreview(state)

  of kkPageUp:
    state.findState.cursorIndex = max(0, state.findState.cursorIndex - 20)
    if state.findState.results.len > 0:
      loadPreview(state)

  else:
    discard
