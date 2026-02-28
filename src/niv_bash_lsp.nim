## niv_bash_lsp — minimal Bash/Shell Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils, sets, tables]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  BashTokenKind = enum
    btKeyword      # if, then, else, fi, for, do, done, while, case, esac, ...
    btString       # "double", 'single', $'ansi-c'
    btNumber       # numeric literals
    btComment      # # comment
    btFunction     # function definitions
    btParameter    # $VAR, ${VAR}, $1, $@, $?, $$
    btOperator     # |, ||, &&, ;, ;;, >, >>, <, <<, &
    btMacro        # command substitution $(...)
    btNamespace    # shebang #!/bin/bash

  BashToken = object
    kind: BashTokenKind
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
  stNumber = 2
  stComment = 3
  stFunction = 4
  stParameter = 5
  stOperator = 6
  stMacro = 7
  stNamespace = 8

const bashKeywords = [
  "if", "then", "else", "elif", "fi",
  "for", "do", "done", "while", "until",
  "case", "esac", "in", "select",
  "function", "return", "exit",
  "local", "export", "readonly", "declare", "typeset",
  "unset", "unsetenv",
  "source", "eval", "exec",
  "set", "shift", "trap",
  "break", "continue",
  "true", "false",
]

var bashKeywordSet: HashSet[string]

proc initLookupSets() =
  for kw in bashKeywords: bashKeywordSet.incl(kw)

# ---------------------------------------------------------------------------
# Bash Tokenizer
# ---------------------------------------------------------------------------

proc isWordChar(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '0'..'9', '_'}

proc isDigit(c: char): bool =
  c in {'0'..'9'}

