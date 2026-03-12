## Find mode: search for text across files in the project

import std/[unicode, osproc, strutils, os]
import types
import buffer
import lsp_client
import lsp_types
import highlight
import fileio

# ---------------------------------------------------------------------------
# Tree structure for grouping results by directory hierarchy
# ---------------------------------------------------------------------------

type
  FindFileNode = ref object
    name: string
    path: string
    indices: seq[int]
    expanded: bool

  FindDirNode = ref object
    name: string
    subdirs: seq[FindDirNode]
    files: seq[FindFileNode]
    expanded: bool
    matchCount: int              # cached total matches in subtree

var findTreeRoots: seq[FindDirNode]

proc buildFindTree(results: openArray[FindMatch]) =
  var root = FindDirNode(name: "", expanded: true)
  var lastFilePath: string
  var lastFileNode: FindFileNode
  var lastDir: string
  var lastDirNode: FindDirNode

  for i in 0..<results.len:
    # Fast path: same file as previous (grep groups by file)
    if results[i].filePath == lastFilePath:
      lastFileNode.indices.add(i)
      continue

    # Split into dir + filename without allocating seq
    let filePath = results[i].filePath
    let slashPos = filePath.rfind('/')
    var dir, fileName: string
    if slashPos >= 0:
      dir = filePath[0..<slashPos]
      fileName = filePath[slashPos + 1..^1]
    else:
      dir = "."
      fileName = filePath

    # Walk to dir node (cached for consecutive same-dir results)
    var dirNode: FindDirNode
    if dir == lastDir and lastDirNode != nil:
      dirNode = lastDirNode
    else:
      dirNode = root
      var pos = 0
      while pos < dir.len:
        var nextSlash = pos
        while nextSlash < dir.len and dir[nextSlash] != '/':
          inc nextSlash
        let part = dir[pos..<nextSlash]
        var child: FindDirNode = nil
        for c in dirNode.subdirs:
          if c.name == part:
            child = c
            break
        if child == nil:
          child = FindDirNode(name: part, expanded: true)
          dirNode.subdirs.add(child)
        dirNode = child
        pos = nextSlash + 1
      lastDir = dir
      lastDirNode = dirNode

    let fileNode = FindFileNode(
      name: fileName, path: filePath, indices: @[i], expanded: true,
    )
    dirNode.files.add(fileNode)
    lastFilePath = filePath
    lastFileNode = fileNode

  # Collapse single-child chains in-place + compute matchCount bottom-up
  proc collapseAndCount(node: FindDirNode) =
    while node.subdirs.len == 1 and node.files.len == 0:
      let child = node.subdirs[0]
      node.name &= "/" & child.name
      node.subdirs = child.subdirs
      node.files = child.files
    node.matchCount = 0
    for f in node.files:
      node.matchCount += f.indices.len
    for child in node.subdirs:
      collapseAndCount(child)
      node.matchCount += child.matchCount

  findTreeRoots = @[]
  for child in root.subdirs:
    collapseAndCount(child)
    findTreeRoots.add(child)

proc flattenDir(items: var seq[FindDisplayItem], node: FindDirNode, depth: int) =
  items.add(FindDisplayItem(
    kind: fdkDir, name: node.name,
    expanded: node.expanded, depth: depth, matchCount: node.matchCount,
  ))
  if not node.expanded: return

  for child in node.subdirs:
    flattenDir(items, child, depth + 1)

  for f in node.files:
    items.add(FindDisplayItem(
      kind: fdkFile, filePath: f.path, name: f.name,
      expanded: f.expanded, depth: depth + 1, matchCount: f.indices.len,
    ))
    if f.expanded:
      for idx in f.indices:
        items.add(FindDisplayItem(
          kind: fdkMatch, matchIdx: idx, depth: depth + 2,
        ))

