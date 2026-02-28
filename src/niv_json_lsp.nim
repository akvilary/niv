## niv_json_lsp — minimal JSON Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils, os, posix]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  JsonTokenKind = enum
    jtProperty  # object key
    jtString    # string value
    jtNumber    # number
    jtKeyword   # true, false, null

  JsonToken = object
    kind: JsonTokenKind
    line: int
    col: int
    length: int

  DiagInfo = object
    line: int
    col: int
    endCol: int
    message: string

  DocumentState = object
    uri: string
    text: string
    version: int

# Semantic token type indices (must match legend in initialize response)
const
  stProperty = 0
  stString = 1
  stNumber = 2
  stKeyword = 3

# ---------------------------------------------------------------------------
# JSON Tokenizer + Diagnostics
# ---------------------------------------------------------------------------

type
  ContextKind = enum
    ckObject
    ckArray

proc tokenizeJson(text: string): (seq[JsonToken], seq[DiagInfo]) =
  var tokens: seq[JsonToken]
  var diags: seq[DiagInfo]
  var pos = 0
  var line = 0
  var col = 0
  var contextStack: seq[ContextKind]
  var expectKey = false   # next string should be a property key

  template ch(): char =
    if pos < text.len: text[pos] else: '\0'

  template advance() =
    if pos < text.len:
      if text[pos] == '\n':
        inc line
        col = 0
      else:
        inc col
      inc pos

  template skipWhitespace() =
    while pos < text.len and text[pos] in {' ', '\t', '\r', '\n'}:
      advance()

  proc readString(): (int, int, int, bool) =
    ## Returns (startLine, startCol, length, ok)
    let sLine = line
    let sCol = col
    advance()  # skip opening "
    var length = 1
    while pos < text.len:
      let c = text[pos]
      if c == '\\':
        advance()
        inc length
        if pos < text.len:
          let esc = text[pos]
          if esc notin {'\"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'}:
            diags.add(DiagInfo(line: line, col: col, endCol: col + 1,
                               message: "Invalid escape sequence: \\" & esc))
          advance()
          inc length
        else:
          diags.add(DiagInfo(line: sLine, col: sCol, endCol: sCol + length,
                             message: "Unterminated string"))
          return (sLine, sCol, length, false)
      elif c == '"':
        advance()
        inc length
        return (sLine, sCol, length, true)
      elif c == '\n':
        diags.add(DiagInfo(line: sLine, col: sCol, endCol: sCol + length,
                           message: "Unterminated string"))
        return (sLine, sCol, length, false)
      else:
        advance()
        inc length
    diags.add(DiagInfo(line: sLine, col: sCol, endCol: sCol + length,
                       message: "Unterminated string"))
    return (sLine, sCol, length, false)

  var rootValues = 0

  while pos < text.len:
    skipWhitespace()
    if pos >= text.len:
      break

    let c = ch()

    case c
    of '{':
      if contextStack.len == 0:
        inc rootValues
      contextStack.add(ckObject)
      expectKey = true
      advance()

    of '}':
      if contextStack.len > 0 and contextStack[^1] == ckObject:
        contextStack.setLen(contextStack.len - 1)
      else:
        diags.add(DiagInfo(line: line, col: col, endCol: col + 1,
                           message: "Unexpected '}'"))
      if contextStack.len > 0 and contextStack[^1] == ckObject:
        expectKey = false
      advance()

    of '[':
      if contextStack.len == 0:
        inc rootValues
      contextStack.add(ckArray)
      expectKey = false
      advance()

    of ']':
      if contextStack.len > 0 and contextStack[^1] == ckArray:
        contextStack.setLen(contextStack.len - 1)
      else:
        diags.add(DiagInfo(line: line, col: col, endCol: col + 1,
                           message: "Unexpected ']'"))
      if contextStack.len > 0 and contextStack[^1] == ckObject:
        expectKey = false
      advance()

    of '"':
      let isKey = expectKey and contextStack.len > 0 and contextStack[^1] == ckObject
      if contextStack.len == 0:
        inc rootValues
      let (sLine, sCol, length, _) = readString()
      if isKey:
        tokens.add(JsonToken(kind: jtProperty, line: sLine, col: sCol, length: length))
        expectKey = false
      else:
        tokens.add(JsonToken(kind: jtString, line: sLine, col: sCol, length: length))

    of '-', '0'..'9':
      if contextStack.len == 0:
        inc rootValues
      let sLine = line
      let sCol = col
      var length = 0
      if ch() == '-':
        advance()
        inc length
      while pos < text.len and text[pos] in {'0'..'9'}:
        advance()
        inc length
      if pos < text.len and text[pos] == '.':
        advance()
        inc length
        while pos < text.len and text[pos] in {'0'..'9'}:
          advance()
          inc length
      if pos < text.len and text[pos] in {'e', 'E'}:
        advance()
        inc length
        if pos < text.len and text[pos] in {'+', '-'}:
          advance()
          inc length
        while pos < text.len and text[pos] in {'0'..'9'}:
          advance()
          inc length
      tokens.add(JsonToken(kind: jtNumber, line: sLine, col: sCol, length: length))

    of 't':
      if contextStack.len == 0:
        inc rootValues
      let sLine = line
      let sCol = col
      if pos + 3 < text.len and text[pos..pos+3] == "true":
        for _ in 0..<4: advance()
        tokens.add(JsonToken(kind: jtKeyword, line: sLine, col: sCol, length: 4))
      else:
        diags.add(DiagInfo(line: line, col: col, endCol: col + 1,
                           message: "Unexpected character: " & c))
        advance()

    of 'f':
      if contextStack.len == 0:
        inc rootValues
      let sLine = line
      let sCol = col
      if pos + 4 < text.len and text[pos..pos+4] == "false":
        for _ in 0..<5: advance()
        tokens.add(JsonToken(kind: jtKeyword, line: sLine, col: sCol, length: 5))
      else:
        diags.add(DiagInfo(line: line, col: col, endCol: col + 1,
                           message: "Unexpected character: " & c))
        advance()

    of 'n':
      if contextStack.len == 0:
        inc rootValues
      let sLine = line
      let sCol = col
      if pos + 3 < text.len and text[pos..pos+3] == "null":
        for _ in 0..<4: advance()
        tokens.add(JsonToken(kind: jtKeyword, line: sLine, col: sCol, length: 4))
      else:
        diags.add(DiagInfo(line: line, col: col, endCol: col + 1,
                           message: "Unexpected character: " & c))
        advance()

    of ':':
      expectKey = false
      advance()

    of ',':
      if contextStack.len > 0 and contextStack[^1] == ckObject:
        expectKey = true
      advance()

    else:
      diags.add(DiagInfo(line: line, col: col, endCol: col + 1,
                         message: "Unexpected character: " & c))
      advance()

  if contextStack.len > 0:
    diags.add(DiagInfo(line: line, col: col, endCol: col + 1,
                       message: "Unexpected end of input"))

  if rootValues > 1:
    diags.add(DiagInfo(line: 0, col: 0, endCol: 1,
                       message: "Multiple root values in JSON"))

  return (tokens, diags)

