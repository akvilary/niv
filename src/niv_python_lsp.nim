## niv_python_lsp — Python Language Server with semantic tokens & go-to-definition
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing
##
## Features:
##   - 17 semantic token types (keyword, string, number, comment, function, method,
##     class, decorator, builtin, operator, type, parameter, selfParameter,
##     clsParameter, property, namespace, builtinConstant)
##   - Indent-based scope tracking for context-aware tokenization
##   - Go-to-definition with import resolution and inheritance chain (MRO)
##   - Basic diagnostics (unterminated strings)

import std/[json, strutils, os, tables, osproc, sets]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  PythonTokenKind = enum
    ptKeyword        # 0  - if, else, def, class, return, import, ...
    ptString         # 1  - "...", '...', f"..."
    ptNumber         # 2  - 42, 3.14, 0xFF
    ptComment        # 3  - # ...
    ptFunction       # 4  - name after def (top-level), function calls
    ptMethod         # 5  - name after def inside class
    ptClass          # 6  - name after class
    ptDecorator      # 7  - @decorator
    ptBuiltin        # 8  - print, len, range, ...
    ptOperator       # 9  - =, +, and, or, not, in, is
    ptType           # 10 - int, str, float, dict, ...
    ptParameter      # 11 - function parameters
    ptSelfParam      # 12 - self in parameters
    ptClsParam       # 13 - cls in parameters
    ptProperty       # 14 - obj.attr (after dot)
    ptNamespace      # 15 - module name in import/from
    ptBuiltinConst   # 16 - True, False, None

  PythonToken = object
    kind: PythonTokenKind
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
  stKeyword = 0
  stString = 1
  stNumber = 2
  stComment = 3
  stFunction = 4
  stMethod = 5
  stClass = 6
  stDecorator = 7   # "macro" in LSP legend
  stBuiltin = 8     # "variable" in LSP legend
  stOperator = 9
  stType = 10
  stParameter = 11
  stSelfParam = 12
  stClsParam = 13
  stProperty = 14
  stNamespace = 15
  stBuiltinConst = 16

# ---------------------------------------------------------------------------
# Scope tracking for context-aware tokenization
# ---------------------------------------------------------------------------

type
  ScopeKind = enum
    skModule, skClass, skFunction

  ScopeEntry = object
    kind: ScopeKind
    indent: int

# ---------------------------------------------------------------------------
# Python language data
# ---------------------------------------------------------------------------

const pythonKeywords = [
  "as", "assert", "async", "await", "break", "class", "continue",
  "def", "del", "elif", "else", "except", "finally", "for", "from",
  "global", "if", "import", "lambda", "nonlocal", "pass", "raise",
  "return", "try", "while", "with", "yield",
]

const pythonKeywordOperators = ["and", "or", "not", "in", "is"]

const pythonBuiltinConstants = ["True", "False", "None"]

const pythonBuiltinTypes = [
  "int", "str", "float", "list", "dict", "set", "tuple", "bool",
  "bytes", "bytearray", "memoryview", "complex", "frozenset", "object",
]

const pythonBuiltinFunctions = [
  "print", "len", "range", "type", "isinstance", "issubclass",
  "abs", "all", "any", "ascii", "bin", "breakpoint", "callable",
  "chr", "classmethod", "compile", "delattr", "dir", "divmod",
  "enumerate", "eval", "exec", "filter", "format", "getattr",
  "globals", "hasattr", "hash", "help", "hex", "id", "input",
  "iter", "locals", "map", "max", "min", "next",
  "oct", "open", "ord", "pow", "property", "repr", "reversed",
  "round", "setattr", "slice", "sorted", "staticmethod", "sum",
  "super", "vars", "zip", "__import__",
]

# Precomputed lookup sets for O(1) classification
var keywordSet: HashSet[string]
var kwOperatorSet: HashSet[string]
var builtinConstSet: HashSet[string]
var builtinTypeSet: HashSet[string]
var builtinFuncSet: HashSet[string]

proc initLookupTables() =
  for kw in pythonKeywords: keywordSet.incl(kw)
  for kw in pythonKeywordOperators: kwOperatorSet.incl(kw)
  for kw in pythonBuiltinConstants: builtinConstSet.incl(kw)
  for kw in pythonBuiltinTypes: builtinTypeSet.incl(kw)
  for kw in pythonBuiltinFunctions: builtinFuncSet.incl(kw)

# ---------------------------------------------------------------------------
# Multi-line string token splitting
# ---------------------------------------------------------------------------

proc emitStringTokens(tokens: var seq[PythonToken], text: string,
                      textStart, textEnd: int,
                      startLine, startCol: int, endLine: int,
                      rangeStart: int = -1, rangeEnd: int = -1) =
  ## Emit per-line string tokens. For multi-line strings, creates one token per line.
  ## If rangeStart/rangeEnd >= 0, only emit tokens within that line range.
  let inRange = rangeStart < 0  # no range filtering
  if startLine == endLine:
    if inRange or (startLine >= rangeStart and startLine <= rangeEnd):
      tokens.add(PythonToken(kind: ptString, line: startLine, col: startCol,
                             length: textEnd - textStart))
  else:
    var p = textStart
    var curLine = startLine
    while p < textEnd:
      let tokenCol = if curLine == startLine: startCol else: 0
      var lineLen = 0
      while p + lineLen < textEnd and text[p + lineLen] != '\n':
        inc lineLen
      if inRange or (curLine >= rangeStart and curLine <= rangeEnd):
        tokens.add(PythonToken(kind: ptString, line: curLine, col: tokenCol,
                               length: lineLen))
      p += lineLen
      if p < textEnd and text[p] == '\n':
        inc p
      inc curLine

