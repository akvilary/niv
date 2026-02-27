## niv_toml_lsp — minimal TOML Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils, os, posix]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  TomlTokenKind = enum
    ttKeyword      # true, false, inf, nan
    ttString       # "basic", 'literal', """multi""", '''multi'''
    ttNumber       # int, float, hex, oct, bin
    ttComment      # # comment
    ttProperty     # bare keys, quoted keys (left of =)
    ttOperator     # = and . (in dotted keys)
    ttType         # [table] and [[array]] header names
    ttDatetime     # datetime, date, time

  TomlToken = object
    kind: TomlTokenKind
    line: int
    col: int
    length: int

  DocumentState = object
    uri: string
    text: string
    version: int

# Semantic token type indices (must match legend in initialize response)
const
  stKeyword = 0
  stString = 1
  stNumber = 2
  stComment = 3
  stProperty = 4
  stOperator = 5
  stType = 6
  stDatetime = 7

# ---------------------------------------------------------------------------
# TOML Tokenizer
# ---------------------------------------------------------------------------

proc isBareKeyChar(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}

proc tokenizeToml(text: string): seq[TomlToken] =
  var tokens: seq[TomlToken]
  var pos = 0
  var line = 0
  var col = 0
  var inMultiBasic = false    # inside """..."""
  var inMultiLiteral = false  # inside '''...'''
  var multiStartLine = 0
  var multiStartCol = 0
  var multiLineTokenStart = 0 # col at start of current line segment

  template ch(): char =
    if pos < text.len: text[pos] else: '\0'

  template peek(offset: int): char =
    if pos + offset < text.len: text[pos + offset] else: '\0'

  template advance() =
    if pos < text.len:
      if text[pos] == '\n':
        inc line
        col = 0
      else:
        inc col
      inc pos

  template skipWhitespace() =
    while pos < text.len and text[pos] in {' ', '\t', '\r'}:
      advance()

  # Emit per-line tokens for multi-line strings
  proc emitMultiLineToken(tokens: var seq[TomlToken], kind: TomlTokenKind,
                          startLine, startCol, endLine, endCol: int) =
    if startLine == endLine:
      tokens.add(TomlToken(kind: kind, line: startLine, col: startCol,
                           length: endCol - startCol))
    else:
      # First line: from startCol to end of line (estimate with large length)
      # We'll fix lengths by scanning the text
      tokens.add(TomlToken(kind: kind, line: startLine, col: startCol, length: 1))
      for ln in startLine + 1 ..< endLine:
        tokens.add(TomlToken(kind: kind, line: ln, col: 0, length: 1))
      tokens.add(TomlToken(kind: kind, line: endLine, col: 0, length: endCol))

  # Compute per-line lengths for multi-line tokens
  proc emitMultiLineFromText(tokens: var seq[TomlToken], kind: TomlTokenKind,
                             text: string, startPos, endPos, startLine, startCol: int) =
    var ln = startLine
    var c = startCol
    var lineStart = startPos
    for i in startPos..<endPos:
      if text[i] == '\n':
        let length = i - lineStart - (if ln == startLine: 0 else: 0)
        let actualCol = if ln == startLine: startCol else: 0
        let actualLen = if ln == startLine: i - lineStart else: i - lineStart
        if actualLen > 0:
          tokens.add(TomlToken(kind: kind, line: ln, col: actualCol, length: actualLen))
        inc ln
        lineStart = i + 1
      # Last segment
    let remaining = endPos - lineStart
    let actualCol = if ln == startLine: startCol else: 0
    if remaining > 0:
      tokens.add(TomlToken(kind: kind, line: ln, col: actualCol, length: remaining))

  while pos < text.len:
    # Skip whitespace (not newlines)
    skipWhitespace()
    if pos >= text.len: break

    let c = ch()

    if c == '\n':
      advance()
      continue

    # Comment
    if c == '#':
      let sLine = line
      let sCol = col
      let sPos = pos
      while pos < text.len and text[pos] != '\n':
        advance()
      tokens.add(TomlToken(kind: ttComment, line: sLine, col: sCol,
                           length: pos - sPos))
      continue

    # Table headers: [name] or [[name]]
    if c == '[':
      let sCol = col
      let isArray = peek(1) == '['
      if isArray:
        advance() # first [
        advance() # second [
      else:
        advance() # [
      # Skip whitespace inside brackets
      skipWhitespace()
      # Read table name (can contain dots)
      let nameStart = pos
      let nameCol = col
      let nameLine = line
      while pos < text.len and text[pos] notin {']', '\n', '#'}:
        advance()
      let nameEnd = pos
      # Trim trailing whitespace from name
      var trimEnd = nameEnd
      while trimEnd > nameStart and text[trimEnd - 1] in {' ', '\t'}:
        dec trimEnd
      if trimEnd > nameStart:
        tokens.add(TomlToken(kind: ttType, line: nameLine, col: nameCol,
                             length: trimEnd - nameStart))
      # Skip closing brackets
      if pos < text.len and text[pos] == ']':
        advance()
      if isArray and pos < text.len and text[pos] == ']':
        advance()
      continue

    # Key = Value pairs
    # A key starts with a bare key char or a quote
    if isBareKeyChar(c) or c == '"' or c == '\'':
      # Try to parse as key = value
      let keyStartPos = pos
      let keyStartCol = col
      let keyStartLine = line

      # Read key (possibly dotted: a.b.c)
      var isKey = false
      var keyParts: seq[(int, int, int)] # (col, length, pos) for each part
      var dotPositions: seq[(int, int)]  # (line, col) for dots

      # Save state for backtracking
      let savedPos = pos
      let savedLine = line
      let savedCol = col

      block parseKey:
        while true:
          let partCol = col
          let partPos = pos
          var partLen = 0

          if pos < text.len and text[pos] == '"':
            # Quoted key (basic)
            advance()
            partLen = 1
            while pos < text.len and text[pos] != '"' and text[pos] != '\n':
              if text[pos] == '\\' and pos + 1 < text.len:
                advance()
                inc partLen
              advance()
              inc partLen
            if pos < text.len and text[pos] == '"':
              advance()
              inc partLen
            keyParts.add((partCol, partLen, partPos))
          elif pos < text.len and text[pos] == '\'':
            # Quoted key (literal)
            advance()
            partLen = 1
            while pos < text.len and text[pos] != '\'' and text[pos] != '\n':
              advance()
              inc partLen
            if pos < text.len and text[pos] == '\'':
              advance()
              inc partLen
            keyParts.add((partCol, partLen, partPos))
          elif pos < text.len and isBareKeyChar(text[pos]):
            # Bare key
            while pos < text.len and isBareKeyChar(text[pos]):
              advance()
              inc partLen
            keyParts.add((partCol, partLen, partPos))
          else:
            break parseKey

          # Check for dot (dotted key)
          skipWhitespace()
          if pos < text.len and text[pos] == '.':
            dotPositions.add((line, col))
            advance() # skip dot
            skipWhitespace()
          else:
            break

        # Now check for = sign
        skipWhitespace()
        if pos < text.len and text[pos] == '=':
          isKey = true

      if isKey:
        # Emit key parts as property tokens
        for (partCol, partLen, partPos) in keyParts:
          tokens.add(TomlToken(kind: ttProperty, line: keyStartLine,
                               col: partCol, length: partLen))
        # Emit dots as operators
        for (dotLine, dotCol) in dotPositions:
          tokens.add(TomlToken(kind: ttOperator, line: dotLine,
                               col: dotCol, length: 1))
        # Emit = as operator
        tokens.add(TomlToken(kind: ttOperator, line: line, col: col, length: 1))
        advance() # skip =
        skipWhitespace()

        # Parse value
        if pos >= text.len or text[pos] == '\n':
          continue

        let vc = text[pos]

        # Multi-line basic string """
        if vc == '"' and peek(1) == '"' and peek(2) == '"':
          let sLine = line
          let sCol = col
          let sPos = pos
          advance(); advance(); advance() # skip """
          # Optional newline after opening
          if pos < text.len and text[pos] == '\n':
            advance()
          elif pos < text.len and text[pos] == '\r' and peek(1) == '\n':
            advance(); advance()
          while pos < text.len:
            if text[pos] == '"' and peek(1) == '"' and peek(2) == '"':
              advance(); advance(); advance()
              break
            if text[pos] == '\\':
              advance()
              if pos < text.len: advance()
            else:
              advance()
          emitMultiLineFromText(tokens, ttString, text, sPos, pos, sLine, sCol)
          continue

        # Multi-line literal string '''
        if vc == '\'' and peek(1) == '\'' and peek(2) == '\'':
          let sLine = line
          let sCol = col
          let sPos = pos
          advance(); advance(); advance() # skip '''
          if pos < text.len and text[pos] == '\n':
            advance()
          elif pos < text.len and text[pos] == '\r' and peek(1) == '\n':
            advance(); advance()
          while pos < text.len:
            if text[pos] == '\'' and peek(1) == '\'' and peek(2) == '\'':
              advance(); advance(); advance()
              break
            advance()
          emitMultiLineFromText(tokens, ttString, text, sPos, pos, sLine, sCol)
          continue

        # Basic string "..."
        if vc == '"':
          let sCol = col
          let sPos = pos
          advance() # skip opening "
          while pos < text.len and text[pos] != '"' and text[pos] != '\n':
            if text[pos] == '\\' and pos + 1 < text.len:
              advance()
            advance()
          if pos < text.len and text[pos] == '"':
            advance()
          tokens.add(TomlToken(kind: ttString, line: line, col: sCol,
                               length: pos - sPos))
          continue

        # Literal string '...'
        if vc == '\'':
          let sCol = col
          let sPos = pos
          advance() # skip opening '
          while pos < text.len and text[pos] != '\'' and text[pos] != '\n':
            advance()
          if pos < text.len and text[pos] == '\'':
            advance()
          tokens.add(TomlToken(kind: ttString, line: line, col: sCol,
                               length: pos - sPos))
          continue

        # Keywords: true, false, inf, +inf, -inf, nan, +nan, -nan
        if vc == 't' and pos + 3 < text.len and text[pos..pos+3] == "true":
          let nextCh = if pos + 4 < text.len: text[pos + 4] else: '\0'
          if not isBareKeyChar(nextCh):
            tokens.add(TomlToken(kind: ttKeyword, line: line, col: col, length: 4))
            for _ in 0..<4: advance()
            continue

        if vc == 'f' and pos + 4 < text.len and text[pos..pos+4] == "false":
          let nextCh = if pos + 5 < text.len: text[pos + 5] else: '\0'
          if not isBareKeyChar(nextCh):
            tokens.add(TomlToken(kind: ttKeyword, line: line, col: col, length: 5))
            for _ in 0..<5: advance()
            continue

        if vc == 'i' and pos + 2 < text.len and text[pos..pos+2] == "inf":
          let nextCh = if pos + 3 < text.len: text[pos + 3] else: '\0'
          if not isBareKeyChar(nextCh):
            tokens.add(TomlToken(kind: ttKeyword, line: line, col: col, length: 3))
            for _ in 0..<3: advance()
            continue

        if vc == 'n' and pos + 2 < text.len and text[pos..pos+2] == "nan":
          let nextCh = if pos + 3 < text.len: text[pos + 3] else: '\0'
          if not isBareKeyChar(nextCh):
            tokens.add(TomlToken(kind: ttKeyword, line: line, col: col, length: 3))
            for _ in 0..<3: advance()
            continue

        if (vc == '+' or vc == '-') and pos + 1 < text.len:
          let nextWord = if pos + 3 < text.len: text[pos+1..pos+3] else: ""
          if nextWord == "inf":
            let afterCh = if pos + 4 < text.len: text[pos + 4] else: '\0'
            if not isBareKeyChar(afterCh):
              tokens.add(TomlToken(kind: ttKeyword, line: line, col: col, length: 4))
              for _ in 0..<4: advance()
              continue
          if nextWord == "nan":
            let afterCh = if pos + 4 < text.len: text[pos + 4] else: '\0'
            if not isBareKeyChar(afterCh):
              tokens.add(TomlToken(kind: ttKeyword, line: line, col: col, length: 4))
              for _ in 0..<4: advance()
              continue

        # Numbers and datetimes
        # Datetime starts with digit and contains - or :
        if vc in {'0'..'9'} or ((vc == '+' or vc == '-') and peek(1) in {'0'..'9'}):
          let sCol = col
          let sPos = pos

          # Read the full value token
          var valLen = 0
          var hasDateSep = false
          var hasTimeSep = false
          var hasHexOctBin = false

          # Check for 0x, 0o, 0b prefixes
          if vc == '0' and peek(1) in {'x', 'o', 'b'}:
            hasHexOctBin = true
            advance(); advance()
            valLen = 2
            while pos < text.len and text[pos] in
                {'0'..'9', 'a'..'f', 'A'..'F', '_'}:
              advance()
              inc valLen
            tokens.add(TomlToken(kind: ttNumber, line: line, col: sCol,
                                 length: valLen))
            continue

          # Read digits and special chars
          if vc in {'+', '-'}:
            advance()
            inc valLen

          # Read number/date/time value
          while pos < text.len and text[pos] in
              {'0'..'9', '-', ':', '.', 'T', 'Z', '+', '_', 'e', 'E'}:
            if text[pos] == '-' and valLen >= 4: hasDateSep = true
            if text[pos] == ':': hasTimeSep = true
            advance()
            inc valLen

          # Classify: datetime if has date or time separators
          if hasDateSep or hasTimeSep:
            tokens.add(TomlToken(kind: ttDatetime, line: line, col: sCol,
                                 length: valLen))
          else:
            tokens.add(TomlToken(kind: ttNumber, line: line, col: sCol,
                                 length: valLen))
          continue

        # Inline table or array values - skip structural chars
        if vc in {'{', '}', '[', ']', ','}:
          advance()
          continue

        # Unknown value char - skip
        advance()
        continue
      else:
        # Not a key=value, restore position and skip this char
        pos = savedPos
        line = savedLine
        col = savedCol
        advance()
        continue

    # Skip any other character
    advance()

  return tokens

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizeTomlRange(text: string, startLine, endLine: int): seq[TomlToken] =
  ## Tokenize full text but only emit tokens in [startLine..endLine]
  let allTokens = tokenizeToml(text)
  result = @[]
  for tok in allTokens:
    if tok.line >= startLine and tok.line <= endLine:
      result.add(tok)

