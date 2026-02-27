## Editor: main loop and state management

import std/[strutils, json]
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
import mode_ts_manager
import lsp_manager
import ts_manager
import lsp_client
import lsp_types
import lsp_protocol
import highlight
import ts_highlight
import fileio

var lspHasSemanticTokens*: bool = false
var lastRangeTopLine: int = -1
var lastRangeEndLine: int = -1

proc newEditorState*(filePath: string = ""): EditorState =
  result.buffer = newBuffer(filePath)
  result.cursor = Position(line: 0, col: 0)
  result.mode = mNormal
  result.running = true
  result.sidebar = initSidebar()
  initLspManager()
  initTsManager()
  # Auto-start LSP for .nim files
  if filePath.len > 0:
    tryAutoStartLsp(filePath)
  # Tree-sitter auto-highlight (if grammar installed and LSP doesn't have semantic tokens)
  if filePath.len > 0 and not lspHasSemanticTokens:
    let text = result.buffer.lines.join("\n")
    tryTsHighlight(filePath, text, result.buffer.lineCount)

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
  ## Request range tokens for the current viewport if server supports it
  if not lspHasSemanticTokensRange or lspState != lsRunning or tokenLegend.len == 0:
    return
  let endLine = min(state.viewport.topLine + state.viewport.height,
                    state.buffer.lineCount) - 1
  let startLine = state.viewport.topLine
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
                # LSP has semantic tokens — disable tree-sitter
                clearTsHighlight()
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
          if tokenLegend.len > 0:
            state.statusMessage = "LSP ready (semantic tokens: " & $tokenLegend.len & " types)"
          else:
            state.statusMessage = "LSP ready (no semantic tokens support)"
        else:
          state.statusMessage = "LSP ready"
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
            let loc = locations[0]
            let uri = loc["uri"].getStr()
            let line = loc["range"]["start"]["line"].getInt()
            let col = loc["range"]["start"]["character"].getInt()
            let filePath = uriToFilePath(uri)

            # Open file if different
            if filePath != state.buffer.filePath:
              sendDidClose()
              clearSemanticTokens()
              lastRangeTopLine = -1
              lastRangeEndLine = -1
              state.buffer = newBuffer(filePath)
              lspDocumentUri = filePathToUri(filePath)
              let text = state.buffer.lines.join("\n")
              sendDidOpen(filePath, text)
              lspSyncedLines = state.buffer.lineCount
              # Request range tokens for viewport
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
        try:
          let resultNode = parseJson(event.responseJson)
          if resultNode.hasKey("data"):
            var data: seq[int]
            for v in resultNode["data"]:
              data.add(v.getInt())
            # Merge range tokens into existing semantic lines
            # Grow semanticLines if needed
            if semanticLines.len < state.buffer.lineCount:
              semanticLines.setLen(state.buffer.lineCount)
            # Parse range tokens — they use absolute line positions
            var currentLine = 0
            var currentCol = 0
            var i = 0
            while i + 4 < data.len:
              let deltaLine = data[i]
              let deltaStart = data[i + 1]
              let length = data[i + 2]
              let tokenType = data[i + 3]
              i += 5
              if deltaLine > 0:
                currentLine += deltaLine
                currentCol = deltaStart
              else:
                currentCol += deltaStart
              if currentLine < semanticLines.len:
                # Check if token already exists to avoid duplicates
                var found = false
                for tok in semanticLines[currentLine]:
                  if tok.col == currentCol and tok.length == length:
                    found = true
                    break
                if not found:
                  semanticLines[currentLine].add(SemanticToken(
                    col: currentCol,
                    length: length,
                    tokenType: tokenType,
                  ))
        except JsonParsingError:
          discard
        if event.requestId == bgHighlightRequestId:
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

proc handleFileLoaderEvents(state: var EditorState): bool =
  ## Poll and process file loader chunks. Returns true if lines were added.
  result = false
  if state.buffer.fullyLoaded:
    return

  while true:
    let (hasData, chunk) = pollFileLoader()
    if not hasData:
      break
    result = true
    case chunk.kind
    of fckLines:
      if chunk.lines.len > 0:
        for line in chunk.lines:
          state.buffer.lines.add(line)
      state.buffer.loadedBytes += chunk.bytesRead
    of fckDone:
      state.buffer.fullyLoaded = true
      # Remove trailing empty line if file ends with newline
      if state.buffer.lines.len > 1 and state.buffer.lines[^1].len == 0:
        state.buffer.lines.setLen(state.buffer.lines.len - 1)
      # Sync full text with LSP and extend background highlighting
      if lspState == lsRunning and state.buffer.filePath.len > 0 and
         state.buffer.lineCount > lspSyncedLines:
        let text = state.buffer.lines.join("\n")
        sendDidChange(text)
        lspSyncedLines = state.buffer.lineCount
      if lspHasSemanticTokensRange and lspState == lsRunning and tokenLegend.len > 0:
        if bgHighlightNextLine >= 0:
          # Still running — extend to cover full file
          bgHighlightTotalLines = state.buffer.lineCount
        elif bgHighlightTotalLines < state.buffer.lineCount:
          # Finished initial pass — continue from where we left off
          startBgHighlight(state.buffer.lineCount, bgHighlightTotalLines)

proc run*(state: var EditorState) =
  enableRawMode()
  defer:
    tsCleanup()
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

    # Reduce editor width when sidebar is visible
    if state.sidebar.visible:
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
      render(state)
      needsRedraw = false

    # Poll file loader events (non-blocking)
    let hadFileEvents = handleFileLoaderEvents(state)
    if hadFileEvents:
      needsRedraw = true

    # Poll LSP events (non-blocking)
    let hadLspEvents = handleLspEvents(state)
    if hadLspEvents:
      needsRedraw = true

    # Continue background progressive highlighting
    trySendBgHighlight()

    # Poll install/uninstall progress
    let lspProgress = pollInstallProgress()
    let tsProgress = pollTsInstallProgress()
    if lspProgress or tsProgress:
      needsRedraw = true

    # Read input (100ms timeout via VTIME=1)
    let key = readKey()
    if key.kind == kkNone:
      continue

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
    of mTsManager:
      handleTsManagerMode(state, key)

    # Pause/resume file loader on insert mode transitions
    if state.mode != prevMode:
      if state.mode == mInsert and not state.buffer.fullyLoaded:
        pauseFileLoader()
      elif prevMode == mInsert and not state.buffer.fullyLoaded:
        resumeFileLoader()
      prevMode = state.mode
