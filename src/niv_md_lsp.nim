## niv_md_lsp — minimal Markdown Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  MdTokenKind = enum
    mtKeyword      # # markers, **, *, `, !, fences
    mtString       # inline code content, fenced code content
    mtComment      # HTML comments <!-- -->
    mtProperty     # link text [text], image alt ![alt]
    mtOperator     # - * + list markers, > blockquote, --- hr
    mtHeading      # heading text (after #)
    mtFunction     # link/image URLs (url)
    mtMacro        # fenced code language identifier
    mtNamespace    # frontmatter content

  MdToken = object
    kind: MdTokenKind
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
  stProperty = 3
  stOperator = 4
  stHeading = 5
  stFunction = 6
  stMacro = 7
  stNamespace = 8

# ---------------------------------------------------------------------------
# Markdown Tokenizer
# ---------------------------------------------------------------------------

proc isHorizontalRule(line: string, pos: int): bool =
  ## Check if line from pos is a horizontal rule: 3+ of same char (- * _)
  ## with optional spaces between
  if pos >= line.len: return false
  let ch = line[pos]
  if ch notin {'-', '*', '_'}: return false
  var count = 0
  var i = pos
  while i < line.len:
    if line[i] == ch:
      inc count
    elif line[i] != ' ':
      return false
    inc i
  return count >= 3

