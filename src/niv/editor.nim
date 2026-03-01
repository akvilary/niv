## Editor: main loop and state management

import std/[strutils, json, osproc]
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
import mode_lsp_manager
import mode_git
import lsp_manager
import lsp_client
import lsp_types
import lsp_protocol
import highlight
import fileio
import jumplist

proc updateGitInfo(state: var EditorState) =
  try:
    let (branchOut, branchCode) = execCmdEx("git rev-parse --abbrev-ref HEAD", options = {poUsePath})
    if branchCode == 0:
      state.gitBranch = branchOut.strip()
      let (diffOut, diffCode) = execCmdEx("git diff --numstat", options = {poUsePath})
      if diffCode == 0:
        var added, deleted = 0
        for line in diffOut.splitLines():
          if line.len == 0: continue
          let parts = line.split('\t')
          if parts.len >= 2:
            try:
              added += parseInt(parts[0])
              deleted += parseInt(parts[1])
            except ValueError:
              discard
        state.gitDiffStat = "+" & $added & " -" & $deleted
    else:
      state.gitBranch = ""
      state.gitDiffStat = ""
  except OSError:
    state.gitBranch = ""
    state.gitDiffStat = ""

proc newEditorState*(filePath: string = ""): EditorState =
  result.buffer = newBuffer(filePath)
  result.cursor = Position(line: 0, col: 0)
  result.mode = mNormal
  result.running = true
  result.sidebar = initSidebar()
  initLspManager()
  updateGitInfo(result)
  if filePath.len > 0:
    tryAutoStartLsp(filePath)

proc syncLspToLine(state: EditorState, targetLine: int) =
  ## Lazy sync: ensure LSP has text at least up to targetLine
  if targetLine <= lspSyncedLines or lspState != lsRunning:
    return
  let syncTo = min(targetLine, state.buffer.lineCount)
  if syncTo <= lspSyncedLines:
    return
  let text = state.buffer.lines[0..<syncTo].join("\n")
  sendDidChange(text)
  lspSyncedLines = syncTo

proc requestViewportRangeTokens(state: EditorState) =
  ## Request range tokens for the current viewport + 1 screen prefetch
  if not lspHasSemanticTokensRange or lspState != lsRunning or tokenLegend.len == 0:
    return
  let h = state.viewport.height
  let startLine = max(0, state.viewport.topLine - h)
  let endLine = min(state.viewport.topLine + h + h,
                    state.buffer.lineCount) - 1
  if startLine == lastRangeTopLine and endLine == lastRangeEndLine:
    return  # Already requested this exact range
  lastRangeTopLine = startLine
  lastRangeEndLine = endLine
  sendSemanticTokensRange(startLine, max(0, endLine))