proc tokenizeBash(text: string): seq[BashToken] =
  var tokens: seq[BashToken]
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

  template skipSpaces() =
    while pos < text.len and text[pos] in {' ', '\t'}:
      advance()

  # Track if we're at the start of a command (for function detection)
  var afterNewline = true

  while pos < text.len:
    let c = ch()

    # Newline
    if c == '\n':
      afterNewline = true
      advance()
      continue

    # Whitespace
    if c in {' ', '\t'}:
      advance()
      continue

    # Shebang (first line only)
    if c == '#' and peek(1) == '!' and line == 0 and col == 0:
      let sCol = col
      let sLine = line
      while pos < text.len and text[pos] != '\n':
        advance()
      tokens.add(BashToken(kind: btNamespace, line: sLine, col: sCol,
                           length: col - sCol))
      continue

    # Comment
    if c == '#':
      let sCol = col
      let sLine = line
      while pos < text.len and text[pos] != '\n':
        advance()
      tokens.add(BashToken(kind: btComment, line: sLine, col: sCol,
                           length: col - sCol))
      continue

    # Here-doc operator << or <<-
    if c == '<' and peek(1) == '<':
      let sCol = col
      let sLine = line
      advance(); advance() # skip <<
      if pos < text.len and text[pos] == '-':
        advance() # skip -
      tokens.add(BashToken(kind: btOperator, line: sLine, col: sCol,
                           length: col - sCol))
      # Read delimiter
      skipSpaces()
      var stripQuotes = false
      var delimiter = ""
      if pos < text.len and text[pos] in {'"', '\''}:
        stripQuotes = true
        let q = text[pos]
        advance()
        while pos < text.len and text[pos] != q and text[pos] != '\n':
          delimiter.add(text[pos])
          advance()
        if pos < text.len and text[pos] == q: advance()
      else:
        while pos < text.len and text[pos] notin {' ', '\t', '\n', ';'}:
          delimiter.add(text[pos])
          advance()
      # Read here-doc body until delimiter on its own line
      if delimiter.len > 0:
        # Skip to next line
        while pos < text.len and text[pos] != '\n': advance()
        if pos < text.len: advance() # skip \n
        while pos < text.len:
          # Check if this line is the delimiter
          let lineStart = pos
          let lineStartLine = line
          let lineStartCol = col
          var currentLine = ""
          while pos < text.len and text[pos] != '\n':
            currentLine.add(text[pos])
            advance()
          if currentLine.strip() == delimiter:
            break
          else:
            if currentLine.len > 0:
              tokens.add(BashToken(kind: btString, line: lineStartLine,
                                   col: lineStartCol, length: currentLine.len))
          if pos < text.len: advance() # skip \n
      afterNewline = false
      continue

    # Double-quoted string "..."
    if c == '"':
      let sCol = col
      let sLine = line
      advance() # skip opening "
      while pos < text.len and text[pos] != '"':
        if text[pos] == '\\':
          advance()
          if pos < text.len: advance()
        elif text[pos] == '$':
          # Variable inside string - emit string part up to here, then variable
          let strEnd = col
          if strEnd > sCol + 1:
            discard # part of the string, we'll emit the whole string at the end
          # For simplicity, treat entire double-quoted string as one token
          advance()
        elif text[pos] == '\n':
          advance()
        else:
          advance()
      if pos < text.len: advance() # skip closing "
      tokens.add(BashToken(kind: btString, line: sLine, col: sCol,
                           length: if sLine == line: col - sCol
                                   else: 1)) # multi-line: just mark start
      # For multi-line strings, emit per-line tokens
      if sLine != line:
        tokens[^1].length = 0 # remove the bad token
        tokens.setLen(tokens.len - 1)
        # Re-scan for per-line emission
        var p = pos - 1
        while p > 0 and text[p] != '"': dec p
        # Just emit entire string on start line as approximation
        let endOfFirstLine = text.find('\n', sCol)
        if endOfFirstLine > 0:
          discard # skip multi-line string token emission for simplicity
      afterNewline = false
      continue

    # Single-quoted string '...'
    if c == '\'':
      let sCol = col
      let sLine = line
      advance() # skip opening '
      while pos < text.len and text[pos] != '\'':
        if text[pos] == '\n':
          advance()
        else:
          advance()
      if pos < text.len: advance() # skip closing '
      if sLine == line:
        tokens.add(BashToken(kind: btString, line: sLine, col: sCol,
                             length: col - sCol))
      afterNewline = false
      continue

    # ANSI-C string $'...'
    if c == '$' and peek(1) == '\'':
      let sCol = col
      let sLine = line
      advance(); advance() # skip $'
      while pos < text.len and text[pos] != '\'':
        if text[pos] == '\\' and pos + 1 < text.len:
          advance()
        advance()
      if pos < text.len: advance() # skip closing '
      tokens.add(BashToken(kind: btString, line: sLine, col: sCol,
                           length: col - sCol))
      afterNewline = false
      continue

    # Command substitution $(...)
    if c == '$' and peek(1) == '(':
      let sCol = col
      let sLine = line
      advance(); advance() # skip $(
      var depth = 1
      while pos < text.len and depth > 0:
        if text[pos] == '(' and text[pos - 1] == '$': inc depth
        elif text[pos] == ')': dec depth
        if depth > 0: advance()
      if pos < text.len: advance() # skip closing )
      tokens.add(BashToken(kind: btMacro, line: sLine, col: sCol,
                           length: if sLine == line: col - sCol else: 2))
      afterNewline = false
      continue

    # Variable ${...}
    if c == '$' and peek(1) == '{':
      let sCol = col
      let sLine = line
      advance(); advance() # skip ${
      while pos < text.len and text[pos] != '}' and text[pos] != '\n':
        advance()
      if pos < text.len and text[pos] == '}': advance()
      tokens.add(BashToken(kind: btParameter, line: sLine, col: sCol,
                           length: col - sCol))
      afterNewline = false
      continue

    # Variable $name or $special
    if c == '$':
      let sCol = col
      let sLine = line
      advance() # skip $
      if pos < text.len:
        if text[pos] in {'@', '*', '#', '?', '-', '$', '!', '0'..'9'}:
          advance()
        elif isWordChar(text[pos]):
          while pos < text.len and isWordChar(text[pos]):
            advance()
      tokens.add(BashToken(kind: btParameter, line: sLine, col: sCol,
                           length: col - sCol))
      afterNewline = false
      continue

    # Backtick command substitution `...`
    if c == '`':
      let sCol = col
      let sLine = line
      advance() # skip opening `
      while pos < text.len and text[pos] != '`':
        if text[pos] == '\\': advance()
        if pos < text.len: advance()
      if pos < text.len: advance() # skip closing `
      tokens.add(BashToken(kind: btMacro, line: sLine, col: sCol,
                           length: if sLine == line: col - sCol else: 1))
      afterNewline = false
      continue

    # Operators: ||, &&, ;;, >>, <<, |, &, ;, >, <, =
    if c in {'|', '&', ';', '>', '<'}:
      let sCol = col
      let sLine = line
      let nc = peek(1)
      if (c == '|' and nc == '|') or (c == '&' and nc == '&') or
         (c == ';' and nc == ';') or (c == '>' and nc == '>'):
        advance(); advance()
        tokens.add(BashToken(kind: btOperator, line: sLine, col: sCol, length: 2))
      else:
        advance()
        tokens.add(BashToken(kind: btOperator, line: sLine, col: sCol, length: 1))
      afterNewline = false
      continue

    # Parentheses and braces as operators
    if c in {'(', ')', '{', '}'}:
      advance()
      afterNewline = false
      continue

    # = assignment
    if c == '=':
      let sCol = col
      advance()
      tokens.add(BashToken(kind: btOperator, line: line, col: sCol, length: 1))
      afterNewline = false
      continue

    # Word (keyword, function name, or command)
    if isWordChar(c) or c == '/' or c == '.' or c == '-':
      let sCol = col
      let sLine = line
      let sPos = pos
      while pos < text.len and (isWordChar(text[pos]) or
            text[pos] in {'/', '.', '-', ':', '+', '@'}):
        advance()

      let word = text[sPos..<pos]

      # Check if this is a function definition: word()
      skipSpaces()
      if pos < text.len and text[pos] == '(' and peek(1) == ')':
        tokens.add(BashToken(kind: btFunction, line: sLine, col: sCol,
                             length: word.len))
        advance(); advance() # skip ()
        afterNewline = false
        continue

      # Check if keyword
      let isKw = word in bashKeywordSet

      if isKw:
        tokens.add(BashToken(kind: btKeyword, line: sLine, col: sCol,
                             length: word.len))
        # After "function" keyword, next word is function name
        if word == "function":
          skipSpaces()
          if pos < text.len and isWordChar(text[pos]):
            let fnCol = col
            let fnLine = line
            let fnPos = pos
            while pos < text.len and isWordChar(text[pos]):
              advance()
            tokens.add(BashToken(kind: btFunction, line: fnLine, col: fnCol,
                                 length: pos - fnPos))
      else:
        # Check if it's a pure number
        var allDigits = true
        for ch in word:
          if not isDigit(ch):
            allDigits = false
            break
        if allDigits and word.len > 0:
          tokens.add(BashToken(kind: btNumber, line: sLine, col: sCol,
                               length: word.len))

      afterNewline = false
      continue

    # Skip unknown characters
    advance()
    afterNewline = false

  return tokens

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizeBashRange(text: string, startLine, endLine: int): seq[BashToken] =
  let allTokens = tokenizeBash(text)
  result = @[]
  for tok in allTokens:
    if tok.line >= startLine and tok.line <= endLine:
      result.add(tok)

