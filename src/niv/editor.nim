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
import lsp_manager
import lsp_client
import lsp_types
import lsp_protocol
import highlight
import fileio
import jumplist

proc newEditorState*(filePath: string = ""): EditorState =
  result.buffer = newBuffer(filePath)
  result.cursor = Position(line: 0, col: 0)
  result.mode = mNormal
  result.running = true
  result.sidebar = initSidebar()
  initLspManager()
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
        try:
          let resultNode = parseJson(event.responseJson)
          if resultNode.hasKey("data"):
            var data: seq[int]
            for v in resultNode["data"]:
              data.add(v.getInt())
            if semanticLines.len < state.buffer.lineCount:
              semanticLines.setLen(state.buffer.lineCount)
            # Replace tokens: clear each line before adding fresh tokens
            var currentLine = 0
            var currentCol = 0
            var lastClearedLine = -1
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
                # Clear line on first encounter — replace stale tokens
                if currentLine != lastClearedLine:
                  semanticLines[currentLine] = @[]
                  lastClearedLine = currentLine
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
        let oldLen = state.buffer.lines.len
        state.buffer.lines.setLen(oldLen + chunk.lines.len)
        for i in 0..<chunk.lines.len:
          state.buffer.lines[oldLen + i] = chunk.lines[i]
      state.buffer.loadedBytes += chunk.bytesRead
      # Progressive LSP sync to viewport
      if lspState == lsRunning and lspSyncedLines > 0:
        let viewEnd = state.viewport.topLine + state.viewport.height
        if state.buffer.lineCount > lspSyncedLines and lspSyncedLines < viewEnd:
          syncLspToLine(state, min(state.buffer.lineCount, viewEnd + 100))
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
      if state.sidebar.visible:
        adjustSidebarScroll(state.sidebar, state.viewport.height)
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
    if lspProgress:
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

    # Pause/resume file loader on insert mode transitions
    if state.mode != prevMode:
      if state.mode == mInsert and not state.buffer.fullyLoaded:
        pauseFileLoader()
      elif prevMode == mInsert and not state.buffer.fullyLoaded:
        resumeFileLoader()
      prevMode = state.mode