proc tokenizeMd(text: string): seq[MdToken] =
  var tokens: seq[MdToken]
  let lines = text.split('\n')
  var inFencedCode = false
  var fenceChar = ' '
  var fenceLen = 0
  var fenceIndent = 0
  var inHtmlComment = false
  var inFrontmatter = false
  var frontmatterDone = false
  var lineIndex = 0

  for lineNum in 0..<lines.len:
    let line = lines[lineNum]
    inc lineIndex

    # Multi-line HTML comment continuation
    if inHtmlComment:
      let closePos = line.find("-->")
      if closePos >= 0:
        tokens.add(MdToken(kind: mtComment, line: lineNum, col: 0,
                           length: closePos + 3))
        inHtmlComment = false
      else:
        if line.len > 0:
          tokens.add(MdToken(kind: mtComment, line: lineNum, col: 0,
                             length: line.len))
      continue

    # Frontmatter: YAML block between --- at start of file
    if lineNum == 0 and not frontmatterDone and line.strip() == "---":
      inFrontmatter = true
      tokens.add(MdToken(kind: mtNamespace, line: lineNum, col: 0,
                         length: line.len))
      continue

    if inFrontmatter:
      if line.strip() == "---" or line.strip() == "...":
        tokens.add(MdToken(kind: mtNamespace, line: lineNum, col: 0,
                           length: line.len))
        inFrontmatter = false
        frontmatterDone = true
      else:
        if line.len > 0:
          tokens.add(MdToken(kind: mtNamespace, line: lineNum, col: 0,
                             length: line.len))
      continue

    if not inFrontmatter:
      frontmatterDone = true

    # Fenced code block
    if inFencedCode:
      # Check for closing fence
      var indent = 0
      var i = 0
      while i < line.len and line[i] == ' ':
        inc indent
        inc i
      if i < line.len and line[i] == fenceChar:
        var count = 0
        let fenceStart = i
        while i < line.len and line[i] == fenceChar:
          inc count
          inc i
        # Rest must be whitespace only
        var onlyWs = true
        while i < line.len:
          if line[i] notin {' ', '\t'}:
            onlyWs = false
            break
          inc i
        if count >= fenceLen and onlyWs:
          tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: fenceStart,
                             length: count))
          inFencedCode = false
          continue
      # Code content line
      if line.len > 0:
        tokens.add(MdToken(kind: mtString, line: lineNum, col: 0,
                           length: line.len))
      continue

    # Check for fenced code block opening
    block checkFence:
      var indent = 0
      var i = 0
      while i < line.len and line[i] == ' ' and indent < 4:
        inc indent
        inc i
      if i < line.len and line[i] in {'`', '~'}:
        let fc = line[i]
        let fenceStart = i
        var count = 0
        while i < line.len and line[i] == fc:
          inc count
          inc i
        if count >= 3:
          # Opening fence found
          tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: fenceStart,
                             length: count))
          # Language identifier
          var langStart = i
          while langStart < line.len and line[langStart] == ' ':
            inc langStart
          if langStart < line.len:
            var langEnd = langStart
            while langEnd < line.len and line[langEnd] notin {' ', '\t'}:
              inc langEnd
            if langEnd > langStart:
              tokens.add(MdToken(kind: mtMacro, line: lineNum, col: langStart,
                                 length: langEnd - langStart))
          inFencedCode = true
          fenceChar = fc
          fenceLen = count
          fenceIndent = indent
          continue

    var pos = 0

    # Measure leading whitespace
    var indent = 0
    while pos < line.len and line[pos] == ' ':
      inc pos
      inc indent

    if pos >= line.len:
      continue

    # Blockquote marker >
    if line[pos] == '>':
      tokens.add(MdToken(kind: mtOperator, line: lineNum, col: pos, length: 1))
      inc pos
      if pos < line.len and line[pos] == ' ': inc pos
      # Continue parsing the rest of the line after >

    # Heading # ... ######
    if pos < line.len and line[pos] == '#':
      let hStart = pos
      var level = 0
      while pos < line.len and line[pos] == '#' and level < 6:
        inc pos
        inc level
      if pos >= line.len or line[pos] == ' ':
        tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: hStart,
                           length: level))
        if pos < line.len and line[pos] == ' ': inc pos
        # Heading text
        if pos < line.len:
          # Trim trailing # markers
          var textEnd = line.len
          var te = textEnd - 1
          while te > pos and line[te] == '#': dec te
          while te > pos and line[te] == ' ': dec te
          textEnd = te + 1
          if textEnd > pos:
            tokens.add(MdToken(kind: mtHeading, line: lineNum, col: pos,
                               length: textEnd - pos))
        continue

    # Horizontal rule: --- *** ___
    if indent < 4 and pos < line.len and isHorizontalRule(line, pos):
      tokens.add(MdToken(kind: mtOperator, line: lineNum, col: pos,
                         length: line.len - pos))
      continue

    # List markers: - * + followed by space
    if pos < line.len and line[pos] in {'-', '*', '+'} and
       pos + 1 < line.len and line[pos + 1] == ' ':
      tokens.add(MdToken(kind: mtOperator, line: lineNum, col: pos, length: 1))
      pos += 2
      # Continue to parse inline content after list marker

    # Numbered list: digits followed by . or ) and space
    if pos < line.len and line[pos] in {'0'..'9'}:
      var numEnd = pos
      while numEnd < line.len and line[numEnd] in {'0'..'9'}:
        inc numEnd
      if numEnd < line.len and line[numEnd] in {'.', ')'} and
         numEnd + 1 < line.len and line[numEnd + 1] == ' ':
        tokens.add(MdToken(kind: mtOperator, line: lineNum, col: pos,
                           length: numEnd - pos + 1))
        pos = numEnd + 2

    # Inline content parsing
    while pos < line.len:
      let c = line[pos]

      # HTML comment <!-- ... -->
      if c == '<' and pos + 3 < line.len and line[pos..pos+3] == "<!--":
        let commentStart = pos
        let closePos = line.find("-->", pos + 4)
        if closePos >= 0:
          tokens.add(MdToken(kind: mtComment, line: lineNum, col: commentStart,
                             length: closePos + 3 - commentStart))
          pos = closePos + 3
        else:
          tokens.add(MdToken(kind: mtComment, line: lineNum, col: commentStart,
                             length: line.len - commentStart))
          inHtmlComment = true
          break
        continue

      # Inline code `...`
      if c == '`':
        let tickStart = pos
        var tickLen = 0
        while pos < line.len and line[pos] == '`':
          inc pos
          inc tickLen
        # Find closing backticks of same length
        var found = false
        var searchPos = pos
        while searchPos <= line.len - tickLen:
          if line[searchPos] == '`':
            var closeLen = 0
            var cp = searchPos
            while cp < line.len and line[cp] == '`':
              inc closeLen
              inc cp
            if closeLen == tickLen:
              # Opening backticks
              tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: tickStart,
                                 length: tickLen))
              # Code content
              if searchPos > pos:
                tokens.add(MdToken(kind: mtString, line: lineNum, col: pos,
                                   length: searchPos - pos))
              # Closing backticks
              tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: searchPos,
                                 length: tickLen))
              pos = cp
              found = true
              break
            else:
              searchPos = cp
          else:
            inc searchPos
        if not found:
          pos = tickStart + tickLen
        continue

      # Image ![alt](url)
      if c == '!' and pos + 1 < line.len and line[pos + 1] == '[':
        let imgStart = pos
        tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: pos, length: 1))
        inc pos # skip !
        # [alt]
        if pos < line.len and line[pos] == '[':
          let bracketStart = pos
          inc pos
          let altStart = pos
          var depth = 1
          while pos < line.len and depth > 0:
            if line[pos] == '[': inc depth
            elif line[pos] == ']': dec depth
            if depth > 0: inc pos
          if depth == 0:
            if pos > altStart:
              tokens.add(MdToken(kind: mtProperty, line: lineNum, col: altStart,
                                 length: pos - altStart))
            inc pos # skip ]
            # (url)
            if pos < line.len and line[pos] == '(':
              inc pos
              let urlStart = pos
              var pDepth = 1
              while pos < line.len and pDepth > 0:
                if line[pos] == '(': inc pDepth
                elif line[pos] == ')': dec pDepth
                if pDepth > 0: inc pos
              if pDepth == 0:
                if pos > urlStart:
                  tokens.add(MdToken(kind: mtFunction, line: lineNum, col: urlStart,
                                     length: pos - urlStart))
                inc pos # skip )
          continue
        continue

      # Link [text](url)
      if c == '[':
        let bracketStart = pos
        inc pos
        let textStart = pos
        var depth = 1
        while pos < line.len and depth > 0:
          if line[pos] == '[': inc depth
          elif line[pos] == ']': dec depth
          if depth > 0: inc pos
        if depth == 0:
          let textEnd = pos
          inc pos # skip ]
          if pos < line.len and line[pos] == '(':
            # It's a link
            if textEnd > textStart:
              tokens.add(MdToken(kind: mtProperty, line: lineNum, col: textStart,
                                 length: textEnd - textStart))
            inc pos # skip (
            let urlStart = pos
            var pDepth = 1
            while pos < line.len and pDepth > 0:
              if line[pos] == '(': inc pDepth
              elif line[pos] == ')': dec pDepth
              if pDepth > 0: inc pos
            if pDepth == 0:
              if pos > urlStart:
                tokens.add(MdToken(kind: mtFunction, line: lineNum, col: urlStart,
                                   length: pos - urlStart))
              inc pos # skip )
            continue
          else:
            # Not a link, just text in brackets - skip
            pos = bracketStart + 1
            continue
        else:
          pos = bracketStart + 1
          continue

      # Bold ** or __
      if (c == '*' and pos + 1 < line.len and line[pos + 1] == '*') or
         (c == '_' and pos + 1 < line.len and line[pos + 1] == '_'):
        let marker = line[pos..pos+1]
        tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: pos, length: 2))
        pos += 2
        # Find closing marker
        let closePos = line.find(marker, pos)
        if closePos > pos:
          tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: closePos,
                             length: 2))
          pos = closePos + 2
        continue

      # Italic * or _  (single, not followed by same char)
      if c in {'*', '_'} and pos + 1 < line.len and line[pos + 1] != c:
        tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: pos, length: 1))
        inc pos
        # Find closing marker (same char, not preceded by backslash)
        var fp = pos
        while fp < line.len:
          if line[fp] == c and (fp == 0 or line[fp - 1] != '\\'):
            tokens.add(MdToken(kind: mtKeyword, line: lineNum, col: fp, length: 1))
            pos = fp + 1
            break
          inc fp
        if fp >= line.len:
          discard # no closing marker found, continue
        continue

      inc pos

  return tokens

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizeMdRange(text: string, startLine, endLine: int): seq[MdToken] =
  let allTokens = tokenizeMd(text)
  result = @[]
  for tok in allTokens:
    if tok.line >= startLine and tok.line <= endLine:
      result.add(tok)

# ---------------------------------------------------------------------------
# Semantic Token Encoding (LSP delta encoding)
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[MdToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of mtKeyword: stKeyword
      of mtString: stString
      of mtComment: stComment
      of mtProperty: stProperty
      of mtOperator: stOperator
      of mtHeading: stHeading
      of mtFunction: stFunction
      of mtMacro: stMacro
      of mtNamespace: stNamespace
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
              "tokenTypes": ["keyword", "string", "comment", "property",
                             "operator", "heading", "function", "macro", "namespace"],
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
      let tokens = tokenizeMd(text)
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
      let tokens = tokenizeMdRange(text, startLine, endLine)
      let data = encodeSemanticTokens(tokens)
      sendTokensResponse(id, data)

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