# ---------------------------------------------------------------------------
# Semantic Token Encoding (LSP delta encoding)
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[JsonToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of jtProperty: stProperty
      of jtString: stString
      of jtNumber: stNumber
      of jtKeyword: stKeyword
    result.add(deltaLine)
    result.add(deltaCol)
    result.add(tok.length)
    result.add(tokenType)
    result.add(0)  # no modifiers
    prevLine = tok.line
    prevCol = tok.col

# ---------------------------------------------------------------------------
# Inside-out Range Tokenizer (no full-context stack needed)
# ---------------------------------------------------------------------------

proc tokenizeJsonRange(text: string, startLine, endLine: int): seq[JsonToken] =
  ## Tokenize only lines [startLine..endLine] using local context.
  ## For JSON, token types can be determined by nearby characters:
  ##   - string followed by ':' → property, otherwise → string value
  ##   - numbers, true/false/null are self-describing
  result = @[]
  var pos = 0
  var line = 0
  var col = 0

  template ch(): char =
    if pos < text.len: text[pos] else: '\0'

  template advance() =
    if pos < text.len:
      if text[pos] == '\n':
        inc line
        col = 0
      else:
        inc col
      inc pos

  template skipWhitespace() =
    while pos < text.len and text[pos] in {' ', '\t', '\r', '\n'}:
      advance()

  # Skip to startLine
  while pos < text.len and line < startLine:
    if text[pos] == '\n':
      inc line
      col = 0
    else:
      inc col
    inc pos

  while pos < text.len and line <= endLine:
    skipWhitespace()
    if pos >= text.len or line > endLine:
      break

    let c = ch()
    case c
    of '"':
      let sLine = line
      let sCol = col
      advance()  # skip opening "
      var length = 1
      while pos < text.len:
        let sc = text[pos]
        if sc == '\\':
          advance()
          inc length
          if pos < text.len:
            advance()
            inc length
        elif sc == '"':
          advance()
          inc length
          break
        elif sc == '\n':
          break
        else:
          advance()
          inc length

      # Determine type: look ahead past whitespace for ':'
      var lookPos = pos
      while lookPos < text.len and text[lookPos] in {' ', '\t', '\r', '\n'}:
        inc lookPos
      let isProperty = lookPos < text.len and text[lookPos] == ':'

      if sLine >= startLine and sLine <= endLine:
        if isProperty:
          result.add(JsonToken(kind: jtProperty, line: sLine, col: sCol, length: length))
        else:
          result.add(JsonToken(kind: jtString, line: sLine, col: sCol, length: length))

    of '-', '0'..'9':
      let sLine = line
      let sCol = col
      var length = 0
      if ch() == '-':
        advance()
        inc length
      while pos < text.len and text[pos] in {'0'..'9'}:
        advance()
        inc length
      if pos < text.len and text[pos] == '.':
        advance()
        inc length
        while pos < text.len and text[pos] in {'0'..'9'}:
          advance()
          inc length
      if pos < text.len and text[pos] in {'e', 'E'}:
        advance()
        inc length
        if pos < text.len and text[pos] in {'+', '-'}:
          advance()
          inc length
        while pos < text.len and text[pos] in {'0'..'9'}:
          advance()
          inc length
      if sLine >= startLine and sLine <= endLine:
        result.add(JsonToken(kind: jtNumber, line: sLine, col: sCol, length: length))

    of 't':
      let sLine = line
      let sCol = col
      if pos + 3 < text.len and text[pos..pos+3] == "true":
        for _ in 0..<4: advance()
        if sLine >= startLine and sLine <= endLine:
          result.add(JsonToken(kind: jtKeyword, line: sLine, col: sCol, length: 4))
      else:
        advance()

    of 'f':
      let sLine = line
      let sCol = col
      if pos + 4 < text.len and text[pos..pos+4] == "false":
        for _ in 0..<5: advance()
        if sLine >= startLine and sLine <= endLine:
          result.add(JsonToken(kind: jtKeyword, line: sLine, col: sCol, length: 5))
      else:
        advance()

    of 'n':
      let sLine = line
      let sCol = col
      if pos + 3 < text.len and text[pos..pos+3] == "null":
        for _ in 0..<4: advance()
        if sLine >= startLine and sLine <= endLine:
          result.add(JsonToken(kind: jtKeyword, line: sLine, col: sCol, length: 4))
      else:
        advance()

    of '{', '}', '[', ']', ':', ',':
      advance()

    else:
      advance()

# ---------------------------------------------------------------------------
# LSP Protocol I/O
# ---------------------------------------------------------------------------

proc readMessage(): string =
  ## Read a JSON-RPC message from stdin (Content-Length framing)
  ## Returns empty string on EOF
  var contentLength = -1
  while true:
    var line: string
    try:
      line = stdin.readLine().strip(chars = {'\r', '\n'})
    except EOFError:
      return ""
    if line.len == 0:
      break
    if line.startsWith("Content-Length:"):
      try:
        contentLength = parseInt(line.split(':')[1].strip())
      except ValueError:
        discard
  if contentLength <= 0:
    return ""
  var buf = newString(contentLength)
  let bytesRead = stdin.readBuffer(addr buf[0], contentLength)
  if bytesRead < contentLength:
    buf.setLen(bytesRead)
  return buf

proc sendMessage(msg: JsonNode) =
  let body = $msg
  stdout.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  stdout.flushFile()

proc sendResponse(id: JsonNode, resultNode: JsonNode) =
  sendMessage(%*{
    "jsonrpc": "2.0",
    "id": id,
    "result": resultNode
  })

proc sendTokensResponse(id: JsonNode, data: seq[int]) =
  ## Send semantic tokens response with direct string building.
  ## Avoids creating millions of JNode objects for the data array.
  var body = """{"jsonrpc":"2.0","id":""" & $id & ""","result":{"data":["""
  for i, v in data:
    if i > 0: body.add(',')
    body.addInt(v)
  body.add("]}}")
  stdout.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  stdout.flushFile()

proc sendNotification(meth: string, params: JsonNode) =
  sendMessage(%*{
    "jsonrpc": "2.0",
    "method": meth,
    "params": params
  })

# ---------------------------------------------------------------------------
# Diagnostics publishing
# ---------------------------------------------------------------------------

proc publishDiagnostics(uri: string, text: string) =
  let (_, diags) = tokenizeJson(text)
  var diagsJson = newJArray()
  for d in diags:
    diagsJson.add(%*{
      "range": {
        "start": {"line": d.line, "character": d.col},
        "end": {"line": d.line, "character": d.endCol}
      },
      "severity": 1,
      "source": "niv-json-lsp",
      "message": d.message
    })
  sendNotification("textDocument/publishDiagnostics", %*{
    "uri": uri,
    "diagnostics": diagsJson
  })

# ---------------------------------------------------------------------------
# Main server loop
# ---------------------------------------------------------------------------

proc main() =
  var documents: seq[DocumentState]
  var running = true

  while running:
    let raw = readMessage()
    if raw.len == 0:
      break  # EOF on stdin

    var msg: JsonNode
    try:
      msg = parseJson(raw)
    except JsonParsingError:
      continue

    let meth = msg.getOrDefault("method").getStr("")
    let id = msg.getOrDefault("id")

    case meth
    of "initialize":
      sendResponse(id, %*{
        "capabilities": {
          "textDocumentSync": 1,
          "semanticTokensProvider": {
            "legend": {
              "tokenTypes": ["property", "string", "number", "keyword"],
              "tokenModifiers": []
            },
            "full": true,
            "range": true
          }
        }
      })

    of "initialized":
      discard

    of "textDocument/didOpen":
      let params = msg["params"]
      let td = params["textDocument"]
      let uri = td["uri"].getStr()
      let text = td["text"].getStr()
      let version = td["version"].getInt()
      # Store or update document
      var found = false
      for i in 0..<documents.len:
        if documents[i].uri == uri:
          documents[i].text = text
          documents[i].version = version
          found = true
          break
      if not found:
        documents.add(DocumentState(uri: uri, text: text, version: version))
      publishDiagnostics(uri, text)

    of "textDocument/didChange":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let version = params["textDocument"]["version"].getInt()
      let changes = params["contentChanges"]
      if changes.len > 0:
        let newText = changes[0]["text"].getStr()
        for i in 0..<documents.len:
          if documents[i].uri == uri:
            documents[i].text = newText
            documents[i].version = version
            # Skip diagnostics for large files (>1MB) to avoid slow tokenization
            if newText.len < 1_000_000:
              publishDiagnostics(uri, newText)
            break

    of "textDocument/didClose":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      for i in 0..<documents.len:
        if documents[i].uri == uri:
          documents.delete(i)
          break

    of "textDocument/semanticTokens/full":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      var text = ""
      for doc in documents:
        if doc.uri == uri:
          text = doc.text
          break
      let (tokens, _) = tokenizeJson(text)
      let data = encodeSemanticTokens(tokens)
      sendTokensResponse(id, data)

    of "textDocument/semanticTokens/range":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let rangeNode = params["range"]
      let startLine = rangeNode["start"]["line"].getInt()
      let endLine = rangeNode["end"]["line"].getInt()
      var text = ""
      for doc in documents:
        if doc.uri == uri:
          text = doc.text
          break
      let tokens = tokenizeJsonRange(text, startLine, endLine)
      let data = encodeSemanticTokens(tokens)
      sendTokensResponse(id, data)

    of "shutdown":
      sendResponse(id, newJNull())
      running = false

    of "exit":
      break

    else:
      # Unknown method with id → return method not found
      if id != nil and id.kind != JNull:
        sendMessage(%*{
          "jsonrpc": "2.0",
          "id": id,
          "error": {"code": -32601, "message": "Method not found: " & meth}
        })

when isMainModule:
  main()
