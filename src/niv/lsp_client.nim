## LSP client: process management, worker thread, Channel communication
##
## Architecture:
##   Main thread  -> writes JSON-RPC to LSP stdin via sendToLsp()
##   Worker thread -> reads LSP stdout (POSIX read), sends LspEvents via Channel
##   Communication: system Channel[LspEvent] (thread-safe, lock-free tryRecv)

import std/[json, osproc, streams, strutils, os, posix, uri]
import lsp_types
import lsp_protocol
import lsp_manager
import highlight

# ---------------------------------------------------------------------------
# Global state (main thread owns client, worker thread only reads outputFd)
# ---------------------------------------------------------------------------

var lspChannel*: Channel[LspEvent]
var lspThread: Thread[cint]
var lspProcess: Process
var lspState*: LspState = lsOff
var lspNextId: int = 1
var lspPendingRequests*: seq[tuple[id: int, meth: string]]
var lspDocumentVersion*: int = 0
var lspDocumentUri*: string = ""
var lspServerCommand*: string = ""
var currentDiagnostics*: seq[Diagnostic]
var completionState*: CompletionState
var lspHasSemanticTokens*: bool = false
var lspHasSemanticTokensRange*: bool = false
var lspSyncedLines*: int = 0
var lastRangeTopLine*: int = -1
var lastRangeEndLine*: int = -1

# Background progressive highlighting state
const BgHighlightChunkSize* = 5000
var bgHighlightNextLine*: int = -1
var bgHighlightTotalLines*: int = 0
var bgHighlightRequestId*: int = -1

# ---------------------------------------------------------------------------
# POSIX I/O helpers for worker thread (no GC-managed Stream objects)
# ---------------------------------------------------------------------------

proc readLineFromFd(fd: cint, eof: var bool): string =
  ## Read until CRLF or LF. Sets eof=true on read error / EOF.
  result = ""
  eof = false
  var ch: char
  while true:
    let n = posix.read(fd, addr ch, 1)
    if n <= 0:
      eof = true
      return
    if ch == '\r':
      # Consume following LF
      discard posix.read(fd, addr ch, 1)
      return
    if ch == '\n':
      return
    result.add(ch)

proc readExactFromFd(fd: cint, length: int, eof: var bool): string =
  ## Read exactly `length` bytes. Sets eof=true if read fails before done.
  result = newString(length)
  eof = false
  var offset = 0
  while offset < length:
    let n = posix.read(fd, addr result[offset], length - offset)
    if n <= 0:
      eof = true
      result.setLen(offset)
      return
    offset += n

# ---------------------------------------------------------------------------
# Worker thread — blocks on LSP stdout, pushes events into Channel
# ---------------------------------------------------------------------------

proc lspWorker(outputFd: cint) {.thread.} =
  var eof = false

  while not eof:
    # --- Read headers (Content-Length framing) ---
    var contentLength = -1
    while true:
      let line = readLineFromFd(outputFd, eof)
      if eof:
        lspChannel.send(LspEvent(kind: lekServerExited, exitCode: -1))
        return
      if line.len == 0:
        break  # Empty line = end of headers
      if line.startsWith("Content-Length:"):
        try:
          contentLength = parseInt(line.split(':')[1].strip())
        except ValueError:
          discard

    if contentLength <= 0:
      continue

    # --- Read body ---
    let body = readExactFromFd(outputFd, contentLength, eof)
    if eof:
      lspChannel.send(LspEvent(kind: lekServerExited, exitCode: -1))
      return

    # --- Parse JSON ---
    var msg: JsonNode
    try:
      msg = parseJson(body)
    except JsonParsingError:
      continue

    # --- Dispatch ---
    if msg.hasKey("method") and not msg.hasKey("id"):
      # Server notification
      let meth = msg["method"].getStr()
      case meth
      of "textDocument/publishDiagnostics":
        let params = msg["params"]
        let uri = params["uri"].getStr()
        var diags: seq[Diagnostic]
        if params.hasKey("diagnostics"):
          for d in params["diagnostics"]:
            let r = d["range"]
            let sev = if d.hasKey("severity"): d["severity"].getInt() else: 1
            diags.add(Diagnostic(
              range: LspRange(
                startLine: r["start"]["line"].getInt(),
                startCol: r["start"]["character"].getInt(),
                endLine: r["end"]["line"].getInt(),
                endCol: r["end"]["character"].getInt(),
              ),
              severity: DiagnosticSeverity(sev),
              message: d["message"].getStr(),
              source: if d.hasKey("source"): d["source"].getStr() else: "",
            ))
        lspChannel.send(LspEvent(kind: lekDiagnostics, diagnostics: diags, diagUri: uri))
      else:
        discard  # Ignore unknown notifications

    elif msg.hasKey("id"):
      # Response to our request
      let id = msg["id"].getInt()
      if msg.hasKey("error"):
        let errMsg = msg["error"]["message"].getStr()
        lspChannel.send(LspEvent(kind: lekError, errorMessage: errMsg))
      elif msg.hasKey("result"):
        lspChannel.send(LspEvent(
          kind: lekResponse,
          requestId: id,
          responseJson: $msg["result"],
        ))

  lspChannel.send(LspEvent(kind: lekServerExited, exitCode: 0))