proc flattenFindTree(state: var EditorState) =
  var items = newSeqOfCap[FindDisplayItem](state.findState.results.len * 2)
  for root in findTreeRoots:
    flattenDir(items, root, 0)
  state.findState.displayItems = move(items)

proc buildDisplayItems(state: var EditorState) =
  buildFindTree(state.findState.results)
  flattenFindTree(state)

proc toggleExpand(state: var EditorState) =
  let items = state.findState.displayItems
  if items.len == 0 or state.findState.cursorIndex >= items.len: return
  let item = items[state.findState.cursorIndex]
  if item.kind == fdkMatch: return

  if item.kind == fdkDir:
    proc toggleDir(nodes: seq[FindDirNode], name: string): bool =
      for node in nodes:
        if node.name == name:
          node.expanded = not node.expanded
          return true
        if toggleDir(node.subdirs, name): return true
      return false
    discard toggleDir(findTreeRoots, item.name)

  elif item.kind == fdkFile:
    proc toggleFile(nodes: seq[FindDirNode], path: string): bool =
      for node in nodes:
        for f in node.files:
          if f.path == path:
            f.expanded = not f.expanded
            return true
        if toggleFile(node.subdirs, path): return true
      return false
    discard toggleFile(findTreeRoots, item.filePath)

  flattenFindTree(state)

# ---------------------------------------------------------------------------
# Match helpers
# ---------------------------------------------------------------------------

proc currentMatch(state: EditorState): int =
  let items = state.findState.displayItems
  if items.len == 0 or state.findState.cursorIndex >= items.len: return -1
  let item = items[state.findState.cursorIndex]
  if item.kind == fdkMatch: return item.matchIdx
  return -1

# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

proc runFind(state: var EditorState) =
  let query = $state.findState.query
  if query.len < 2:
    state.findState.results = @[]
    state.findState.displayItems = @[]
    findTreeRoots = @[]
    state.findState.searched = query.len > 0
    return

  state.findState.cursorIndex = 0
  state.findState.scrollOffset = 0
  state.findState.searched = true

  let searchPath = if state.findState.searchDir.len > 0:
    quoteShell(state.findState.searchDir)
  else: "."
  let caseFlag = if state.findState.caseSensitive: "" else: "i"
  let cmd = "grep -rnI" & caseFlag & " --color=never --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=__pycache__ --exclude-dir=.venv -- " & quoteShell(query) & " " & searchPath & " 2>/dev/null"
  let (output, exitCode) = execCmdEx(cmd, options = {poUsePath})
  if exitCode != 0 and output.len == 0:
    state.findState.results = @[]
    state.findState.displayItems = @[]
    findTreeRoots = @[]
    return

  let maxResults = 5000
  let queryLower = if state.findState.caseSensitive: "" else: query.toLower()
  var results = newSeqOfCap[FindMatch](min(maxResults, output.len div 40))
  var pos = 0
  while pos < output.len and results.len < maxResults:
    var eol = pos
    while eol < output.len and output[eol] != '\n':
      inc eol
    if eol == pos:
      pos = eol + 1
      continue

    # Parse: filepath:linenum:content
    var firstColon = -1
    for i in pos..<eol:
      if output[i] == ':':
        firstColon = i
        break
    if firstColon < 0:
      pos = eol + 1
      continue

    var secondColon = -1
    for i in firstColon + 1..<eol:
      if output[i] == ':':
        secondColon = i
        break
    if secondColon < 0:
      pos = eol + 1
      continue

    var fpStart = pos
    if eol - pos > 2 and output[pos] == '.' and output[pos + 1] == '/':
      fpStart = pos + 2
    let filePath = output[fpStart..<firstColon]

    var lineNum = 0
    var valid = true
    for i in firstColon + 1..<secondColon:
      if output[i] in {'0'..'9'}:
        lineNum = lineNum * 10 + (ord(output[i]) - ord('0'))
      else:
        valid = false
        break
    if not valid:
      pos = eol + 1
      continue

    let lineText = output[secondColon + 1..<eol]
    let col = if state.findState.caseSensitive:
      lineText.find(query)
    else:
      lineText.toLower().find(queryLower)

    results.add(FindMatch(
      filePath: filePath,
      line: lineNum - 1,
      col: max(0, col),
      lineText: lineText,
    ))
    pos = eol + 1

  state.findState.results = move(results)
  buildDisplayItems(state)

# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------

proc loadPreview(state: var EditorState) =
  state.findState.previewLines = @[]
  state.findState.previewStartLine = 0
  let mi = currentMatch(state)
  if mi < 0: return

  let match = state.findState.results[mi]
  let fullPath = if match.filePath.isAbsolute: match.filePath
                 else: getCurrentDir() / match.filePath
  if not fileExists(fullPath): return

  try:
    let content = readFile(fullPath)
    let lines = content.splitLines()
    let contextBefore = 5
    let startLine = max(0, match.line - contextBefore)
    state.findState.previewStartLine = startLine
    for i in startLine..<lines.len:
      state.findState.previewLines.add(lines[i])
  except IOError:
    discard

# ---------------------------------------------------------------------------
# Open result
# ---------------------------------------------------------------------------

proc openFindResult(state: var EditorState) =
  let mi = currentMatch(state)
  if mi < 0: return

  let match = state.findState.results[mi]
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

# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------

proc moveCursorDown(state: var EditorState) =
  if state.findState.cursorIndex < state.findState.displayItems.len - 1:
    inc state.findState.cursorIndex
    loadPreview(state)

proc moveCursorUp(state: var EditorState) =
  if state.findState.cursorIndex > 0:
    dec state.findState.cursorIndex
    loadPreview(state)

# ---------------------------------------------------------------------------
# Mode handler
# ---------------------------------------------------------------------------

proc handleFindMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    state.mode = mNormal
    state.statusMessage = ""

  of kkEnter:
    if state.findState.displayItems.len > 0 and
       state.findState.cursorIndex < state.findState.displayItems.len:
      let item = state.findState.displayItems[state.findState.cursorIndex]
      if item.kind in {fdkDir, fdkFile}:
        toggleExpand(state)
      else:
        openFindResult(state)
    elif state.findState.query.len > 0 and state.findState.results.len == 0:
      runFind(state)
      if state.findState.displayItems.len > 0:
        loadPreview(state)

  of kkBackspace:
    if state.findState.query.len > 0:
      state.findState.query.setLen(state.findState.query.len - 1)
      runFind(state)
      if state.findState.displayItems.len > 0:
        loadPreview(state)

  of kkChar:
    state.findState.query.add(key.ch)
    runFind(state)
    if state.findState.displayItems.len > 0:
      loadPreview(state)

  of kkArrowDown:
    moveCursorDown(state)

  of kkArrowUp:
    moveCursorUp(state)

  of kkCtrlKey:
    case key.ctrl
    of Rune(ord('n')):
      moveCursorDown(state)
    of Rune(ord('p')):
      moveCursorUp(state)
    of Rune(ord('f')):
      state.mode = mNormal
      state.statusMessage = ""
    of Rune(ord('s')):
      state.findState.caseSensitive = not state.findState.caseSensitive
      if state.findState.query.len >= 2:
        runFind(state)
        if state.findState.displayItems.len > 0:
          loadPreview(state)
    of Rune(ord('d')):
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
        if state.findState.displayItems.len > 0:
          loadPreview(state)
    else:
      discard

  of kkPageDown:
    if state.findState.displayItems.len > 0:
      state.findState.cursorIndex = min(state.findState.cursorIndex + 20,
                                         state.findState.displayItems.len - 1)
      loadPreview(state)

  of kkPageUp:
    state.findState.cursorIndex = max(0, state.findState.cursorIndex - 20)
    if state.findState.displayItems.len > 0:
      loadPreview(state)

  else:
    discard