proc handleLspEvents(state: var EditorState): bool =
  ## Poll and process all pending LSP events (non-blocking)
  ## Returns true if any events were processed
  result = false
  while true:
    let (hasEvent, event) = pollLspEvent()
    if not hasEvent:
      break
    result = true
    case event.kind
    of lekResponse:
      let meth = popPendingRequest(event.requestId)
      case meth
      of "initialize":
        lspState = lsRunning
        # Parse token legend from server capabilities
        try:
          let caps = parseJson(event.responseJson)
          if caps.hasKey("capabilities"):
            let serverCaps = caps["capabilities"]
            if serverCaps.hasKey("semanticTokensProvider"):
              lspHasSemanticTokens = true
              let stp = serverCaps["semanticTokensProvider"]
              # Check if server supports range requests
              lspHasSemanticTokensRange = stp.hasKey("range") and
                stp["range"].kind == JBool and stp["range"].getBool()
              if stp.hasKey("legend") and stp["legend"].hasKey("tokenTypes"):
                var legend: seq[string]
                for t in stp["legend"]["tokenTypes"]:
                  legend.add(t.getStr())
                parseLegend(legend)
        except JsonParsingError:
          discard
        sendToLsp(buildInitialized())
        # Send didOpen for current file
        if state.buffer.filePath.len > 0:
          let text = state.buffer.lines.join("\n")
          sendDidOpen(state.buffer.filePath, text)
          lspSyncedLines = state.buffer.lineCount
          # Request range tokens for viewport
          if lspHasSemanticTokensRange and tokenLegend.len > 0:
            requestViewportRangeTokens(state)
            startBgHighlight(state.buffer.lineCount)
        else:
          discard
      of "shutdown":
        lspSendExit()
      of "textDocument/definition":
        try:
          let resultNode = parseJson(event.responseJson)
          # Can be Location, Location[], or null
          var locations: seq[JsonNode]
          if resultNode.kind == JArray:
            for loc in resultNode:
              locations.add(loc)
          elif resultNode.kind == JObject:
            locations.add(resultNode)

          if locations.len > 0:
            # Save current position for gb (go back)
            pushJump(state.buffer.filePath, state.cursor, state.viewport.topLine)
            # Prefer .py over .pyi stub files
            var loc = locations[0]
            for candidate in locations:
              let cUri = candidate["uri"].getStr()
              if not cUri.endsWith(".pyi"):
                loc = candidate
                break
            let uri = loc["uri"].getStr()
            let line = loc["range"]["start"]["line"].getInt()
            let col = loc["range"]["start"]["character"].getInt()
            let filePath = uriToFilePath(uri)

            # Open file if different
            if filePath != state.buffer.filePath:
              stopFileLoader()
              resetViewportRangeCache()
              state.buffer = newBuffer(filePath)
              switchLsp(filePath)
              # If same-language LSP is still running, send didOpen immediately
              if lspState == lsRunning:
                let text = state.buffer.lines.join("\n")
                sendDidOpen(filePath, text)
                lspSyncedLines = state.buffer.lineCount
                if lspHasSemanticTokensRange and tokenLegend.len > 0:
                  requestViewportRangeTokens(state)
                  startBgHighlight(state.buffer.lineCount)

            state.cursor = Position(line: line, col: col)
            state.viewport.topLine = 0
            state.viewport.leftCol = 0
            state.statusMessage = ""
          else:
            state.statusMessage = "Definition not found"
        except JsonParsingError:
          state.statusMessage = "LSP: invalid definition response"
      of "textDocument/semanticTokens/range":
        # Direct parse: find "data":[ and extract numbers without JSON overhead
        let isBgResponse = event.requestId == bgHighlightRequestId
        let dataKey = "\"data\":["
        let dataIdx = event.responseJson.find(dataKey)
        var maxLine = 0
        if dataIdx >= 0:
          if semanticLines.len < state.buffer.lineCount:
            semanticLines.setLen(state.buffer.lineCount)
          var currentLine = 0
          var currentCol = 0
          var lastClearedLine = -1
          var p = dataIdx + dataKey.len
          let s = event.responseJson
          while p < s.len and s[p] != ']':
            var vals: array[5, int]
            var gotAll = true
            for vi in 0..4:
              while p < s.len and s[p] in {' ', ','}: inc p
              if p >= s.len or s[p] == ']':
                gotAll = false
                break
              var num = 0
              while p < s.len and s[p] in {'0'..'9'}:
                num = num * 10 + (ord(s[p]) - ord('0'))
                inc p
              vals[vi] = num
            if not gotAll: break
            if vals[0] > 0:
              currentLine += vals[0]
              currentCol = vals[1]
            else:
              currentCol += vals[1]
            if currentLine < semanticLines.len:
              # Skip viewport responses for lines already covered by background
              if not isBgResponse and currentLine < bgHighlightReceivedUpTo:
                continue
              if currentLine != lastClearedLine:
                semanticLines[currentLine] = @[]
                lastClearedLine = currentLine
              if currentLine > maxLine:
                maxLine = currentLine
              semanticLines[currentLine].add(SemanticToken(
                col: currentCol,
                length: vals[2],
                tokenType: vals[3],
              ))
        if isBgResponse:
          if maxLine + 1 > bgHighlightReceivedUpTo:
            bgHighlightReceivedUpTo = maxLine + 1
          bgHighlightRequestId = -1
        trySendBgHighlight()
      of "textDocument/completion":
        try:
          let resultNode = parseJson(event.responseJson)
          let items = if resultNode.kind == JArray: resultNode
                      elif resultNode.hasKey("items"): resultNode["items"]
                      else: newJArray()
          var compItems: seq[CompletionItem]
          for item in items:
            compItems.add(CompletionItem(
              label: item["label"].getStr(),
              kind: if item.hasKey("kind"): item["kind"].getInt() else: 1,
              detail: if item.hasKey("detail"): item["detail"].getStr() else: "",
              insertText: if item.hasKey("insertText"): item["insertText"].getStr()
                          else: item["label"].getStr(),
            ))
          if compItems.len > 0:
            completionState.active = true
            completionState.items = compItems
            completionState.selectedIndex = 0
          else:
            state.statusMessage = "No completions"
        except JsonParsingError:
          discard
      else:
        discard
    of lekDiagnostics:
      if state.buffer.fullyLoaded and event.diagUri == lspDocumentUri:
        currentDiagnostics = event.diagnostics
    of lekError:
      state.statusMessage = "LSP: " & event.errorMessage
    of lekServerExited:
      lspState = lsOff
      currentDiagnostics = @[]
      clearSemanticTokens()
      resetBgHighlight()
      lspSyncedLines = 0