# ---------------------------------------------------------------------------
# Public API (called from main thread only)
# ---------------------------------------------------------------------------

proc filePathToUri*(path: string): string =
  ## Convert a local file path to a file:// URI
  "file://" & absolutePath(path)

proc uriToFilePath*(uri: string): string =
  ## Convert a file:// URI to a local path (decodes percent-encoding)
  if uri.startsWith("file://"):
    decodeUrl(uri[7..^1])
  else:
    decodeUrl(uri)

proc nextLspId*(): int =
  result = lspNextId
  inc lspNextId

proc sendToLsp*(msg: JsonNode) =
  ## Send a JSON-RPC message to the LSP server stdin
  if lspState notin {lsStarting, lsRunning}:
    return
  let encoded = encodeMessage(msg)
  lspProcess.inputStream.write(encoded)
  lspProcess.inputStream.flush()

proc addPendingRequest*(id: int, meth: string) =
  lspPendingRequests.add((id, meth))

proc popPendingRequest*(id: int): string =
  ## Find and remove a pending request by id, return its method name
  for i in 0..<lspPendingRequests.len:
    if lspPendingRequests[i].id == id:
      result = lspPendingRequests[i].meth
      lspPendingRequests.delete(i)
      return
  result = ""

proc startLsp*(command: string, args: seq[string], rootPath: string) =
  ## Start an LSP server subprocess and worker thread
  if lspState != lsOff:
    return

  lspChannel.open()
  lspServerCommand = command
  lspNextId = 1
  lspPendingRequests = @[]

  try:
    lspProcess = startProcess(
      command = command,
      workingDir = rootPath,
      args = args,
      options = {poUsePath}
    )
  except OSError:
    lspState = lsOff
    return

  lspState = lsStarting

  # Launch worker thread with the stdout file descriptor
  let outputFd = cint(lspProcess.outputHandle)
  createThread(lspThread, lspWorker, outputFd)

  # Send initialize request
  let id = nextLspId()
  let rootUri = filePathToUri(rootPath)
  sendToLsp(buildInitialize(id, getCurrentProcessId(), rootUri))
  addPendingRequest(id, "initialize")

proc stopLsp*() =
  ## Gracefully shut down the LSP server
  if lspState == lsOff:
    return

  if lspState == lsRunning:
    lspState = lsStopping
    let id = nextLspId()
    sendToLsp(buildShutdown(id))
    addPendingRequest(id, "shutdown")
  elif lspState in {lsStarting, lsStopping}:
    # Force kill
    lspProcess.kill()
    lspState = lsOff

proc lspSendExit*() =
  ## Send the exit notification (called after shutdown response)
  sendToLsp(buildExit())
  lspState = lsOff

proc lspIsActive*(): bool =
  lspState in {lsStarting, lsRunning}

proc pollLspEvent*(): (bool, LspEvent) =
  ## Non-blocking check for an LSP event from the worker thread
  if lspState == lsOff:
    return (false, LspEvent())
  lspChannel.tryRecv()

proc findLspServer*(command: string): string =
  ## Find an LSP server binary: bundled dir, managed dir, then PATH
  let bundled = findBundledServer(command)
  if bundled.len > 0:
    return bundled
  let managed = serverBinPath(command)
  if fileExists(managed):
    return managed
  return ""

var activeLspLanguageId*: string = ""

proc tryAutoStartLsp*(filePath: string) =
  ## Auto-start the appropriate LSP server based on file extension
  if lspState != lsOff:
    return
  let server = findServerForFile(filePath)
  if server == nil:
    return
  let bin = findLspServer(server.command)
  if bin.len == 0:
    return
  activeLspLanguageId = server.languageId
  startLsp(bin, server.args, getCurrentDir())

proc sendDidOpen*(filePath: string, text: string) =
  if lspState != lsRunning:
    return
  lspDocumentVersion = 1
  lspDocumentUri = filePathToUri(filePath)
  let languageId = if activeLspLanguageId.len > 0: activeLspLanguageId else: "text"
  sendToLsp(buildDidOpen(lspDocumentUri, languageId, lspDocumentVersion, text))

proc sendDidChange*(text: string) =
  if lspState != lsRunning:
    return
  inc lspDocumentVersion
  sendToLsp(buildDidChange(lspDocumentUri, lspDocumentVersion, text))