# ---------------------------------------------------------------------------
# Semantic Token Encoding (LSP delta encoding)
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[BashToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    if tok.length <= 0: continue
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of btKeyword: stKeyword
      of btString: stString
      of btNumber: stNumber
      of btComment: stComment
      of btFunction: stFunction
      of btParameter: stParameter
      of btOperator: stOperator
      of btMacro: stMacro
      of btNamespace: stNamespace
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
  initLookupSets()
  var documents: Table[string, DocumentState]
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
                             "function", "parameter", "operator", "macro",
                             "namespace"],
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
      documents[uri] = DocumentState(uri: uri, text: text, version: version)

    of "textDocument/didChange":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let version = params["textDocument"]["version"].getInt()
      let changes = params["contentChanges"]
      if changes.len > 0:
        let newText = changes[0]["text"].getStr()
        if uri in documents:
          documents[uri].text = newText
          documents[uri].version = version

    of "textDocument/didClose":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      documents.del(uri)

    of "textDocument/semanticTokens/full":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      let text = if uri in documents: documents[uri].text else: ""
      let tokens = tokenizeBash(text)
      let data = encodeSemanticTokens(tokens)
      sendTokensResponse(id, data)

    of "textDocument/semanticTokens/range":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let rangeNode = params["range"]
      let startLine = rangeNode["start"]["line"].getInt()
      let endLine = rangeNode["end"]["line"].getInt()
      let text = if uri in documents: documents[uri].text else: ""
      let tokens = tokenizeBashRange(text, startLine, endLine)
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
