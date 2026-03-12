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
    name*: string
    path*: string
    indices*: seq[int]
    expanded*: bool

  FindDirNode = ref object
    name*: string                 # display name (collapsed chain)
    subdirs*: seq[FindDirNode]
    files*: seq[FindFileNode]
    expanded*: bool

var findTreeRoots: seq[FindDirNode]

proc buildFindTree(results: seq[FindMatch]) =
  type TmpNode = ref object
    name: string
    children: seq[TmpNode]
    files: seq[FindFileNode]

  var root = TmpNode(name: "")

  for i in 0..<results.len:
    let m = results[i]
    let (dir, fileName) = splitPath(m.filePath)
    let parts = if dir.len > 0: dir.split('/') else: @["."]

    # Walk/create dir path in tree
    var node = root
    for part in parts:
      var child: TmpNode = nil
      for c in node.children:
        if c.name == part:
          child = c
          break
      if child == nil:
        child = TmpNode(name: part)
        node.children.add(child)
      node = child

    # Add match to file node
    var foundFile = false
    for f in node.files:
      if f.path == m.filePath:
        f.indices.add(i)
        foundFile = true
        break
    if not foundFile:
      node.files.add(FindFileNode(
        name: fileName, path: m.filePath, indices: @[i], expanded: true,
      ))

  # Convert to FindDirNode, collapsing single-child chains
  proc convert(tmp: TmpNode): FindDirNode =
    var cur = tmp
    var displayName = cur.name
    while cur.children.len == 1 and cur.files.len == 0:
      cur = cur.children[0]
      displayName &= "/" & cur.name
    result = FindDirNode(name: displayName, expanded: true)
    for child in cur.children:
      result.subdirs.add(convert(child))
    result.files = cur.files

  findTreeRoots = @[]
  for child in root.children:
    findTreeRoots.add(convert(child))

proc countSubMatches(n: FindDirNode): int =
  for f in n.files: result += f.indices.len
  for s in n.subdirs: result += countSubMatches(s)

proc flattenDir(items: var seq[FindDisplayItem], node: FindDirNode, depth: int) =
  let totalMatches = countSubMatches(node)

  items.add(FindDisplayItem(
    kind: fdkDir, filePath: node.name, name: node.name,
    expanded: node.expanded, depth: depth, matchCount: totalMatches,
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
          kind: fdkMatch, filePath: f.path, matchIdx: idx, depth: depth + 2,
        ))

proc flattenFindTree(state: var EditorState) =
  state.findState.displayItems = @[]
  for root in findTreeRoots:
    flattenDir(state.findState.displayItems, root, 0)

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

  state.findState.results = @[]
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
    state.findState.displayItems = @[]
    findTreeRoots = @[]
    return

  let maxResults = 5000
  var count = 0
  for line in output.splitLines():
    if line.len == 0: continue
    if count >= maxResults: break
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
    let col = if state.findState.caseSensitive:
      lineText.find(query)
    else:
      lineText.toLower().find(query.toLower())

    state.findState.results.add(FindMatch(
      filePath: filePath,
      line: lineNum - 1,
      col: max(0, col),
      lineText: lineText,
    ))
    inc count

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