# ---------------------------------------------------------------------------
# Semantic Token Encoding (LSP delta encoding)
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[TomlToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of ttKeyword: stKeyword
      of ttString: stString
      of ttNumber: stNumber
      of ttComment: stComment
      of ttProperty: stProperty
      of ttOperator: stOperator
      of ttType: stType
      of ttDatetime: stDatetime
    result.add(deltaLine)
    result.add(deltaCol)
    result.add(tok.length)
    result.add(tokenType)
    result.add(0)  # no modifiers
    prevLine = tok.line
    prevCol = tok.col

# ---------------------------------------------------------------------------
# LSP Protocol I/O
# ---------------------------------------------------------------------------

proc readMessage(): string =
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

# ---------------------------------------------------------------------------
# Main server loop
# ---------------------------------------------------------------------------

proc main() =
  var documents: seq[DocumentState]
  var running = true

  while running:
    let raw = readMessage()
    if raw.len == 0:
      break

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
              "tokenTypes": ["keyword", "string", "number", "comment",
                             "property", "operator", "type", "builtinConstant"],
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
      var found = false
      for i in 0..<documents.len:
        if documents[i].uri == uri:
          documents[i].text = text
          documents[i].version = version
          found = true
          break
      if not found:
        documents.add(DocumentState(uri: uri, text: text, version: version))

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
      let tokens = tokenizeToml(text)
      let data = encodeSemanticTokens(tokens)
      var dataJson = newJArray()
      for v in data:
        dataJson.add(%v)
      sendResponse(id, %*{"data": dataJson})

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
      let tokens = tokenizeTomlRange(text, startLine, endLine)
      let data = encodeSemanticTokens(tokens)
      var dataJson = newJArray()
      for v in data:
        dataJson.add(%v)
      sendResponse(id, %*{"data": dataJson})

    of "shutdown":
      sendResponse(id, newJNull())
      running = false

    of "exit":
      break

    else:
      if id != nil and id.kind != JNull:
        sendMessage(%*{
          "jsonrpc": "2.0",
          "id": id,
          "error": {"code": -32601, "message": "Method not found: " & meth}
        })

when isMainModule:
  main()
