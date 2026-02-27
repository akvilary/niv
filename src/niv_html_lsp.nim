## niv_html_lsp — minimal HTML Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  HtmlTokenKind = enum
    htKeyword      # <!DOCTYPE html>
    htString       # attribute values "..." '...'
    htComment      # <!-- ... -->
    htType         # tag names: div, span, html, body
    htProperty     # attribute names: class, id, href, src
    htOperator     # < > </ /> =
    htMacro        # HTML entities: &amp; &#123; &#xAB;

  HtmlToken = object
    kind: HtmlTokenKind
    line: int
    col: int
    length: int

  DocumentState = object
    uri: string
    text: string
    version: int

const
  stKeyword = 0
  stString = 1
  stComment = 2
  stType = 3
  stProperty = 4
  stOperator = 5
  stMacro = 6

# ---------------------------------------------------------------------------
# HTML Tokenizer
# ---------------------------------------------------------------------------

proc isNameChar(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', ':'}

proc isNameStart(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '_', ':'}

proc tokenizeHtml(text: string): seq[HtmlToken] =
  var tokens: seq[HtmlToken]
  var pos = 0
  var line = 0
  var col = 0

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

  proc getLineLen(text: string, lineNum: int): int =
    var ln = 0
    var i = 0
    while i < text.len:
      if ln == lineNum:
        let start = i
        while i < text.len and text[i] != '\n':
          inc i
        return i - start
      if text[i] == '\n':
        inc ln
      inc i
    return 0

  while pos < text.len:
    let c = ch()

    # Comment <!-- ... -->
    if c == '<' and peek(1) == '!' and peek(2) == '-' and peek(3) == '-':
      let sCol = col
      let sLine = line
      advance(); advance(); advance(); advance() # skip <!--
      while pos < text.len:
        if text[pos] == '-' and peek(1) == '-' and peek(2) == '>':
          advance(); advance(); advance() # skip -->
          break
        advance()
      # Emit per-line tokens
      if sLine == line:
        tokens.add(HtmlToken(kind: htComment, line: sLine, col: sCol,
                              length: col - sCol))
      else:
        let firstLen = getLineLen(text, sLine)
        tokens.add(HtmlToken(kind: htComment, line: sLine, col: sCol,
                              length: firstLen - sCol))
        for ln in (sLine + 1)..<line:
          let lnLen = getLineLen(text, ln)
          if lnLen > 0:
            tokens.add(HtmlToken(kind: htComment, line: ln, col: 0,
                                  length: lnLen))
        if col > 0:
          tokens.add(HtmlToken(kind: htComment, line: line, col: 0,
                                length: col))
      continue

    # DOCTYPE: <!DOCTYPE ...>
    if c == '<' and peek(1) == '!':
      # Check for DOCTYPE (case insensitive)
      let upper = text[pos..min(pos + 9, text.len - 1)].toUpperAscii()
      if upper.startsWith("<!DOCTYPE"):
        let sCol = col
        let sLine = line
        while pos < text.len and text[pos] != '>':
          advance()
        if pos < text.len: advance() # skip >
        tokens.add(HtmlToken(kind: htKeyword, line: sLine, col: sCol,
                              length: col - sCol))
        continue

    # Opening tag < or closing tag </
    if c == '<':
      let sCol = col
      let sLine = line
      let isClosing = peek(1) == '/'

      if isClosing:
        # </
        advance(); advance() # skip </
        tokens.add(HtmlToken(kind: htOperator, line: sLine, col: sCol, length: 2))
      else:
        # <
        advance() # skip <
        tokens.add(HtmlToken(kind: htOperator, line: sLine, col: sCol, length: 1))

      # Skip whitespace
      while pos < text.len and text[pos] in {' ', '\t', '\n', '\r'}:
        advance()

      # Tag name
      var tagNameLower = ""
      if pos < text.len and isNameStart(text[pos]):
        let nameCol = col
        let nameLine = line
        let nameStart = pos
        while pos < text.len and isNameChar(text[pos]):
          advance()
        tokens.add(HtmlToken(kind: htType, line: nameLine, col: nameCol,
                              length: col - nameCol))
        tagNameLower = text[nameStart..<pos].toLowerAscii()

      if isClosing:
        # Closing tag: skip to >
        while pos < text.len and text[pos] in {' ', '\t', '\n', '\r'}:
          advance()
        if pos < text.len and text[pos] == '>':
          let gCol = col
          advance()
          tokens.add(HtmlToken(kind: htOperator, line: line, col: gCol, length: 1))
        continue

      # Attributes (inside opening tag until > or />)
      while pos < text.len:
        # Skip whitespace
        while pos < text.len and text[pos] in {' ', '\t', '\n', '\r'}:
          advance()

        if pos >= text.len: break

        # Self-closing />
        if text[pos] == '/' and peek(1) == '>':
          let opCol = col
          advance(); advance()
          tokens.add(HtmlToken(kind: htOperator, line: line, col: opCol, length: 2))
          break

        # Closing >
        if text[pos] == '>':
          let opCol = col
          advance()
          tokens.add(HtmlToken(kind: htOperator, line: line, col: opCol, length: 1))
          break

        # Attribute name
        if isNameStart(text[pos]) or text[pos] == '-':
          let attrCol = col
          let attrLine = line
          while pos < text.len and isNameChar(text[pos]):
            advance()
          tokens.add(HtmlToken(kind: htProperty, line: attrLine, col: attrCol,
                                length: col - attrCol))

          # Skip whitespace
          while pos < text.len and text[pos] in {' ', '\t', '\n', '\r'}:
            advance()

          # = sign
          if pos < text.len and text[pos] == '=':
            let eqCol = col
            advance()
            tokens.add(HtmlToken(kind: htOperator, line: line, col: eqCol, length: 1))

            # Skip whitespace
            while pos < text.len and text[pos] in {' ', '\t', '\n', '\r'}:
              advance()

            # Attribute value
            if pos < text.len and text[pos] in {'"', '\''}:
              let q = text[pos]
              let valCol = col
              let valLine = line
              advance() # skip opening quote
              while pos < text.len and text[pos] != q:
                if text[pos] == '\n':
                  advance()
                else:
                  advance()
              if pos < text.len: advance() # skip closing quote
              if valLine == line:
                tokens.add(HtmlToken(kind: htString, line: valLine, col: valCol,
                                      length: col - valCol))
            elif pos < text.len and text[pos] notin {' ', '\t', '\n', '\r', '>', '/'}:
              # Unquoted attribute value
              let valCol = col
              let valLine = line
              while pos < text.len and text[pos] notin {' ', '\t', '\n', '\r', '>', '"', '\''}:
                advance()
              tokens.add(HtmlToken(kind: htString, line: valLine, col: valCol,
                                    length: col - valCol))
          continue

        # Unknown character inside tag — skip
        advance()

      # Skip content of script and style tags
      if tagNameLower in ["script", "style"]:
        let closeTag = "</" & tagNameLower
        while pos < text.len:
          if text[pos] == '<' and pos + closeTag.len <= text.len:
            let slice = text[pos..<pos + closeTag.len].toLowerAscii()
            if slice == closeTag:
              break
          advance()
      continue

    # HTML entity: &name; or &#digits; or &#xhex;
    if c == '&':
      let sCol = col
      let sLine = line
      advance() # skip &
      if pos < text.len and text[pos] == '#':
        advance() # skip #
        if pos < text.len and text[pos] in {'x', 'X'}:
          advance() # skip x
          while pos < text.len and text[pos] in {'0'..'9', 'a'..'f', 'A'..'F'}:
            advance()
        else:
          while pos < text.len and text[pos] in {'0'..'9'}:
            advance()
      else:
        while pos < text.len and text[pos] in {'a'..'z', 'A'..'Z', '0'..'9'}:
          advance()
      if pos < text.len and text[pos] == ';':
        advance() # skip ;
        tokens.add(HtmlToken(kind: htMacro, line: sLine, col: sCol,
                              length: col - sCol))
      # If no semicolon, just skip (not a valid entity)
      continue

    # Regular text — skip
    advance()

  return tokens

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizeHtmlRange(text: string, startLine, endLine: int): seq[HtmlToken] =
  let allTokens = tokenizeHtml(text)
  result = @[]
  for tok in allTokens:
    if tok.line >= startLine and tok.line <= endLine:
      result.add(tok)

# ---------------------------------------------------------------------------
# Semantic Token Encoding (LSP delta encoding)
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[HtmlToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    if tok.length <= 0: continue
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of htKeyword: stKeyword
      of htString: stString
      of htComment: stComment
      of htType: stType
      of htProperty: stProperty
      of htOperator: stOperator
      of htMacro: stMacro
    result.add(deltaLine)
    result.add(deltaCol)
    result.add(tok.length)
    result.add(tokenType)
    result.add(0)
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
              "tokenTypes": ["keyword", "string", "comment",
                             "type", "property", "operator", "macro"],
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
      let tokens = tokenizeHtml(text)
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
      let tokens = tokenizeHtmlRange(text, startLine, endLine)
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