proc sendSemanticTokensRange*(startLine, endLine: int) =
  ## Request semantic tokens for a specific line range
  if not lspHasSemanticTokensRange or lspState != lsRunning or tokenLegend.len == 0:
    return
  let stId = nextLspId()
  sendToLsp(buildSemanticTokensRange(stId, lspDocumentUri,
    startLine, 0, endLine, 0))
  addPendingRequest(stId, "textDocument/semanticTokens/range")

proc resetViewportRangeCache*() =
  lastRangeTopLine = -1
  lastRangeEndLine = -1

proc startBgHighlight*(lineCount: int, fromLine: int = 0) =
  ## Start background progressive highlighting from fromLine to lineCount
  bgHighlightNextLine = fromLine
  bgHighlightTotalLines = lineCount

proc resetBgHighlight*() =
  bgHighlightNextLine = -1
  bgHighlightTotalLines = 0
  bgHighlightRequestId = -1

proc trySendBgHighlight*() =
  ## Send the next background highlight chunk if conditions are met
  if bgHighlightRequestId >= 0:
    return  # Background request still in flight
  if bgHighlightNextLine < 0 or bgHighlightNextLine >= bgHighlightTotalLines:
    bgHighlightNextLine = -1
    return
  if not lspHasSemanticTokensRange or lspState != lsRunning or tokenLegend.len == 0:
    return
  let endLine = min(bgHighlightNextLine + BgHighlightChunkSize - 1, bgHighlightTotalLines - 1)
  let stId = nextLspId()
  sendToLsp(buildSemanticTokensRange(stId, lspDocumentUri,
    bgHighlightNextLine, 0, endLine, 0))
  addPendingRequest(stId, "textDocument/semanticTokens/range")
  bgHighlightRequestId = stId
  bgHighlightNextLine = endLine + 1
  if bgHighlightNextLine >= bgHighlightTotalLines:
    bgHighlightNextLine = -1

proc sendDidClose*() =
  if lspState != lsRunning:
    return
  if lspDocumentUri.len > 0:
    sendToLsp(buildDidClose(lspDocumentUri))
  lspSyncedLines = 0

proc forceStopLsp*() =
  ## Synchronously kill the LSP server and clean up all state.
  ## Used when switching LSP servers (not for graceful editor exit).
  if lspState == lsOff:
    return
  # Best-effort graceful shutdown
  if lspState == lsRunning:
    try:
      let id = nextLspId()
      sendToLsp(buildShutdown(id))
      sendToLsp(buildExit())
    except CatchableError:
      discard
  # Kill the process
  try:
    lspProcess.kill()
    discard lspProcess.waitForExit(timeout = 500)
    lspProcess.close()
  except CatchableError:
    discard
  # Drain channel
  while true:
    let (hasEvent, _) = lspChannel.tryRecv()
    if not hasEvent: break
  # Reset ALL state
  lspState = lsOff
  lspNextId = 1
  lspPendingRequests = @[]
  lspDocumentUri = ""
  lspDocumentVersion = 0
  lspServerCommand = ""
  lspSyncedLines = 0
  activeLspLanguageId = ""
  currentDiagnostics = @[]
  completionState = CompletionState()
  lspHasSemanticTokens = false
  lspHasSemanticTokensRange = false
  clearSemanticTokens()
  clearTokenLegend()
  resetBgHighlight()
  resetViewportRangeCache()

proc switchLsp*(filePath: string) =
  ## Switch LSP server for a new file. Handles same-language and cross-language cases.
  ## Same language: didClose old, didOpen new (keep tokenLegend).
  ## Different language: forceStop old, start new (clear everything).
  ## No server available: stop old, clear state.
  let newServer = findServerForFile(filePath)
  let newLangId = if newServer != nil: newServer.languageId else: ""
  let sameLang = newLangId.len > 0 and newLangId == activeLspLanguageId

  if sameLang and lspState == lsRunning:
    # Same LSP server — just switch documents
    sendDidClose()
    clearSemanticTokens()
    resetBgHighlight()
    currentDiagnostics = @[]
    completionState = CompletionState()
    lspSyncedLines = 0
    return

  if sameLang and lspState == lsStarting:
    # LSP still starting for same language — wait for initialize
    clearSemanticTokens()
    resetBgHighlight()
    currentDiagnostics = @[]
    lspSyncedLines = 0
    return

  # Different language or LSP not running — full switch
  if lspState != lsOff:
    forceStopLsp()

  if newServer != nil:
    let bin = findLspServer(newServer.command)
    if bin.len > 0:
      activeLspLanguageId = newServer.languageId
      startLsp(bin, newServer.args, getCurrentDir())
      return

  # No server available for this file type
  activeLspLanguageId = ""