# ---------------------------------------------------------------------------
# Python Tokenizer + Diagnostics (with context tracking)
# ---------------------------------------------------------------------------

proc tokenizePython(text: string, startLine: int = 0, endLine: int = int.high): (seq[PythonToken], seq[DiagInfo]) =
  var tokens: seq[PythonToken]
  var diags: seq[DiagInfo]
  var pos = 0
  var line = 0
  var col = 0
  var lastKeyword = ""  # Track "def"/"class" for next identifier

  # Scope tracking
  var scopeStack: seq[ScopeEntry] = @[ScopeEntry(kind: skModule, indent: -1)]
  var lineIndent = 0
  var atLineStart = true

  # Function parameter tracking
  var inFuncParams = false
  var funcParamDepth = 0
  var isFirstParam = true
  var afterParamColon = false
  var expectParam = false  # after * or ** prefix

  # Import tracking: detect 'import' and 'from' lines
  var inImportLine = false  # after 'import' keyword
  var inFromLine = false    # after 'from' keyword, before 'import'
  var afterDot = false      # identifier after a dot

  proc isIdentChar(c: char): bool =
    c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

  template ch(): char =
    if pos < text.len: text[pos] else: '\0'

  template advance() =
    if pos < text.len:
      if text[pos] == '\n':
        inc line
        col = 0
        atLineStart = true
        lineIndent = 0
        lastKeyword = ""
        inImportLine = false
        inFromLine = false
        afterDot = false
        # Don't reset inFuncParams - params can span lines
      else:
        inc col
      inc pos

  template skipWhitespace() =
    while pos < text.len and text[pos] in {' ', '\t', '\r', '\n'}:
      if atLineStart and text[pos] in {' ', '\t'}:
        if text[pos] == '\t': lineIndent += 4
        else: inc lineIndent
      advance()
    # Apply scope popping when we reach content on a new line
    if atLineStart:
      atLineStart = false
      if not inFuncParams:
        while scopeStack.len > 1 and scopeStack[^1].indent >= lineIndent:
          scopeStack.setLen(scopeStack.len - 1)

  proc inClassScope(): bool =
    for i in countdown(scopeStack.len - 1, 0):
      if scopeStack[i].kind == skClass:
        return true
      if scopeStack[i].kind == skFunction:
        return false  # function scope hides class
    return false

  # Read a string (single or triple quoted)
  proc readString(quoteChar: char, isRaw: bool): (int, int, int, bool) =
    let sLine = line
    let sCol = col
    var length = 0
    let isTriple = pos + 2 < text.len and text[pos + 1] == quoteChar and text[pos + 2] == quoteChar
    if isTriple:
      for _ in 0..<3:
        advance(); inc length
      while pos < text.len:
        if text[pos] == '\\' and not isRaw:
          advance(); inc length
          if pos < text.len: advance(); inc length
        elif text[pos] == quoteChar and pos + 2 < text.len and
             text[pos + 1] == quoteChar and text[pos + 2] == quoteChar:
          for _ in 0..<3: advance(); inc length
          return (sLine, sCol, length, true)
        else:
          advance(); inc length
      diags.add(DiagInfo(line: sLine, col: sCol, endCol: sCol + min(length, 3),
                         message: "Unterminated triple-quoted string"))
      return (sLine, sCol, length, false)
    else:
      advance(); inc length  # skip opening quote
      while pos < text.len:
        let c = text[pos]
        if c == '\\' and not isRaw:
          advance(); inc length
          if pos < text.len: advance(); inc length
        elif c == quoteChar:
          advance(); inc length
          return (sLine, sCol, length, true)
        elif c == '\n':
          diags.add(DiagInfo(line: sLine, col: sCol, endCol: sCol + length,
                             message: "Unterminated string"))
          return (sLine, sCol, length, false)
        else:
          advance(); inc length
      diags.add(DiagInfo(line: sLine, col: sCol, endCol: sCol + length,
                         message: "Unterminated string"))
      return (sLine, sCol, length, false)

  while pos < text.len:
    skipWhitespace()
    if pos >= text.len: break
    if line > endLine and not inFuncParams: break
    let c = ch()

    case c
    # Comments
    of '#':
      let sLine = line
      let sCol = col
      var length = 0
      while pos < text.len and text[pos] != '\n':
        advance(); inc length
      tokens.add(PythonToken(kind: ptComment, line: sLine, col: sCol, length: length))

    # String prefixes or identifiers
    of 'a'..'z', 'A'..'Z', '_':
      let sLine = line
      let sCol = col
      let startPos = pos
      let wasDot = afterDot
      afterDot = false

      # Check for string prefix
      var isStringPrefix = false
      var isRaw = false
      if c in {'f', 'F', 'r', 'R', 'b', 'B', 'u', 'U'}:
        var prefixLen = 1
        var nextPos = pos + 1
        if nextPos < text.len and text[nextPos] in {'f', 'F', 'r', 'R', 'b', 'B'}:
          let pair = ($c & $text[nextPos]).toLowerAscii()
          if pair in ["rf", "fr", "rb", "br"]:
            prefixLen = 2; inc nextPos
        if nextPos < text.len and text[nextPos] in {'\'', '"'}:
          isStringPrefix = true
          isRaw = c in {'r', 'R'} or (prefixLen == 2 and (text[pos + 1] in {'r', 'R'} or c in {'r', 'R'}))
          for _ in 0..<prefixLen: advance()
          let quoteChar = text[pos]
          let (_, _, strLen, _) = readString(quoteChar, isRaw)
          emitStringTokens(tokens, text, startPos, pos, sLine, sCol, line)

      if not isStringPrefix:
        # Read identifier
        while pos < text.len and isIdentChar(text[pos]):
          advance()
        let word = text[startPos..<pos]
        let length = pos - startPos

        # Classify the identifier
        if word == "def" or word == "class":
          tokens.add(PythonToken(kind: ptKeyword, line: sLine, col: sCol, length: length))
          lastKeyword = word
        elif word == "import":
          tokens.add(PythonToken(kind: ptKeyword, line: sLine, col: sCol, length: length))
          if inFromLine:
            inFromLine = false
            inImportLine = true
          else:
            inImportLine = true
          lastKeyword = ""
        elif word == "from":
          tokens.add(PythonToken(kind: ptKeyword, line: sLine, col: sCol, length: length))
          inFromLine = true
          lastKeyword = ""
        elif lastKeyword == "def":
          # Function/method name
          let isMethod = inClassScope()
          if isMethod:
            tokens.add(PythonToken(kind: ptMethod, line: sLine, col: sCol, length: length))
            scopeStack.add(ScopeEntry(kind: skFunction, indent: lineIndent))
          else:
            tokens.add(PythonToken(kind: ptFunction, line: sLine, col: sCol, length: length))
            scopeStack.add(ScopeEntry(kind: skFunction, indent: lineIndent))
          lastKeyword = ""
          # Prepare for parameter parsing
          inFuncParams = false  # will be set true when we see '('
          funcParamDepth = 0
          isFirstParam = true
          afterParamColon = false
          expectParam = false
        elif lastKeyword == "class":
          tokens.add(PythonToken(kind: ptClass, line: sLine, col: sCol, length: length))
          scopeStack.add(ScopeEntry(kind: skClass, indent: lineIndent))
          lastKeyword = ""
        elif inFuncParams and not afterParamColon:
          # Inside function parameter list
          if (word == "self") and isFirstParam:
            tokens.add(PythonToken(kind: ptSelfParam, line: sLine, col: sCol, length: length))
          elif (word == "cls") and isFirstParam:
            tokens.add(PythonToken(kind: ptClsParam, line: sLine, col: sCol, length: length))
          else:
            tokens.add(PythonToken(kind: ptParameter, line: sLine, col: sCol, length: length))
          expectParam = false
          isFirstParam = false
        elif inImportLine:
          # Module name after 'import'
          tokens.add(PythonToken(kind: ptNamespace, line: sLine, col: sCol, length: length))
        elif inFromLine:
          # Module name after 'from'
          tokens.add(PythonToken(kind: ptNamespace, line: sLine, col: sCol, length: length))
        elif wasDot:
          # Identifier after dot → property or method call
          # Lookahead for '(' to distinguish method call from property access
          var lookPos = pos
          while lookPos < text.len and text[lookPos] in {' ', '\t'}:
            inc lookPos
          if lookPos < text.len and text[lookPos] == '(':
            tokens.add(PythonToken(kind: ptFunction, line: sLine, col: sCol, length: length))
          else:
            tokens.add(PythonToken(kind: ptProperty, line: sLine, col: sCol, length: length))
        elif word in builtinConstSet:
          tokens.add(PythonToken(kind: ptBuiltinConst, line: sLine, col: sCol, length: length))
        elif word in kwOperatorSet:
          tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))
        elif word in keywordSet:
          tokens.add(PythonToken(kind: ptKeyword, line: sLine, col: sCol, length: length))
        elif word in builtinTypeSet:
          tokens.add(PythonToken(kind: ptType, line: sLine, col: sCol, length: length))
        elif word in builtinFuncSet:
          tokens.add(PythonToken(kind: ptBuiltin, line: sLine, col: sCol, length: length))
        else:
          # Lookahead: identifier followed by '(' → function call
          var lookPos = pos
          while lookPos < text.len and text[lookPos] in {' ', '\t'}:
            inc lookPos
          if lookPos < text.len and text[lookPos] == '(':
            tokens.add(PythonToken(kind: ptFunction, line: sLine, col: sCol, length: length))
          # else: plain variable, no token emitted
          lastKeyword = ""

    # Regular strings
    of '"', '\'':
      lastKeyword = ""
      afterDot = false
      let quoteChar = c
      let sLine = line
      let sCol = col
      let stringStartPos = pos
      let (_, _, length, _) = readString(quoteChar, false)
      emitStringTokens(tokens, text, stringStartPos, pos, sLine, sCol, line)

    # Numbers
    of '0'..'9':
      lastKeyword = ""
      afterDot = false
      let sLine = line
      let sCol = col
      var length = 0
      if c == '0' and pos + 1 < text.len and text[pos + 1] in {'x', 'X'}:
        advance(); advance(); length = 2
        while pos < text.len and text[pos] in {'0'..'9', 'a'..'f', 'A'..'F', '_'}:
          advance(); inc length
      elif c == '0' and pos + 1 < text.len and text[pos + 1] in {'o', 'O'}:
        advance(); advance(); length = 2
        while pos < text.len and text[pos] in {'0'..'7', '_'}:
          advance(); inc length
      elif c == '0' and pos + 1 < text.len and text[pos + 1] in {'b', 'B'}:
        advance(); advance(); length = 2
        while pos < text.len and text[pos] in {'0', '1', '_'}:
          advance(); inc length
      else:
        while pos < text.len and text[pos] in {'0'..'9', '_'}:
          advance(); inc length
        if pos < text.len and text[pos] == '.':
          advance(); inc length
          while pos < text.len and text[pos] in {'0'..'9', '_'}:
            advance(); inc length
        if pos < text.len and text[pos] in {'e', 'E'}:
          advance(); inc length
          if pos < text.len and text[pos] in {'+', '-'}:
            advance(); inc length
          while pos < text.len and text[pos] in {'0'..'9', '_'}:
            advance(); inc length
      if pos < text.len and text[pos] in {'j', 'J'}:
        advance(); inc length
      tokens.add(PythonToken(kind: ptNumber, line: sLine, col: sCol, length: length))

    # Dot — could start a float like .5 or be property access
    of '.':
      lastKeyword = ""
      if pos + 1 < text.len and text[pos + 1] in {'0'..'9'}:
        afterDot = false
        let sLine = line
        let sCol = col
        var length = 0
        advance(); inc length
        while pos < text.len and text[pos] in {'0'..'9', '_'}:
          advance(); inc length
        if pos < text.len and text[pos] in {'e', 'E'}:
          advance(); inc length
          if pos < text.len and text[pos] in {'+', '-'}:
            advance(); inc length
          while pos < text.len and text[pos] in {'0'..'9', '_'}:
            advance(); inc length
        if pos < text.len and text[pos] in {'j', 'J'}:
          advance(); inc length
        tokens.add(PythonToken(kind: ptNumber, line: sLine, col: sCol, length: length))
      else:
        afterDot = true
        advance()

    # Decorators
    of '@':
      lastKeyword = ""
      afterDot = false
      let sLine = line
      let sCol = col
      advance()
      var length = 1
      while pos < text.len and (isIdentChar(text[pos]) or text[pos] == '.'):
        advance(); inc length
      if length > 1:
        tokens.add(PythonToken(kind: ptDecorator, line: sLine, col: sCol, length: length))

    # Parentheses (track function params)
    of '(':
      lastKeyword = ""
      afterDot = false
      if inFuncParams:
        inc funcParamDepth
      elif funcParamDepth == 0 and tokens.len > 0 and
           tokens[^1].kind in {ptFunction, ptMethod}:
        # Just saw a function/method name, now opening params
        inFuncParams = true
        funcParamDepth = 1
        isFirstParam = true
        afterParamColon = false
        expectParam = false
      advance()
    of ')':
      lastKeyword = ""
      afterDot = false
      if inFuncParams:
        dec funcParamDepth
        if funcParamDepth <= 0:
          inFuncParams = false
          funcParamDepth = 0
      advance()

    # Comma in func params
    of ',':
      lastKeyword = ""
      afterDot = false
      if inFuncParams:
        afterParamColon = false
        expectParam = false
      advance()

    # Colon in func params (type annotation)
    of ':':
      lastKeyword = ""
      afterDot = false
      if inFuncParams and funcParamDepth == 1:
        afterParamColon = true
      advance()

    # Star / double star for *args, **kwargs
    of '*':
      lastKeyword = ""
      afterDot = false
      let sLine = line
      let sCol = col
      advance()
      var length = 1
      if pos < text.len and text[pos] == '*':
        advance(); inc length
        if pos < text.len and text[pos] == '=':
          advance(); inc length
      elif pos < text.len and text[pos] == '=':
        advance(); inc length
      if inFuncParams and funcParamDepth == 1:
        expectParam = true
        # Don't emit operator for * / ** in param list
      else:
        tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))

    # Operators
    of '=':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col
      advance(); var length = 1
      if pos < text.len and text[pos] == '=':
        advance(); inc length
      if inFuncParams and funcParamDepth == 1 and length == 1:
        # Default value assignment in params
        afterParamColon = true  # skip default value tokens as params
      else:
        tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))
    of '!':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col
      advance(); var length = 1
      if pos < text.len and text[pos] == '=':
        advance(); inc length
      tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))
    of '<':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col
      advance(); var length = 1
      if pos < text.len and text[pos] in {'=', '<'}:
        advance(); inc length
      tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))
    of '>':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col
      advance(); var length = 1
      if pos < text.len and text[pos] in {'=', '>'}:
        advance(); inc length
      tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))
    of '+', '%', '&', '|', '^', '~':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col
      advance(); var length = 1
      if pos < text.len and text[pos] == '=':
        advance(); inc length
      tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))
    of '-':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col
      advance(); var length = 1
      if pos < text.len and text[pos] == '>':
        advance(); inc length
      elif pos < text.len and text[pos] == '=':
        advance(); inc length
      tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))
    of '/':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col
      advance(); var length = 1
      if pos < text.len and text[pos] == '/':
        advance(); inc length
        if pos < text.len and text[pos] == '=':
          advance(); inc length
      elif pos < text.len and text[pos] == '=':
        advance(); inc length
      tokens.add(PythonToken(kind: ptOperator, line: sLine, col: sCol, length: length))

    # Brackets and other punctuation — skip
    of '[', ']', '{', '}', ';', '\\':
      lastKeyword = ""; afterDot = false
      advance()
    else:
      lastKeyword = ""; afterDot = false
      advance()

  if startLine > 0 and tokens.len > 0:
    var i = 0
    while i < tokens.len and tokens[i].line < startLine: inc i
    if i > 0: tokens = tokens[i..^1]
  return (tokens, diags)