var pendingFullLspSync = false
const LspSyncChunkSize = 50_000  ## lines per tick (~3ms)
var lspSyncBuf: string
var lspSyncIdx: int

const MaxLinesPerPoll = 200_000  ## max lines to process per tick

proc handleFileLoaderEvents(state: var EditorState): bool =
  ## Poll and process file loader chunks. Returns true if lines were added.
  result = false
  if state.buffer.fullyLoaded:
    return

  var linesProcessed = 0
  while linesProcessed < MaxLinesPerPoll:
    var pollResult = pollFileLoader()
    if not pollResult[0]:
      break
    var chunk = move pollResult[1]
    result = true
    case chunk.kind
    of fckLines:
      let linesPtr = chunk.lines
      if linesPtr != nil and linesPtr[].len > 0:
        let oldLen = state.buffer.lines.len
        state.buffer.lines.setLen(oldLen + linesPtr[].len)
        for i in 0..<linesPtr[].len:
          state.buffer.lines[oldLen + i] = move linesPtr[][i]
        linesProcessed += linesPtr[].len
      state.buffer.loadedBytes += chunk.bytesRead
      freeFileChunkLines(chunk)
    of fckDone:
      state.buffer.fullyLoaded = true
      # Remove trailing empty line if file ends with newline
      if state.buffer.lines.len > 1 and state.buffer.lines[^1].len == 0:
        state.buffer.lines.setLen(state.buffer.lines.len - 1)
      # Defer expensive full LSP sync to idle time
      if lspState == lsRunning and state.buffer.filePath.len > 0 and
         state.buffer.lineCount > lspSyncedLines:
        pendingFullLspSync = true
      if lspHasSemanticTokensRange and lspState == lsRunning and tokenLegend.len > 0:
        if bgHighlightNextLine >= 0:
          bgHighlightTotalLines = state.buffer.lineCount
        elif bgHighlightTotalLines < state.buffer.lineCount:
          startBgHighlight(state.buffer.lineCount, bgHighlightTotalLines)

