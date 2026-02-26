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

var lspHasSemanticTokens*: bool = false

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

proc handleLspEvents(state: var EditorState) =
  ## Poll and process all pending LSP events (non-blocking)
  while true:
    let (hasEvent, event) = pollLspEvent()
    if not hasEvent:
      break
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
          # Request semantic tokens
          if tokenLegend.len > 0:
            let stId = nextLspId()
            sendToLsp(buildSemanticTokensFull(stId, lspDocumentUri))
            addPendingRequest(stId, "textDocument/semanticTokens/full")
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
              state.buffer = newBuffer(filePath)
              lspDocumentUri = filePathToUri(filePath)
              let text = state.buffer.lines.join("\n")
              sendDidOpen(filePath, text)
              # Request semantic tokens for new file
              if tokenLegend.len > 0:
                let stId = nextLspId()
                sendToLsp(buildSemanticTokensFull(stId, lspDocumentUri))
                addPendingRequest(stId, "textDocument/semanticTokens/full")

            state.cursor = Position(line: line, col: col)
            state.viewport.topLine = 0
            state.viewport.leftCol = 0
            state.statusMessage = ""
          else:
            state.statusMessage = "Definition not found"
        except JsonParsingError:
          state.statusMessage = "LSP: invalid definition response"
      of "textDocument/semanticTokens/full":
        try:
          let resultNode = parseJson(event.responseJson)
          if resultNode.hasKey("data"):
            var data: seq[int]
            for v in resultNode["data"]:
              data.add(v.getInt())
            parseSemanticTokens(data, state.buffer.lineCount)
        except JsonParsingError:
          discard
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
      if event.diagUri == lspDocumentUri:
        currentDiagnostics = event.diagnostics
    of lekError:
      state.statusMessage = "LSP: " & event.errorMessage
    of lekServerExited:
      lspState = lsOff
      currentDiagnostics = @[]
      clearSemanticTokens()

proc run*(state: var EditorState) =
  enableRawMode()
  defer:
    tsCleanup()
    stopLsp()
    disableRawMode()

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

    # Render
    render(state)

    # Poll LSP events (non-blocking)
    handleLspEvents(state)

    # Poll install/uninstall progress
    pollInstallProgress()
    pollTsInstallProgress()

    # Read input (100ms timeout via VTIME=1)
    let key = readKey()
    if key.kind == kkNone:
      continue

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