# ---------------------------------------------------------------------------
# Semantic Token Encoding (LSP delta encoding)
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[PythonToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of ptKeyword: stKeyword
      of ptString: stString
      of ptNumber: stNumber
      of ptComment: stComment
      of ptFunction: stFunction
      of ptMethod: stMethod
      of ptClass: stClass
      of ptDecorator: stDecorator
      of ptBuiltin: stBuiltin
      of ptOperator: stOperator
      of ptType: stType
      of ptParameter: stParameter
      of ptSelfParam: stSelfParam
      of ptClsParam: stClsParam
      of ptProperty: stProperty
      of ptNamespace: stNamespace
      of ptBuiltinConst: stBuiltinConst
    result.add(deltaLine)
    result.add(deltaCol)
    result.add(tok.length)
    result.add(tokenType)
    result.add(0)  # no modifiers
    prevLine = tok.line
    prevCol = tok.col

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizePythonRange(text: string, startLine, endLine: int): seq[PythonToken] =
  let (tokens, _) = tokenizePython(text, startLine, endLine)
  return tokens

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
  let (_, diags) = tokenizePython(text)
  var diagsJson = newJArray()
  for d in diags:
    diagsJson.add(%*{
      "range": {
        "start": {"line": d.line, "character": d.col},
        "end": {"line": d.line, "character": d.endCol}
      },
      "severity": 1,
      "source": "niv-python-lsp",
      "message": d.message
    })
  sendNotification("textDocument/publishDiagnostics", %*{
    "uri": uri,
    "diagnostics": diagsJson
  })

# ---------------------------------------------------------------------------
# Go-to-definition
# ---------------------------------------------------------------------------

var pythonSearchPaths: seq[string]

proc initPythonPaths() =
  try:
    let (output, exitCode) = execCmdEx(
      "python3 -c \"import sys; print('\\n'.join(p for p in sys.path if p))\"")
    if exitCode == 0:
      for line in output.strip().splitLines():
        let p = line.strip()
        if p.len > 0 and dirExists(p):
          pythonSearchPaths.add(p)
  except OSError:
    discard

type
  ImportInfo = object
    module: string
    name: string
    alias: string

  ClassInfo = object
    name: string
    bases: seq[string]
    bodyStartLine: int
    bodyIndent: int

proc parseImports(text: string, packageDir: string = ""): seq[ImportInfo] =
  for rawLine in text.split('\n'):
    let line = rawLine.strip()
    if line.startsWith("from "):
      let rest = line[5..^1].strip()
      let importIdx = rest.find(" import ")
      if importIdx < 0: continue
      var module = rest[0..<importIdx].strip()
      if module.startsWith(".") and packageDir.len > 0:
        var dots = 0
        while dots < module.len and module[dots] == '.': inc dots
        var baseDir = packageDir
        for _ in 1..<dots: baseDir = parentDir(baseDir)
        let relName = module[dots..^1].strip()
        if relName.len > 0:
          let asFile = baseDir / relName & ".py"
          if fileExists(asFile): module = asFile
          else:
            let asPackage = baseDir / relName / "__init__.py"
            if fileExists(asPackage): module = asPackage
            else: continue
        else:
          module = baseDir / "__init__.py"
          if not fileExists(module): continue
      elif module.startsWith("."):
        continue
      let names = rest[importIdx + 8..^1].strip()
      for part in names.split(','):
        let trimmed = part.strip()
        if trimmed.len == 0: continue
        let asParts = trimmed.split(" as ")
        let name = asParts[0].strip()
        let alias = if asParts.len > 1: asParts[1].strip() else: ""
        result.add(ImportInfo(module: module, name: name, alias: alias))
    elif line.startsWith("import "):
      let rest = line[7..^1].strip()
      for part in rest.split(','):
        let trimmed = part.strip()
        if trimmed.len == 0: continue
        let asParts = trimmed.split(" as ")
        let module = asParts[0].strip()
        let alias = if asParts.len > 1: asParts[1].strip() else: ""
        result.add(ImportInfo(module: module, name: "", alias: alias))

proc parseClasses(text: string): seq[ClassInfo] =
  ## Extract class definitions with their base classes
  let lines = text.split('\n')
  for i in 0..<lines.len:
    let stripped = lines[i].strip()
    if stripped.startsWith("class "):
      var rest = stripped[6..^1]
      # Extract class name
      var nameEnd = 0
      while nameEnd < rest.len and rest[nameEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        inc nameEnd
      if nameEnd == 0: continue
      let className = rest[0..<nameEnd]
      var bases: seq[string]
      # Parse bases if '(' follows
      if nameEnd < rest.len and rest[nameEnd] == '(':
        let closeIdx = rest.find(')', nameEnd)
        if closeIdx > nameEnd + 1:
          let basesStr = rest[nameEnd + 1..<closeIdx]
          for base in basesStr.split(','):
            let b = base.strip()
            # Remove generic params like Base[T]
            let bracketIdx = b.find('[')
            let baseName = if bracketIdx >= 0: b[0..<bracketIdx].strip() else: b
            if baseName.len > 0:
              bases.add(baseName)
      # Determine body indent
      let lineIndent = lines[i].len - stripped.len
      var bodyIndent = lineIndent + 4  # default
      if i + 1 < lines.len:
        let nextLine = lines[i + 1]
        var nextIndent = 0
        for c in nextLine:
          if c == ' ': inc nextIndent
          elif c == '\t': nextIndent += 4
          else: break
        if nextIndent > lineIndent:
          bodyIndent = nextIndent
      result.add(ClassInfo(
        name: className, bases: bases,
        bodyStartLine: i + 1, bodyIndent: bodyIndent
      ))

var modulePathCache: Table[string, string]

proc resolveModulePath(moduleName: string): string =
  if modulePathCache.hasKey(moduleName):
    return modulePathCache[moduleName]
  # If it's already a file path (from relative import resolution)
  if moduleName.endsWith(".py") and fileExists(moduleName):
    modulePathCache[moduleName] = moduleName
    return moduleName
  let parts = moduleName.replace(".", "/")
  for searchPath in pythonSearchPaths:
    let asFile = searchPath / parts & ".py"
    if fileExists(asFile):
      modulePathCache[moduleName] = asFile
      return asFile
    let asPackage = searchPath / parts / "__init__.py"
    if fileExists(asPackage):
      modulePathCache[moduleName] = asPackage
      return asPackage
  # Fallback: ask Python
  try:
    let (output, exitCode) = execCmdEx(
      "python3 -c \"import " & moduleName & "; print(" & moduleName & ".__file__)\"")
    if exitCode == 0:
      let p = output.strip()
      if p.len > 0 and fileExists(p):
        modulePathCache[moduleName] = p
        return p
  except OSError:
    discard
  modulePathCache[moduleName] = ""
  return ""

proc findDefinitionInText(text: string, word: string): (int, int) =
  ## Find `def word` or `class word` in text. Returns (line, col) or (-1, -1).
  let lines = text.split('\n')
  let defPattern = "def " & word
  let classPattern = "class " & word
  for i in 0..<lines.len:
    let stripped = lines[i].strip()
    for pattern in [defPattern, classPattern]:
      if stripped.startsWith(pattern):
        let afterLen = pattern.len
        if afterLen >= stripped.len or
           stripped[afterLen] in {'(', ':', ' ', '\t'}:
          let col = lines[i].find(pattern)
          if col >= 0:
            let nameCol = col + pattern.len - word.len
            return (i, nameCol)
  # Also look for top-level assignment: word = ...
  for i in 0..<lines.len:
    let stripped = lines[i].strip()
    if stripped.startsWith(word) and stripped.len > word.len:
      let after = stripped[word.len..^1].strip()
      if after.startsWith("=") and not after.startsWith("=="):
        let col = lines[i].find(word)
        if col >= 0:
          return (i, col)
  return (-1, -1)

proc findMethodInClassBody(text: string, classInfo: ClassInfo, methodName: string): (int, int) =
  ## Search for `def methodName` inside a specific class body
  let lines = text.split('\n')
  let defPattern = "def " & methodName
  for i in classInfo.bodyStartLine..<lines.len:
    let ln = lines[i]
    # Measure indent
    var indent = 0
    for c in ln:
      if c == ' ': inc indent
      elif c == '\t': indent += 4
      else: break
    # Stop if indent drops to or below class definition level
    let stripped = ln.strip()
    if stripped.len > 0 and indent < classInfo.bodyIndent:
      break
    if stripped.startsWith(defPattern):
      let afterLen = defPattern.len
      if afterLen >= stripped.len or stripped[afterLen] in {'(', ':', ' ', '\t'}:
        let col = ln.find(defPattern)
        if col >= 0:
          return (i, col + 4)  # +4 to skip "def "
  return (-1, -1)

proc findMethodWithMRO(text: string, className: string, methodName: string,
                        imports: seq[ImportInfo], visited: var HashSet[string],
                        depth: int = 0): (string, int, int) =
  ## Search for method in class and its bases (MRO). Returns (filePath, line, col).
  ## filePath="" means current file.
  if depth > 10: return ("", -1, -1)  # prevent infinite recursion
  let key = className & "." & methodName
  if key in visited: return ("", -1, -1)
  visited.incl(key)

  let classes = parseClasses(text)

  # Find the class
  for cls in classes:
    if cls.name == className:
      # Search in this class body
      let (foundLine, foundCol) = findMethodInClassBody(text, cls, methodName)
      if foundLine >= 0:
        return ("", foundLine, foundCol)
      # Not found → search in base classes
      for base in cls.bases:
        # Check if base is defined in current file
        var baseFound = false
        for baseCls in classes:
          if baseCls.name == base:
            let (fp, bl, bc) = findMethodWithMRO(text, base, methodName, imports, visited, depth + 1)
            if bl >= 0: return (fp, bl, bc)
            baseFound = true
            break
        if not baseFound:
          # Try to resolve base from imports
          for imp in imports:
            let target = if imp.alias.len > 0: imp.alias else: imp.name
            if target == base and imp.name.len > 0:
              let modulePath = resolveModulePath(imp.module)
              if modulePath.len > 0:
                let moduleText = readFile(modulePath)
                let (fp, bl, bc) = findMethodWithMRO(moduleText, imp.name, methodName, imports, visited, depth + 1)
                if bl >= 0:
                  let resultPath = if fp.len > 0: fp else: modulePath
                  return (resultPath, bl, bc)
      return ("", -1, -1)

  return ("", -1, -1)

proc resolveQualifierType(text: string, qualifier: string, useLine: int): string =
  ## Try to determine the type of a variable.
  ## Returns class name or "".
  # 1. If qualifier starts with uppercase → likely a class itself
  if qualifier.len > 0 and qualifier[0] in {'A'..'Z'}:
    return qualifier

  # 2. Search for assignment: qualifier = ClassName( above current line
  let lines = text.split('\n')
  for i in countdown(min(useLine, lines.len - 1), 0):
    let stripped = lines[i].strip()
    if stripped.startsWith(qualifier) and stripped.len > qualifier.len:
      let afterVar = stripped[qualifier.len..^1].strip()
      if afterVar.startsWith("=") and not afterVar.startsWith("=="):
        let rhs = afterVar[1..^1].strip()
        # Extract class name from ClassName(...) or ClassName[...](...) etc.
        var className = ""
        for c in rhs:
          if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
            className.add(c)
          else: break
        if className.len > 0 and className[0] in {'A'..'Z'}:
          return className

  # 3. Search for type hint in function parameters: (qualifier: ClassName, ...)
  for i in countdown(min(useLine, lines.len - 1), 0):
    let ln = lines[i].strip()
    if ln.startsWith("def "):
      # Parse parameters
      let openParen = ln.find('(')
      let closeParen = ln.rfind(')')
      if openParen >= 0 and closeParen > openParen:
        let params = ln[openParen + 1..<closeParen]
        for param in params.split(','):
          let p = param.strip()
          let colonIdx = p.find(':')
          if colonIdx >= 0:
            let paramName = p[0..<colonIdx].strip()
            let typeName = p[colonIdx + 1..^1].strip()
            # Remove default value
            let eqIdx = typeName.find('=')
            let cleanType = if eqIdx >= 0: typeName[0..<eqIdx].strip() else: typeName
            if paramName == qualifier and cleanType.len > 0:
              # Remove Optional[], List[] etc wrappers
              var baseType = cleanType
              let bracketIdx = baseType.find('[')
              if bracketIdx >= 0:
                baseType = baseType[0..<bracketIdx]
              if baseType == "Optional" or baseType == "List" or baseType == "Dict":
                discard  # can't resolve inner type easily
              else:
                return baseType
      break  # only check the immediately enclosing function
  return ""

proc getDefinitionContext(text: string, line, col: int): (string, string) =
  ## Returns (qualifier, name). E.g. "json.loads" → ("json", "loads")
  let lines = text.split('\n')
  if line >= lines.len: return ("", "")
  let ln = lines[line]
  if col >= ln.len: return ("", "")
  if ln[col] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    return ("", "")
  var startCol = col
  while startCol > 0 and ln[startCol - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    dec startCol
  var endCol = col
  while endCol < ln.len and ln[endCol] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
    inc endCol
  let name = ln[startCol..<endCol]
  if startCol >= 2 and ln[startCol - 1] == '.':
    var qEnd = startCol - 1
    # Skip past closing paren if present: ClassName(...).method
    if qEnd >= 1 and ln[qEnd - 1] == ')':
      # Walk backward to find matching '('
      var depth = 1
      var qPos = qEnd - 2
      while qPos >= 0 and depth > 0:
        if ln[qPos] == ')': inc depth
        elif ln[qPos] == '(': dec depth
        dec qPos
      if depth == 0:
        # qPos+1 is at '(', identifier before it is the constructor
        var cEnd = qPos + 1
        var cStart = cEnd
        while cStart > 0 and ln[cStart - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
          dec cStart
        let qualifier = ln[cStart..<cEnd]
        if qualifier.len > 0:
          return (qualifier, name)
    else:
      var qStart = qEnd - 1
      while qStart > 0 and ln[qStart - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        dec qStart
      let qualifier = ln[qStart..<qEnd]
      if qualifier.len > 0:
        return (qualifier, name)
  return ("", name)

# ---------------------------------------------------------------------------
# Main server loop
# ---------------------------------------------------------------------------

proc main() =
  initLookupTables()
  initPythonPaths()
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
          "definitionProvider": true,
          "semanticTokensProvider": {
            "legend": {
              "tokenTypes": ["keyword", "string", "number", "comment",
                             "function", "method", "class", "macro",
                             "builtinFunction", "operator", "type", "parameter",
                             "selfParameter", "clsParameter", "property",
                             "namespace", "builtinConstant"],
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
      if text.len < 1_000_000:
        publishDiagnostics(uri, text)

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
          if newText.len < 1_000_000:
            publishDiagnostics(uri, newText)

    of "textDocument/didClose":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      documents.del(uri)

    of "textDocument/semanticTokens/full":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      let text = if uri in documents: documents[uri].text else: ""
      let (tokens, _) = tokenizePython(text)
      let data = encodeSemanticTokens(tokens)
      sendTokensResponse(id, data)

    of "textDocument/semanticTokens/range":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let rangeNode = params["range"]
      let startLine = rangeNode["start"]["line"].getInt()
      let endLine = rangeNode["end"]["line"].getInt()
      let text = if uri in documents: documents[uri].text else: ""
      let tokens = tokenizePythonRange(text, startLine, endLine)
      let data = encodeSemanticTokens(tokens)
      sendTokensResponse(id, data)

    of "textDocument/definition":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let defLine = params["position"]["line"].getInt()
      let defCol = params["position"]["character"].getInt()
      let text = if uri in documents: documents[uri].text else: ""
      var filePath = ""
      if uri.startsWith("file://"):
        filePath = uri[7..^1]

      let (qualifier, name) = getDefinitionContext(text, defLine, defCol)

      if name.len == 0:
        sendResponse(id, newJArray())
      elif qualifier.len == 0:
        # No qualifier — try same-file first, then imports
        let (foundLine, foundCol) = findDefinitionInText(text, name)
        if foundLine >= 0:
          sendResponse(id, %*{
            "uri": uri,
            "range": {
              "start": {"line": foundLine, "character": foundCol},
              "end": {"line": foundLine, "character": foundCol + name.len}
            }
          })
        else:
          var found = false
          let packageDir = if filePath.len > 0: parentDir(filePath) else: ""
          let imports = parseImports(text, packageDir)
          for imp in imports:
            let target = if imp.alias.len > 0: imp.alias else: imp.name
            if target == name and imp.name.len > 0:
              let modulePath = resolveModulePath(imp.module)
              if modulePath.len > 0:
                let moduleText = readFile(modulePath)
                let (mLine, mCol) = findDefinitionInText(moduleText, imp.name)
                if mLine >= 0:
                  sendResponse(id, %*{
                    "uri": "file://" & modulePath,
                    "range": {
                      "start": {"line": mLine, "character": mCol},
                      "end": {"line": mLine, "character": mCol + imp.name.len}
                    }
                  })
                  found = true
                  break
          if not found:
            # Try as module name: `import json` + gd on `json`
            for imp in imports:
              if imp.name.len == 0:  # bare import
                let target = if imp.alias.len > 0: imp.alias else: imp.module.split('.')[^1]
                if target == name:
                  let modulePath = resolveModulePath(imp.module)
                  if modulePath.len > 0:
                    sendResponse(id, %*{
                      "uri": "file://" & modulePath,
                      "range": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": 0}
                      }
                    })
                    found = true
                    break
          if not found:
            sendResponse(id, newJArray())
      else:
        # Qualifier present (e.g. json.loads, obj.method, ClassName(...).method)
        var found = false
        let packageDir = if filePath.len > 0: parentDir(filePath) else: ""
        let imports = parseImports(text, packageDir)

        # First: try to resolve qualifier as a type and do MRO-based method search
        let className = resolveQualifierType(text, qualifier, defLine)
        if className.len > 0:
          # Check if class is in current file
          var visited: HashSet[string]
          let (resultPath, mLine, mCol) = findMethodWithMRO(
            text, className, name, imports, visited)
          if mLine >= 0:
            if resultPath.len > 0:
              sendResponse(id, %*{
                "uri": "file://" & resultPath,
                "range": {
                  "start": {"line": mLine, "character": mCol},
                  "end": {"line": mLine, "character": mCol + name.len}
                }
              })
            else:
              sendResponse(id, %*{
                "uri": uri,
                "range": {
                  "start": {"line": mLine, "character": mCol},
                  "end": {"line": mLine, "character": mCol + name.len}
                }
              })
            found = true
          else:
            # Class might be imported
            for imp in imports:
              let target = if imp.alias.len > 0: imp.alias else: imp.name
              if target == className and imp.name.len > 0:
                let modulePath = resolveModulePath(imp.module)
                if modulePath.len > 0:
                  let moduleText = readFile(modulePath)
                  var visited2: HashSet[string]
                  let (fp, ml, mc) = findMethodWithMRO(
                    moduleText, imp.name, name, parseImports(moduleText, parentDir(modulePath)),
                    visited2)
                  if ml >= 0:
                    let resultUri = if fp.len > 0: "file://" & fp
                                    else: "file://" & modulePath
                    sendResponse(id, %*{
                      "uri": resultUri,
                      "range": {
                        "start": {"line": ml, "character": mc},
                        "end": {"line": ml, "character": mc + name.len}
                      }
                    })
                    found = true
                    break

        # Fallback: try as module.function (e.g. json.loads)
        if not found:
          for imp in imports:
            if imp.name.len == 0:  # `import X` or `import X as Y`
              let target = if imp.alias.len > 0: imp.alias else: imp.module.split('.')[^1]
              if target == qualifier:
                let modulePath = resolveModulePath(imp.module)
                if modulePath.len > 0:
                  let moduleText = readFile(modulePath)
                  let (mLine, mCol) = findDefinitionInText(moduleText, name)
                  if mLine >= 0:
                    sendResponse(id, %*{
                      "uri": "file://" & modulePath,
                      "range": {
                        "start": {"line": mLine, "character": mCol},
                        "end": {"line": mLine, "character": mCol + name.len}
                      }
                    })
                    found = true
                    break

        if not found:
          sendResponse(id, newJArray())

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