proc run*(state: var EditorState) =
  enableRawMode()
  defer:
    stopLsp()
    disableRawMode()

  var needsRedraw = true
  var prevMode = state.mode
  var prevTopLine = -1

  while state.running:
    # Update viewport dimensions
    let size = getTerminalSize()
    state.viewport.height = size.height - 2  # status + command lines
    state.viewport.width = size.width

    # Reduce editor height when git panel is visible
    if state.gitPanel.visible:
      state.gitPanel.height = max(5, (size.height - 2) div 2)
      if state.gitPanel.inCommitInput:
        # In commit mode, viewport maps to the panel area
        state.viewport.height = state.gitPanel.height - 1  # -1 for help line
      else:
        state.viewport.height = size.height - 2 - state.gitPanel.height - 1  # -1 for separator

    # Reduce editor width when sidebar is visible
    if state.sidebar.visible and not state.gitPanel.inCommitInput:
      state.viewport.width = size.width - state.sidebar.width - 1

    # Adjust viewport to keep cursor visible
    adjustViewport(state.viewport, state.cursor, state.buffer.lineCount)

    # Request range tokens when viewport scrolls
    if lspHasSemanticTokensRange and lspState == lsRunning and
       tokenLegend.len > 0 and state.viewport.topLine != prevTopLine:
      let viewportEnd = min(state.viewport.topLine + state.viewport.height,
                            state.buffer.lineCount)
      # Skip if background already highlighted this area
      let bgDone = bgHighlightNextLine < 0 and bgHighlightTotalLines > 0
      if not bgDone or viewportEnd > bgHighlightTotalLines:
        syncLspToLine(state, viewportEnd)
        requestViewportRangeTokens(state)
      prevTopLine = state.viewport.topLine

    # Render only when something changed
    if needsRedraw:
      if state.sidebar.visible:
        adjustSidebarScroll(state.sidebar, state.viewport.height)
      render(state)
      needsRedraw = false

    # Read input first — cursor movement is never blocked by loading
    let key = readKey()
    if key.kind != kkNone:
      needsRedraw = true

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
      of mLspManager:
        handleLspManagerMode(state, key)
      of mGit:
        handleGitMode(state, key)

      # Pause/resume file loader on insert mode transitions
      if state.mode != prevMode:
        if state.mode == mInsert and not state.buffer.fullyLoaded:
          pauseFileLoader()
        elif prevMode == mInsert and not state.buffer.fullyLoaded:
          resumeFileLoader()
        prevMode = state.mode

      # Recalculate viewport dimensions (git panel may have toggled)
      let sz = getTerminalSize()
      state.viewport.height = sz.height - 2
      state.viewport.width = sz.width
      if state.gitPanel.visible:
        state.gitPanel.height = max(5, (sz.height - 2) div 2)
        if state.gitPanel.inCommitInput:
          state.viewport.height = state.gitPanel.height - 1
        else:
          state.viewport.height = sz.height - 2 - state.gitPanel.height - 1
      if state.sidebar.visible and not state.gitPanel.inCommitInput:
        state.viewport.width = sz.width - state.sidebar.width - 1

      # Render input result immediately — cursor visible before file events
      adjustViewport(state.viewport, state.cursor, state.buffer.lineCount)
      if state.sidebar.visible:
        adjustSidebarScroll(state.sidebar, state.viewport.height)
      render(state)
      needsRedraw = false

    # Poll file loader events (non-blocking, after input render)
    let hadFileEvents = handleFileLoaderEvents(state)
    if hadFileEvents:
      needsRedraw = true

    # Incremental LSP sync — join ~50K lines per tick to avoid blocking cursor
    if pendingFullLspSync:
      let endIdx = min(lspSyncIdx + LspSyncChunkSize, state.buffer.lineCount)
      for i in lspSyncIdx..<endIdx:
        if lspSyncBuf.len > 0:
          lspSyncBuf.add('\n')
        lspSyncBuf.add(state.buffer.lines[i])
      lspSyncIdx = endIdx
      if lspSyncIdx >= state.buffer.lineCount:
        sendDidChange(lspSyncBuf)
        lspSyncedLines = state.buffer.lineCount
        lspSyncBuf = ""
        lspSyncIdx = 0
        pendingFullLspSync = false
        needsRedraw = true

    # Poll LSP events (non-blocking)
    let hadLspEvents = handleLspEvents(state)
    if hadLspEvents:
      needsRedraw = true

    # Continue background progressive highlighting
    trySendBgHighlight()

    # Poll install/uninstall progress
    let lspProgress = pollInstallProgress()
    if lspProgress:
      needsRedraw = true
