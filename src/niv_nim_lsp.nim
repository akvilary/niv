## niv_nim_lsp — Nim Language Server with semantic tokens & go-to-definition
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing
##
## Features:
##   - 16 semantic token types (keyword, string, number, comment, function, method,
##     type, macro, builtinFunction, operator, parameter, property, namespace,
##     builtinConstant, decorator, enumMember)
##   - Context-aware tokenization (proc/method/template/macro, parameters, pragmas)
##   - Go-to-definition with import resolution and inheritance chain (object of)

import std/[json, strutils, os, tables, osproc, sets, algorithm]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  NimTokenKind = enum
    ntKeyword        # 0
    ntString         # 1
    ntNumber         # 2
    ntComment        # 3
    ntFunction       # 4  - name after proc/func/iterator/converter
    ntMethod         # 5  - name after method
    ntType           # 6  - type names
    ntMacro          # 7  - name after template/macro
    ntBuiltinFunc    # 8  - echo, len, assert, ...
    ntOperator       # 9  - =, +, -, and, or, not, ...
    ntParameter      # 10 - proc parameters
    ntProperty       # 11 - obj.field
    ntNamespace      # 12 - module name in import
    ntBuiltinConst   # 13 - true, false, nil
    ntDecorator      # 14 - pragmas {.name.}
    ntEnumMember     # 15 - enum members

  NimToken = object
    kind: NimTokenKind
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
  stType = 6
  stMacro = 7
  stBuiltinFunc = 8
  stOperator = 9
  stParameter = 10
  stProperty = 11
  stNamespace = 12
  stBuiltinConst = 13
  stDecorator = 14
  stEnumMember = 15

# ---------------------------------------------------------------------------
# Nim language data
# ---------------------------------------------------------------------------

# Sorted arrays for O(log n) binary search lookups (thread-safe, no GC)
const nimKeywords = [
  "addr", "asm", "bind", "block", "break", "case", "concept",
  "const", "continue", "defer", "discard", "distinct", "do",
  "elif", "else", "end", "enum", "except", "export", "finally",
  "for", "from", "if", "import", "include", "interface", "let",
  "mixin", "object", "of", "out", "ptr", "raise", "ref", "return",
  "static", "try", "tuple", "type", "unsafeAddr", "using", "var",
  "when", "while", "yield",
]

# Keywords that define the next identifier's kind
const nimDeclKeywords = [
  "converter", "func", "iterator", "macro", "method", "proc", "template",
]

const nimKwOperators = [
  "and", "as", "cast", "div", "in", "is", "isnot",
  "mod", "not", "notin", "or", "shl", "shr", "xor",
]

const nimBuiltinConstants = ["false", "nil", "true"]

const nimBuiltinTypes = [
  "BiggestFloat", "BiggestInt", "BiggestUInt",
  "Natural", "Ordinal", "Positive",
  "SomeFloat", "SomeInteger", "SomeNumber",
  "any", "array", "auto", "bool", "byte",
  "cdouble", "cfloat", "char", "cint", "clong",
  "csize_t", "cstring", "cuint",
  "float", "float32", "float64",
  "int", "int8", "int16", "int32", "int64",
  "openArray", "pointer", "range",
  "seq", "set", "string",
  "typed", "typedesc", "uint",
  "uint8", "uint16", "uint32", "uint64",
  "untyped", "varargs", "void",
]

const nimBuiltinFunctions = [
  "GC_ref", "GC_unref",
  "abs", "add", "alloc", "allocShared", "assert",
  "chr", "clamp", "close", "compiles", "contains",
  "debugEcho", "dec", "declared", "deepCopy", "default", "defined",
  "del", "dealloc", "doAssert",
  "echo", "find",
  "gorge",
  "high",
  "inc", "insert", "items",
  "len", "low",
  "max", "min", "mitems", "move", "mpairs",
  "new", "newSeq", "newString",
  "open", "ord",
  "pairs", "pred",
  "quit",
  "readAll", "readFile", "readLine", "realloc", "repr", "reset",
  "sizeof", "staticExec", "staticRead", "succ", "swap",
  "typeof",
  "wasMoved", "write", "writeFile", "writeLine",
]

# Thread-safe lookup procs using binary search on sorted const arrays (no GC)
proc isNimKeyword(word: string): bool =
  binarySearch(nimKeywords, word) >= 0

proc isNimDeclKeyword(word: string): bool =
  binarySearch(nimDeclKeywords, word) >= 0

proc isNimKwOperator(word: string): bool =
  binarySearch(nimKwOperators, word) >= 0

proc isNimBuiltinConst(word: string): bool =
  binarySearch(nimBuiltinConstants, word) >= 0

proc isNimBuiltinType(word: string): bool =
  binarySearch(nimBuiltinTypes, word) >= 0

proc isNimBuiltinFunc(word: string): bool =
  binarySearch(nimBuiltinFunctions, word) >= 0

# Precomputed lookup tables for O(1) classification (main thread only)
var keywordSet: Table[string, bool]
var declKeywordSet: Table[string, bool]
var kwOperatorSet: Table[string, bool]
var builtinConstSet: Table[string, bool]
var builtinTypeSet: Table[string, bool]
var builtinFuncSet: Table[string, bool]

proc initLookupTables() =
  for kw in nimKeywords: keywordSet[kw] = true
  for kw in nimDeclKeywords: declKeywordSet[kw] = true
  for kw in nimKwOperators: kwOperatorSet[kw] = true
  for kw in nimBuiltinConstants: builtinConstSet[kw] = true
  for kw in nimBuiltinTypes: builtinTypeSet[kw] = true
  for kw in nimBuiltinFunctions: builtinFuncSet[kw] = true

# ---------------------------------------------------------------------------
# Multi-line token splitting (strings and comments)
# ---------------------------------------------------------------------------

proc emitMultiLineTokens(tokens: var seq[NimToken], kind: NimTokenKind,
                          text: string, textStart, textEnd: int,
                          startLine, startCol: int, endLine: int,
                          rangeStart: int = -1, rangeEnd: int = -1) =
  let noFilter = rangeStart < 0
  if startLine == endLine:
    if noFilter or (startLine >= rangeStart and startLine <= rangeEnd):
      tokens.add(NimToken(kind: kind, line: startLine, col: startCol,
                           length: textEnd - textStart))
  else:
    var p = textStart
    var curLine = startLine
    while p < textEnd:
      let tokenCol = if curLine == startLine: startCol else: 0
      var lineLen = 0
      while p + lineLen < textEnd and text[p + lineLen] != '\n':
        inc lineLen
      if noFilter or (curLine >= rangeStart and curLine <= rangeEnd):
        tokens.add(NimToken(kind: kind, line: curLine, col: tokenCol,
                             length: lineLen))
      p += lineLen
      if p < textEnd and text[p] == '\n':
        inc p
      inc curLine

# ---------------------------------------------------------------------------
# Nim Tokenizer (full file)
# ---------------------------------------------------------------------------

proc tokenizeNim(text: string): (seq[NimToken], seq[DiagInfo]) =
  var tokens: seq[NimToken]
  var diags: seq[DiagInfo]

  var pos = 0
  var line = 0
  var col = 0
  var lastKeyword = ""  # Track proc/func/method/template/macro/type/iterator/converter

  # Parameter tracking
  var inFuncParams = false
  var funcParamDepth = 0
  var afterParamColon = false  # after : in param (type annotation)

  # Context tracking
  var afterDot = false
  var inImportLine = false
  var inFromLine = false

  # Type section tracking
  var inTypeSection {.used.} = false
  var typeSectionIndent {.used.} = 0
  var afterTypeEquals = false  # after = in type definition
  var inEnumBody = false
  var enumIndent = 0

  proc isIdentChar(c: char): bool =
    c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

  template ch(): char =
    if pos < text.len: text[pos] else: '\0'

  template advance() =
    if pos < text.len:
      if text[pos] == '\n':
        inc line
        col = 0
        lastKeyword = ""
        inImportLine = false
        inFromLine = false
        afterDot = false
        afterTypeEquals = false
      else:
        inc col
      inc pos

  template skipWhitespace() =
    while pos < text.len and text[pos] in {' ', '\t', '\r', '\n'}:
      advance()

  while pos < text.len:
    skipWhitespace()
    if pos >= text.len: break
    let c = ch()

    case c
    # Comments
    of '#':
      let sLine = line
      let sCol = col
      let startPos = pos
      if pos + 1 < text.len and text[pos + 1] == '[':
        # Multi-line comment #[ ... ]#
        advance(); advance()  # skip #[
        var depth = 1
        while pos < text.len and depth > 0:
          if pos + 1 < text.len and text[pos] == '#' and text[pos + 1] == '[':
            inc depth; advance(); advance()
          elif pos + 1 < text.len and text[pos] == ']' and text[pos + 1] == '#':
            dec depth; advance(); advance()
          else:
            advance()
        if depth > 0:
          diags.add(DiagInfo(line: sLine, col: sCol, endCol: sCol + 2,
                             message: "Unterminated multi-line comment"))
        emitMultiLineTokens(tokens, ntComment, text, startPos, pos, sLine, sCol, line)
      else:
        # Single line comment (# or ##)
        var length = 0
        while pos < text.len and text[pos] != '\n':
          advance(); inc length
        tokens.add(NimToken(kind: ntComment, line: sLine, col: sCol, length: length))

    # Strings
    of '"':
      lastKeyword = ""
      afterDot = false
      let sLine = line
      let sCol = col
      let startPos = pos
      if pos + 2 < text.len and text[pos + 1] == '"' and text[pos + 2] == '"':
        # Triple-quoted string
        advance(); advance(); advance()  # skip """
        while pos < text.len:
          if pos + 2 < text.len and text[pos] == '"' and text[pos + 1] == '"' and text[pos + 2] == '"':
            advance(); advance(); advance()
            break
          advance()
        emitMultiLineTokens(tokens, ntString, text, startPos, pos, sLine, sCol, line)
      else:
        # Regular string
        advance()  # skip opening "
        while pos < text.len:
          if text[pos] == '\\':
            advance()
            if pos < text.len: advance()
          elif text[pos] == '"':
            advance()
            break
          elif text[pos] == '\n':
            diags.add(DiagInfo(line: sLine, col: sCol, endCol: col,
                               message: "Unterminated string"))
            break
          else:
            advance()
        tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: pos - startPos))

    # Character literals
    of '\'':
      # Only treat as char literal if NOT preceded by alphanumeric (type suffix)
      let prevIsAlnum = pos > 0 and text[pos - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}
      if prevIsAlnum:
        # Type suffix like 42'i32 — consume as part of previous number token handled separately
        advance()
        # Skip the suffix identifier
        while pos < text.len and isIdentChar(text[pos]):
          advance()
      else:
        lastKeyword = ""
        afterDot = false
        let sLine = line
        let sCol = col
        advance()  # skip opening '
        if pos < text.len and text[pos] == '\\':
          advance()  # skip backslash
          if pos < text.len: advance()  # skip escape char
        elif pos < text.len:
          advance()  # skip the char
        if pos < text.len and text[pos] == '\'':
          advance()  # skip closing '
        tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: pos - (sCol + line * 0)))
        # Recalculate length from positions
        let length = col - sCol
        tokens[^1].length = length

    # Numbers
    of '0'..'9':
      lastKeyword = ""
      afterDot = false
      let sLine = line
      let sCol = col
      let startPos = pos
      if c == '0' and pos + 1 < text.len and text[pos + 1] in {'x', 'X'}:
        advance(); advance()
        while pos < text.len and text[pos] in {'0'..'9', 'a'..'f', 'A'..'F', '_'}:
          advance()
      elif c == '0' and pos + 1 < text.len and text[pos + 1] in {'o', 'O'}:
        advance(); advance()
        while pos < text.len and text[pos] in {'0'..'7', '_'}:
          advance()
      elif c == '0' and pos + 1 < text.len and text[pos + 1] in {'b', 'B'}:
        advance(); advance()
        while pos < text.len and text[pos] in {'0', '1', '_'}:
          advance()
      else:
        while pos < text.len and text[pos] in {'0'..'9', '_'}:
          advance()
        # Float part
        if pos < text.len and text[pos] == '.' and
           pos + 1 < text.len and text[pos + 1] in {'0'..'9'}:
          advance()  # skip .
          while pos < text.len and text[pos] in {'0'..'9', '_'}:
            advance()
        # Exponent
        if pos < text.len and text[pos] in {'e', 'E'}:
          advance()
          if pos < text.len and text[pos] in {'+', '-'}: advance()
          while pos < text.len and text[pos] in {'0'..'9', '_'}:
            advance()
      # Type suffix: 'i32, 'f64, etc.
      if pos < text.len and text[pos] == '\'':
        advance()
        while pos < text.len and isIdentChar(text[pos]):
          advance()
      tokens.add(NimToken(kind: ntNumber, line: sLine, col: sCol, length: pos - startPos))

    # Identifiers and keywords
    of 'a'..'z', 'A'..'Z', '_':
      let sLine = line
      let sCol = col
      let startPos = pos
      let wasDot = afterDot
      afterDot = false

      # Check for raw string: r"..."
      if c in {'r', 'R'} and pos + 1 < text.len and text[pos + 1] == '"':
        advance()  # skip r
        let strStartPos = startPos
        # Now handle as regular or triple string
        if pos + 2 < text.len and text[pos] == '"' and text[pos + 1] == '"' and text[pos + 2] == '"':
          advance(); advance(); advance()  # skip """
          while pos < text.len:
            if pos + 2 < text.len and text[pos] == '"' and text[pos + 1] == '"' and text[pos + 2] == '"':
              advance(); advance(); advance()
              break
            advance()
          emitMultiLineTokens(tokens, ntString, text, strStartPos, pos, sLine, sCol, line)
        else:
          advance()  # skip "
          while pos < text.len and text[pos] != '"' and text[pos] != '\n':
            advance()
          if pos < text.len and text[pos] == '"': advance()
          tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: pos - strStartPos))
        continue

      # Read identifier
      while pos < text.len and isIdentChar(text[pos]):
        advance()
      let word = text[startPos..<pos]
      let length = pos - startPos

      # Check for export marker *
      if pos < text.len and text[pos] == '*':
        advance()  # consume * but don't include in word

      # Classify the identifier
      if lastKeyword in ["proc", "func", "iterator", "converter"]:
        tokens.add(NimToken(kind: ntFunction, line: sLine, col: sCol, length: length))
        lastKeyword = ""
        # Check for generic params [T]
        skipWhitespace()
        if pos < text.len and text[pos] == '[':
          advance()
          var depth = 1
          while pos < text.len and depth > 0:
            if text[pos] == '[': inc depth
            elif text[pos] == ']': dec depth
            advance()
        # Enter func params if (
        skipWhitespace()
        if pos < text.len and text[pos] == '(':
          inFuncParams = true
          funcParamDepth = 1
          afterParamColon = false
          advance()
      elif lastKeyword == "method":
        tokens.add(NimToken(kind: ntMethod, line: sLine, col: sCol, length: length))
        lastKeyword = ""
        skipWhitespace()
        if pos < text.len and text[pos] == '[':
          advance()
          var depth = 1
          while pos < text.len and depth > 0:
            if text[pos] == '[': inc depth
            elif text[pos] == ']': dec depth
            advance()
        skipWhitespace()
        if pos < text.len and text[pos] == '(':
          inFuncParams = true
          funcParamDepth = 1
          afterParamColon = false
          advance()
      elif lastKeyword in ["template", "macro"]:
        tokens.add(NimToken(kind: ntMacro, line: sLine, col: sCol, length: length))
        lastKeyword = ""
        skipWhitespace()
        if pos < text.len and text[pos] == '[':
          advance()
          var depth = 1
          while pos < text.len and depth > 0:
            if text[pos] == '[': inc depth
            elif text[pos] == ']': dec depth
            advance()
        skipWhitespace()
        if pos < text.len and text[pos] == '(':
          inFuncParams = true
          funcParamDepth = 1
          afterParamColon = false
          advance()
      elif lastKeyword == "type":
        tokens.add(NimToken(kind: ntType, line: sLine, col: sCol, length: length))
        lastKeyword = ""
        # Track type section
        inTypeSection = true
        afterTypeEquals = false
      elif inFuncParams and not afterParamColon:
        tokens.add(NimToken(kind: ntParameter, line: sLine, col: sCol, length: length))
      elif inImportLine or inFromLine:
        tokens.add(NimToken(kind: ntNamespace, line: sLine, col: sCol, length: length))
      elif wasDot:
        # After dot: property or method call
        # Lookahead for ( to distinguish method call from property
        var lookPos = pos
        while lookPos < text.len and text[lookPos] in {' ', '\t'}: inc lookPos
        if lookPos < text.len and text[lookPos] == '(':
          tokens.add(NimToken(kind: ntFunction, line: sLine, col: sCol, length: length))
        else:
          tokens.add(NimToken(kind: ntProperty, line: sLine, col: sCol, length: length))
      elif inEnumBody and not afterTypeEquals:
        # Check if this looks like an enum member (identifier at proper indent)
        let lineStart = startPos - sCol
        var indent = 0
        var p = lineStart
        while p < text.len and text[p] in {' ', '\t'}:
          if text[p] == '\t': indent += 4 else: inc indent
          inc p
        if indent >= enumIndent and p == startPos:
          tokens.add(NimToken(kind: ntEnumMember, line: sLine, col: sCol, length: length))
        else:
          # Not at proper indent, might be end of enum
          if indent < enumIndent:
            inEnumBody = false
          # Fallback classification
          if builtinConstSet.hasKey(word):
            tokens.add(NimToken(kind: ntBuiltinConst, line: sLine, col: sCol, length: length))
          elif kwOperatorSet.hasKey(word):
            tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: length))
      elif builtinConstSet.hasKey(word):
        tokens.add(NimToken(kind: ntBuiltinConst, line: sLine, col: sCol, length: length))
      elif kwOperatorSet.hasKey(word):
        tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: length))
      elif declKeywordSet.hasKey(word):
        tokens.add(NimToken(kind: ntKeyword, line: sLine, col: sCol, length: length))
        lastKeyword = word
      elif keywordSet.hasKey(word):
        tokens.add(NimToken(kind: ntKeyword, line: sLine, col: sCol, length: length))
        # Track import/from lines
        if word == "import":
          inImportLine = true
          if inFromLine: inFromLine = false
        elif word == "from":
          inFromLine = true
        elif word == "include" or word == "export":
          inImportLine = true
        elif word == "type":
          # Standalone type keyword starts a type section
          lastKeyword = "type"
        elif word == "enum":
          # After = enum, enter enum body mode
          if afterTypeEquals:
            inEnumBody = true
            # Calculate enum indent (current indent + 2)
            let lineStart2 = startPos - sCol
            var baseIndent = 0
            var p2 = lineStart2
            while p2 < text.len and text[p2] in {' ', '\t'}:
              if text[p2] == '\t': baseIndent += 4 else: inc baseIndent
              inc p2
            enumIndent = baseIndent + 2
      elif builtinTypeSet.hasKey(word):
        tokens.add(NimToken(kind: ntType, line: sLine, col: sCol, length: length))
      elif builtinFuncSet.hasKey(word):
        tokens.add(NimToken(kind: ntBuiltinFunc, line: sLine, col: sCol, length: length))
      elif word[0] in {'A'..'Z'}:
        # Uppercase identifier — likely a type
        tokens.add(NimToken(kind: ntType, line: sLine, col: sCol, length: length))
      else:
        # Check if it's a function call: identifier followed by (
        var lookPos = pos
        while lookPos < text.len and text[lookPos] in {' ', '\t'}: inc lookPos
        if lookPos < text.len and text[lookPos] == '(':
          tokens.add(NimToken(kind: ntFunction, line: sLine, col: sCol, length: length))
        # else: plain variable, no token emitted
      lastKeyword = if declKeywordSet.hasKey(word) or word == "type": word else: ""

    # Backtick identifiers
    of '`':
      lastKeyword = ""
      let sLine = line
      let sCol = col
      advance()  # skip opening `
      while pos < text.len and text[pos] != '`' and text[pos] != '\n':
        advance()
      if pos < text.len and text[pos] == '`':
        advance()  # skip closing `
      let length = col - sCol
      tokens.add(NimToken(kind: ntFunction, line: sLine, col: sCol, length: length))

    # Pragmas {. ... .}
    of '{':
      if pos + 1 < text.len and text[pos + 1] == '.':
        let sLine = line
        let sCol = col
        let startPos = pos
        advance(); advance()  # skip {.
        while pos < text.len:
          if pos + 1 < text.len and text[pos] == '.' and text[pos + 1] == '}':
            advance(); advance()  # skip .}
            break
          elif text[pos] == '\n':
            # Pragma on single line only for now
            break
          else:
            advance()
        emitMultiLineTokens(tokens, ntDecorator, text, startPos, pos, sLine, sCol, line)
      else:
        advance()

    # Dot
    of '.':
      if pos + 1 < text.len and text[pos + 1] == '.':
        # .. range operator
        let sLine = line
        let sCol = col
        advance(); advance()
        tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: 2))
      else:
        afterDot = true
        advance()

    # Operators
    of '=':
      afterTypeEquals = true
      let sLine = line
      let sCol = col
      advance()
      if pos < text.len and text[pos] == '=':
        advance()
        tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: 2))
      else:
        tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: 1))

    of '+', '-', '*', '/', '<', '>', '!', '~', '%', '&', '|', '^', '@', '$', '?':
      lastKeyword = ""
      afterDot = false
      let sLine = line
      let sCol = col
      let startPos = pos
      advance()
      # Consume compound operators
      while pos < text.len and text[pos] in {'=', '>', '<', '+', '-', '*', '/', '!', '~', '%', '&', '|', '^', '@', '$', '?'}:
        advance()
      tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: pos - startPos))

    # Parentheses (parameter tracking)
    of '(':
      if inFuncParams:
        inc funcParamDepth
      advance()

    of ')':
      if inFuncParams:
        dec funcParamDepth
        if funcParamDepth <= 0:
          inFuncParams = false
          funcParamDepth = 0
      advance()

    of '[':
      advance()

    of ']':
      advance()

    # Comma in params
    of ',':
      if inFuncParams:
        afterParamColon = false
      # In import line: next identifier is also namespace
      advance()

    # Colon
    of ':':
      if inFuncParams:
        afterParamColon = true
      advance()

    # Semicolon
    of ';':
      if inFuncParams:
        afterParamColon = false
      advance()

    else:
      advance()

  return (tokens, diags)

# ---------------------------------------------------------------------------
# Parallel Tokenizer
# ---------------------------------------------------------------------------

const
  MaxTokenThreads = 4
  ParallelLineThreshold = 4000

type
  NimTokenizerState = object
    blockCommentDepth: int
    inMultiLineString: bool

  NimSectionArgs = object
    textPtr: ptr UncheckedArray[char]
    textLen: int
    startPos: int
    endPos: int
    startLine: int
    initState: NimTokenizerState
    chanIdx: int

var nimSectionChannels: array[MaxTokenThreads, Channel[seq[NimToken]]]
var nimSectionThreads: array[MaxTokenThreads, Thread[NimSectionArgs]]

proc preScanNimState(text: string, startPos, endPos: int, initState: NimTokenizerState): NimTokenizerState =
  ## Lightweight pre-scan tracking only cross-line state: block comment depth
  ## and multi-line string (triple-quoted).
  result = initState
  var pos = startPos
  while pos < endPos:
    if result.blockCommentDepth > 0:
      # Inside block comment — scan for nested #[ or closing ]#
      if pos + 1 < endPos and text[pos] == '#' and text[pos+1] == '[':
        inc result.blockCommentDepth
        pos += 2
      elif pos + 1 < endPos and text[pos] == ']' and text[pos+1] == '#':
        dec result.blockCommentDepth
        pos += 2
      else:
        inc pos
      continue
    if result.inMultiLineString:
      # Inside triple-quoted string — scan for closing """
      if pos + 2 < endPos and text[pos] == '"' and text[pos+1] == '"' and text[pos+2] == '"':
        result.inMultiLineString = false
        pos += 3
      else:
        inc pos
      continue
    # Normal mode
    # Single-line comment — skip to end of line
    if text[pos] == '#':
      if pos + 1 < endPos and text[pos+1] == '[':
        # Block comment start
        result.blockCommentDepth = 1
        pos += 2
        continue
      else:
        # Single-line comment: skip to newline
        while pos < endPos and text[pos] != '\n':
          inc pos
        continue
    # Triple-quoted string
    if pos + 2 < endPos and text[pos] == '"' and text[pos+1] == '"' and text[pos+2] == '"':
      result.inMultiLineString = true
      pos += 3
      continue
    # Raw triple-quoted string: r"""..."""
    if text[pos] in {'r', 'R'} and pos + 3 < endPos and text[pos+1] == '"' and text[pos+2] == '"' and text[pos+3] == '"':
      result.inMultiLineString = true
      pos += 4
      continue
    # Regular string: skip to end (no cross-line state)
    if text[pos] == '"':
      inc pos
      while pos < endPos and text[pos] != '"' and text[pos] != '\n':
        if text[pos] == '\\' and pos + 1 < endPos: inc pos
        inc pos
      if pos < endPos and text[pos] == '"': inc pos
      continue
    # Character literal
    if text[pos] == '\'':
      inc pos
      if pos < endPos and text[pos] == '\\':
        inc pos
        if pos < endPos: inc pos
      elif pos < endPos: inc pos
      if pos < endPos and text[pos] == '\'': inc pos
      continue
    inc pos

proc nimIsIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc nimSectionWorker(args: NimSectionArgs) {.thread.} =
  ## Tokenize a section of Nim text with given initial cross-line state.
  ## This is a standalone proc (no closures) suitable for thread execution.
  var sectionLen = args.endPos - args.startPos
  var text = newString(sectionLen)
  if sectionLen > 0:
    copyMem(addr text[0], addr args.textPtr[args.startPos], sectionLen)

  var tokens: seq[NimToken]
  var pos = 0
  var line = args.startLine
  var col = 0
  var lastKeyword = ""

  var inFuncParams = false
  var funcParamDepth = 0
  var afterParamColon = false
  var afterDot = false
  var inImportLine = false
  var inFromLine = false
  var afterTypeEquals = false
  var inEnumBody = false
  var enumIndent = 0

  template ch(): char =
    if pos < text.len: text[pos] else: '\0'

  template advance() =
    if pos < text.len:
      if text[pos] == '\n':
        inc line; col = 0
        lastKeyword = ""; inImportLine = false
        inFromLine = false; afterDot = false; afterTypeEquals = false
      else: inc col
      inc pos

  template skipWS() =
    while pos < text.len and text[pos] in {' ', '\t', '\r', '\n'}:
      advance()

  # Handle initial state: if starting inside a block comment, scan for closing ]#
  if args.initState.blockCommentDepth > 0:
    var depth = args.initState.blockCommentDepth
    let sLine = line
    let sCol = col
    let startPos2 = pos
    while pos < text.len and depth > 0:
      if pos + 1 < text.len and text[pos] == '#' and text[pos + 1] == '[':
        inc depth; advance(); advance()
      elif pos + 1 < text.len and text[pos] == ']' and text[pos + 1] == '#':
        dec depth; advance(); advance()
      else:
        advance()
    # Emit multi-line comment tokens line by line
    if sLine == line:
      tokens.add(NimToken(kind: ntComment, line: sLine, col: sCol, length: col - sCol))
    else:
      var p = startPos2
      var curLine = sLine
      while p < pos:
        let tokenCol = if curLine == sLine: sCol else: 0
        var lineLen = 0
        while startPos2 + lineLen < pos and p + lineLen < text.len and text[p + lineLen] != '\n':
          inc lineLen
        tokens.add(NimToken(kind: ntComment, line: curLine, col: tokenCol, length: lineLen))
        p += lineLen
        if p < text.len and text[p] == '\n': inc p
        inc curLine

  # Handle initial state: if starting inside a multi-line string, scan for closing """
  if args.initState.inMultiLineString:
    let sLine = line
    let sCol = col
    let startPos2 = pos
    while pos < text.len:
      if pos + 2 < text.len and text[pos] == '"' and text[pos + 1] == '"' and text[pos + 2] == '"':
        advance(); advance(); advance()
        break
      advance()
    # Emit multi-line string tokens line by line
    if sLine == line:
      tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: col - sCol))
    else:
      var p = startPos2
      var curLine = sLine
      while p < pos:
        let tokenCol = if curLine == sLine: sCol else: 0
        var lineLen = 0
        while p + lineLen < pos and p + lineLen < text.len and text[p + lineLen] != '\n':
          inc lineLen
        tokens.add(NimToken(kind: ntString, line: curLine, col: tokenCol, length: lineLen))
        p += lineLen
        if p < text.len and text[p] == '\n': inc p
        inc curLine

  # Main tokenization loop
  while pos < text.len:
    skipWS()
    if pos >= text.len: break
    let c = ch()

    case c
    # Comments
    of '#':
      let sLine = line; let sCol = col; let startPos2 = pos
      if pos + 1 < text.len and text[pos + 1] == '[':
        # Multi-line comment #[ ... ]#
        advance(); advance()
        var depth = 1
        while pos < text.len and depth > 0:
          if pos + 1 < text.len and text[pos] == '#' and text[pos + 1] == '[':
            inc depth; advance(); advance()
          elif pos + 1 < text.len and text[pos] == ']' and text[pos + 1] == '#':
            dec depth; advance(); advance()
          else:
            advance()
        # Emit multi-line comment tokens
        if sLine == line:
          tokens.add(NimToken(kind: ntComment, line: sLine, col: sCol, length: col - sCol))
        else:
          var p = startPos2
          var curLine = sLine
          while p < pos:
            let tokenCol = if curLine == sLine: sCol else: 0
            var lineLen = 0
            while p + lineLen < pos and p + lineLen < text.len and text[p + lineLen] != '\n':
              inc lineLen
            tokens.add(NimToken(kind: ntComment, line: curLine, col: tokenCol, length: lineLen))
            p += lineLen
            if p < text.len and text[p] == '\n': inc p
            inc curLine
      else:
        # Single line comment
        var length = 0
        while pos < text.len and text[pos] != '\n':
          advance(); inc length
        tokens.add(NimToken(kind: ntComment, line: sLine, col: sCol, length: length))

    # Strings
    of '"':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col; let startPos2 = pos
      if pos + 2 < text.len and text[pos + 1] == '"' and text[pos + 2] == '"':
        # Triple-quoted string
        advance(); advance(); advance()
        while pos < text.len:
          if pos + 2 < text.len and text[pos] == '"' and text[pos + 1] == '"' and text[pos + 2] == '"':
            advance(); advance(); advance(); break
          advance()
        # Emit multi-line string tokens
        if sLine == line:
          tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: col - sCol))
        else:
          var p = startPos2
          var curLine = sLine
          while p < pos:
            let tokenCol = if curLine == sLine: sCol else: 0
            var lineLen = 0
            while p + lineLen < pos and p + lineLen < text.len and text[p + lineLen] != '\n':
              inc lineLen
            tokens.add(NimToken(kind: ntString, line: curLine, col: tokenCol, length: lineLen))
            p += lineLen
            if p < text.len and text[p] == '\n': inc p
            inc curLine
      else:
        # Regular string
        advance()
        while pos < text.len:
          if text[pos] == '\\': advance(); (if pos < text.len: advance())
          elif text[pos] == '"': advance(); break
          elif text[pos] == '\n': break
          else: advance()
        tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: pos - startPos2))

    # Character literals
    of '\'':
      let prevIsAlnum = pos > 0 and text[pos - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}
      if prevIsAlnum:
        advance()
        while pos < text.len and nimIsIdentChar(text[pos]): advance()
      else:
        lastKeyword = ""; afterDot = false
        let sLine = line; let sCol = col
        advance()
        if pos < text.len and text[pos] == '\\':
          advance(); (if pos < text.len: advance())
        elif pos < text.len: advance()
        if pos < text.len and text[pos] == '\'': advance()
        tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: col - sCol))

    # Numbers
    of '0'..'9':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col; let startPos2 = pos
      if c == '0' and pos + 1 < text.len and text[pos + 1] in {'x', 'X'}:
        advance(); advance()
        while pos < text.len and text[pos] in {'0'..'9', 'a'..'f', 'A'..'F', '_'}: advance()
      elif c == '0' and pos + 1 < text.len and text[pos + 1] in {'o', 'O'}:
        advance(); advance()
        while pos < text.len and text[pos] in {'0'..'7', '_'}: advance()
      elif c == '0' and pos + 1 < text.len and text[pos + 1] in {'b', 'B'}:
        advance(); advance()
        while pos < text.len and text[pos] in {'0', '1', '_'}: advance()
      else:
        while pos < text.len and text[pos] in {'0'..'9', '_'}: advance()
        if pos < text.len and text[pos] == '.' and pos + 1 < text.len and text[pos + 1] in {'0'..'9'}:
          advance()
          while pos < text.len and text[pos] in {'0'..'9', '_'}: advance()
        if pos < text.len and text[pos] in {'e', 'E'}:
          advance()
          if pos < text.len and text[pos] in {'+', '-'}: advance()
          while pos < text.len and text[pos] in {'0'..'9', '_'}: advance()
      if pos < text.len and text[pos] == '\'':
        advance()
        while pos < text.len and nimIsIdentChar(text[pos]): advance()
      tokens.add(NimToken(kind: ntNumber, line: sLine, col: sCol, length: pos - startPos2))

    # Identifiers and keywords
    of 'a'..'z', 'A'..'Z', '_':
      let sLine = line; let sCol = col; let startPos2 = pos
      let wasDot = afterDot; afterDot = false

      # Raw string check
      if c in {'r', 'R'} and pos + 1 < text.len and text[pos + 1] == '"':
        advance()
        let strStart = startPos2
        if pos + 2 < text.len and text[pos] == '"' and text[pos + 1] == '"' and text[pos + 2] == '"':
          advance(); advance(); advance()
          while pos < text.len:
            if pos + 2 < text.len and text[pos] == '"' and text[pos + 1] == '"' and text[pos + 2] == '"':
              advance(); advance(); advance(); break
            advance()
          # Emit multi-line string tokens
          if sLine == line:
            tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: col - sCol))
          else:
            var p = strStart
            var curLine = sLine
            while p < pos:
              let tokenCol = if curLine == sLine: sCol else: 0
              var lineLen = 0
              while p + lineLen < pos and p + lineLen < text.len and text[p + lineLen] != '\n':
                inc lineLen
              tokens.add(NimToken(kind: ntString, line: curLine, col: tokenCol, length: lineLen))
              p += lineLen
              if p < text.len and text[p] == '\n': inc p
              inc curLine
        else:
          advance()
          while pos < text.len and text[pos] != '"' and text[pos] != '\n': advance()
          if pos < text.len and text[pos] == '"': advance()
          tokens.add(NimToken(kind: ntString, line: sLine, col: sCol, length: pos - strStart))
        continue

      # Read identifier
      while pos < text.len and nimIsIdentChar(text[pos]): advance()
      let word = text[startPos2..<pos]
      let length = pos - startPos2
      if pos < text.len and text[pos] == '*': advance()

      # Classify the identifier
      if lastKeyword in ["proc", "func", "iterator", "converter"]:
        tokens.add(NimToken(kind: ntFunction, line: sLine, col: sCol, length: length))
        lastKeyword = ""
        skipWS()
        if pos < text.len and text[pos] == '[':
          advance(); var d = 1
          while pos < text.len and d > 0:
            if text[pos] == '[': inc d elif text[pos] == ']': dec d
            advance()
        skipWS()
        if pos < text.len and text[pos] == '(':
          inFuncParams = true; funcParamDepth = 1; afterParamColon = false; advance()
      elif lastKeyword == "method":
        tokens.add(NimToken(kind: ntMethod, line: sLine, col: sCol, length: length))
        lastKeyword = ""
        skipWS()
        if pos < text.len and text[pos] == '[':
          advance(); var d = 1
          while pos < text.len and d > 0:
            if text[pos] == '[': inc d elif text[pos] == ']': dec d
            advance()
        skipWS()
        if pos < text.len and text[pos] == '(':
          inFuncParams = true; funcParamDepth = 1; afterParamColon = false; advance()
      elif lastKeyword in ["template", "macro"]:
        tokens.add(NimToken(kind: ntMacro, line: sLine, col: sCol, length: length))
        lastKeyword = ""
        skipWS()
        if pos < text.len and text[pos] == '[':
          advance(); var d = 1
          while pos < text.len and d > 0:
            if text[pos] == '[': inc d elif text[pos] == ']': dec d
            advance()
        skipWS()
        if pos < text.len and text[pos] == '(':
          inFuncParams = true; funcParamDepth = 1; afterParamColon = false; advance()
      elif lastKeyword == "type":
        tokens.add(NimToken(kind: ntType, line: sLine, col: sCol, length: length))
        lastKeyword = ""
        afterTypeEquals = false
      elif inFuncParams and not afterParamColon:
        tokens.add(NimToken(kind: ntParameter, line: sLine, col: sCol, length: length))
      elif inImportLine or inFromLine:
        tokens.add(NimToken(kind: ntNamespace, line: sLine, col: sCol, length: length))
      elif wasDot:
        var lookPos = pos
        while lookPos < text.len and text[lookPos] in {' ', '\t'}: inc lookPos
        if lookPos < text.len and text[lookPos] == '(':
          tokens.add(NimToken(kind: ntFunction, line: sLine, col: sCol, length: length))
        else:
          tokens.add(NimToken(kind: ntProperty, line: sLine, col: sCol, length: length))
      elif inEnumBody and not afterTypeEquals:
        let lineStart = startPos2 - sCol
        var indent = 0
        var p2 = lineStart
        while p2 < text.len and text[p2] in {' ', '\t'}:
          if text[p2] == '\t': indent += 4 else: inc indent
          inc p2
        if indent >= enumIndent and p2 == startPos2:
          tokens.add(NimToken(kind: ntEnumMember, line: sLine, col: sCol, length: length))
        else:
          if indent < enumIndent: inEnumBody = false
          if isNimBuiltinConst(word):
            tokens.add(NimToken(kind: ntBuiltinConst, line: sLine, col: sCol, length: length))
          elif isNimKwOperator(word):
            tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: length))
      elif isNimBuiltinConst(word):
        tokens.add(NimToken(kind: ntBuiltinConst, line: sLine, col: sCol, length: length))
      elif isNimKwOperator(word):
        tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: length))
      elif isNimDeclKeyword(word):
        tokens.add(NimToken(kind: ntKeyword, line: sLine, col: sCol, length: length))
        lastKeyword = word
      elif isNimKeyword(word):
        tokens.add(NimToken(kind: ntKeyword, line: sLine, col: sCol, length: length))
        if word == "import": inImportLine = true; (if inFromLine: inFromLine = false)
        elif word == "from": inFromLine = true
        elif word in ["include", "export"]: inImportLine = true
        elif word == "type": lastKeyword = "type"
        elif word == "enum" and afterTypeEquals:
          inEnumBody = true
          let ls = startPos2 - sCol
          var bi = 0; var p2 = ls
          while p2 < text.len and text[p2] in {' ', '\t'}:
            if text[p2] == '\t': bi += 4 else: inc bi; inc p2
          enumIndent = bi + 2
      elif isNimBuiltinType(word):
        tokens.add(NimToken(kind: ntType, line: sLine, col: sCol, length: length))
      elif isNimBuiltinFunc(word):
        tokens.add(NimToken(kind: ntBuiltinFunc, line: sLine, col: sCol, length: length))
      elif word.len > 0 and word[0] in {'A'..'Z'}:
        tokens.add(NimToken(kind: ntType, line: sLine, col: sCol, length: length))
      else:
        var lookPos = pos
        while lookPos < text.len and text[lookPos] in {' ', '\t'}: inc lookPos
        if lookPos < text.len and text[lookPos] == '(':
          tokens.add(NimToken(kind: ntFunction, line: sLine, col: sCol, length: length))
      lastKeyword = if isNimDeclKeyword(word) or word == "type": word else: ""

    # Backtick identifiers
    of '`':
      lastKeyword = ""
      let sLine = line; let sCol = col
      advance()
      while pos < text.len and text[pos] != '`' and text[pos] != '\n': advance()
      if pos < text.len and text[pos] == '`': advance()
      tokens.add(NimToken(kind: ntFunction, line: sLine, col: sCol, length: col - sCol))

    # Pragmas {. ... .}
    of '{':
      if pos + 1 < text.len and text[pos + 1] == '.':
        let sLine = line; let sCol = col; let startPos2 = pos
        advance(); advance()
        while pos < text.len:
          if pos + 1 < text.len and text[pos] == '.' and text[pos + 1] == '}':
            advance(); advance(); break
          elif text[pos] == '\n': break
          else: advance()
        # Emit multi-line decorator tokens
        if sLine == line:
          tokens.add(NimToken(kind: ntDecorator, line: sLine, col: sCol, length: col - sCol))
        else:
          var p = startPos2
          var curLine = sLine
          while p < pos:
            let tokenCol = if curLine == sLine: sCol else: 0
            var lineLen = 0
            while p + lineLen < pos and p + lineLen < text.len and text[p + lineLen] != '\n':
              inc lineLen
            tokens.add(NimToken(kind: ntDecorator, line: curLine, col: tokenCol, length: lineLen))
            p += lineLen
            if p < text.len and text[p] == '\n': inc p
            inc curLine
      else: advance()

    # Dot
    of '.':
      if pos + 1 < text.len and text[pos + 1] == '.':
        let sLine = line; let sCol = col
        advance(); advance()
        tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: 2))
      else: afterDot = true; advance()

    # Operators
    of '=':
      afterTypeEquals = true
      let sLine = line; let sCol = col
      advance()
      if pos < text.len and text[pos] == '=': advance()
      tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: col - sCol))

    of '+', '-', '*', '/', '<', '>', '!', '~', '%', '&', '|', '^', '@', '$', '?':
      lastKeyword = ""; afterDot = false
      let sLine = line; let sCol = col; let startPos2 = pos
      advance()
      while pos < text.len and text[pos] in {'=', '>', '<', '+', '-', '*', '/', '!', '~', '%', '&', '|', '^', '@', '$', '?'}: advance()
      tokens.add(NimToken(kind: ntOperator, line: sLine, col: sCol, length: pos - startPos2))

    of '(':
      if inFuncParams: inc funcParamDepth
      advance()
    of ')':
      if inFuncParams:
        dec funcParamDepth
        if funcParamDepth <= 0: inFuncParams = false; funcParamDepth = 0
      advance()
    of ',':
      if inFuncParams: afterParamColon = false
      advance()
    of ':':
      if inFuncParams: afterParamColon = true
      advance()
    of ';':
      if inFuncParams: afterParamColon = false
      advance()
    else: advance()

  nimSectionChannels[args.chanIdx].send(tokens)

proc tokenizeNimParallel(text: string): (seq[NimToken], seq[DiagInfo]) =
  if text.len == 0: return (@[], @[])

  var lineOffsets: seq[int] = @[0]
  for i in 0..<text.len:
    if text[i] == '\n': lineOffsets.add(i + 1)
  let totalLines = lineOffsets.len

  if totalLines < ParallelLineThreshold:
    return tokenizeNim(text)

  let threadCount = min(countProcessors(), MaxTokenThreads)
  if threadCount <= 1:
    return tokenizeNim(text)

  let textPtr = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
  let linesPerSection = totalLines div threadCount

  # Pre-scan to determine state at each section boundary (sequential, cumulative)
  var states: seq[NimTokenizerState] = @[NimTokenizerState()]
  for t in 0..<threadCount - 1:
    let sLine = t * linesPerSection
    let eLine = (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    states.add(preScanNimState(text, startPos, endPos, states[t]))

  for t in 0..<threadCount:
    let sLine = t * linesPerSection
    let eLine = if t == threadCount - 1: totalLines - 1
                else: (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    nimSectionChannels[t].open()
    createThread(nimSectionThreads[t], nimSectionWorker, NimSectionArgs(
      textPtr: textPtr, textLen: text.len,
      startPos: startPos, endPos: endPos,
      startLine: sLine, initState: states[t], chanIdx: t
    ))

  var allTokens: seq[NimToken] = @[]
  for t in 0..<threadCount:
    joinThread(nimSectionThreads[t])
    let (hasData, sectionTokens) = nimSectionChannels[t].tryRecv()
    if hasData: allTokens.add(sectionTokens)
    nimSectionChannels[t].close()

  return (allTokens, @[])

# ---------------------------------------------------------------------------
# Range tokenizer (for viewport)
# ---------------------------------------------------------------------------

proc tokenizeNimRange(text: string, startLine, endLine: int): seq[NimToken] =
  let (allTokens, _) = tokenizeNimParallel(text)
  result = @[]
  for tok in allTokens:
    if tok.line >= startLine and tok.line <= endLine:
      result.add(tok)

# ---------------------------------------------------------------------------
# Semantic Token Encoding
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[NimToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of ntKeyword: stKeyword
      of ntString: stString
      of ntNumber: stNumber
      of ntComment: stComment
      of ntFunction: stFunction
      of ntMethod: stMethod
      of ntType: stType
      of ntMacro: stMacro
      of ntBuiltinFunc: stBuiltinFunc
      of ntOperator: stOperator
      of ntParameter: stParameter
      of ntProperty: stProperty
      of ntNamespace: stNamespace
      of ntBuiltinConst: stBuiltinConst
      of ntDecorator: stDecorator
      of ntEnumMember: stEnumMember
    result.add(deltaLine)
    result.add(deltaCol)
    result.add(tok.length)
    result.add(tokenType)
    result.add(0)
    prevLine = tok.line
    prevCol = tok.col

# ---------------------------------------------------------------------------
# Go-to-definition
# ---------------------------------------------------------------------------

type
  ImportInfo = object
    module: string
    names: seq[string]
    alias: string

  TypeInfo = object
    name: string
    parent: string
    bodyStartLine: int
    bodyIndent: int

var nimLibPath = ""
var nimSearchPaths: seq[string]
var modulePathCache: Table[string, string]
var projectRoot = ""

proc initNimPaths() =
  try:
    let (output, exitCode) = execCmdEx("nim dump --dump.format:json . 2>&1")
    if exitCode == 0:
      let data = parseJson(output)
      if data.hasKey("lib"):
        nimLibPath = data["lib"].getStr()
      if data.hasKey("lazyPaths"):
        for p in data["lazyPaths"]:
          let path = p.getStr()
          if path.len > 0 and dirExists(path):
            nimSearchPaths.add(path)
      if data.hasKey("paths"):
        for p in data["paths"]:
          let path = p.getStr()
          if path.len > 0 and dirExists(path):
            nimSearchPaths.add(path)
  except CatchableError:
    discard
  # Fallback: try to find nimlib
  if nimLibPath.len == 0:
    try:
      let (output, exitCode) = execCmdEx("nim --verbosity:0 --hints:off -e \"echo getCurrentDir()\" 2>/dev/null")
      discard output
      discard exitCode
      let nimExe = findExe("nim")
      if nimExe.len > 0:
        let nimDir = parentDir(parentDir(nimExe))
        let libDir = nimDir / "lib"
        if dirExists(libDir):
          nimLibPath = libDir
    except CatchableError:
      discard

proc parseNimImports(text: string, fileDir: string): seq[ImportInfo] =
  for rawLine in text.split('\n'):
    let line = rawLine.strip()
    if line.startsWith("from "):
      let rest = line[5..^1].strip()
      let importIdx = rest.find(" import ")
      if importIdx < 0: continue
      let module = rest[0..<importIdx].strip()
      let namesStr = rest[importIdx + 8..^1].strip()
      var names: seq[string]
      for part in namesStr.split(','):
        let n = part.strip()
        if n.len > 0: names.add(n)
      result.add(ImportInfo(module: module, names: names))
    elif line.startsWith("import "):
      let rest = line[7..^1].strip()
      # Handle import std/[a, b, c]
      let slashBracket = rest.find("/[")
      if slashBracket >= 0:
        let prefix = rest[0..slashBracket]  # e.g. "std/"
        let bracketStart = slashBracket + 2
        let bracketEnd = rest.find(']', bracketStart)
        if bracketEnd > bracketStart:
          let modules = rest[bracketStart..<bracketEnd]
          for part in modules.split(','):
            let m = part.strip()
            if m.len > 0:
              result.add(ImportInfo(module: prefix & m))
      else:
        for part in rest.split(','):
          let trimmed = part.strip()
          if trimmed.len == 0: continue
          let asParts = trimmed.split(" as ")
          let module = asParts[0].strip()
          let alias = if asParts.len > 1: asParts[1].strip() else: ""
          result.add(ImportInfo(module: module, alias: alias))
    elif line.startsWith("include "):
      let rest = line[8..^1].strip()
      result.add(ImportInfo(module: rest))

proc resolveNimModule(moduleName: string, fileDir: string): string =
  if modulePathCache.hasKey(moduleName):
    return modulePathCache[moduleName]

  # 1. Relative imports (./xxx, ../xxx)
  if moduleName.startsWith("./") or moduleName.startsWith("../"):
    let resolved = fileDir / moduleName & ".nim"
    let normalized = normalizedPath(resolved)
    if fileExists(normalized):
      modulePathCache[moduleName] = normalized
      return normalized
    modulePathCache[moduleName] = ""
    return ""

  # 2. std/ prefix — search in nimlib
  if moduleName.startsWith("std/"):
    let name = moduleName[4..^1]
    if nimLibPath.len > 0:
      for subdir in ["pure", "std", "core", "impure", "posix", ""]:
        let path = if subdir.len > 0: nimLibPath / subdir / name & ".nim"
                   else: nimLibPath / name & ".nim"
        if fileExists(path):
          modulePathCache[moduleName] = path
          return path
    modulePathCache[moduleName] = ""
    return ""

  # 3. Local module — search in file's directory and project
  let parts = moduleName.replace("/", $DirSep)
  # a. Same directory
  let localPath = fileDir / parts & ".nim"
  if fileExists(localPath):
    modulePathCache[moduleName] = localPath
    return localPath
  # b. Project src directory
  if projectRoot.len > 0:
    let srcPath = projectRoot / "src" / parts & ".nim"
    if fileExists(srcPath):
      modulePathCache[moduleName] = srcPath
      return srcPath
    # Package structure: src/pkgname/module.nim
    let srcPath2 = projectRoot / "src" / projectRoot.lastPathPart / parts & ".nim"
    if fileExists(srcPath2):
      modulePathCache[moduleName] = srcPath2
      return srcPath2
  # c. Nimlib (non-std imports like "os", "json")
  if nimLibPath.len > 0:
    for subdir in ["pure", "std", "core", "impure", "posix", ""]:
      let path = if subdir.len > 0: nimLibPath / subdir / parts & ".nim"
                 else: nimLibPath / parts & ".nim"
      if fileExists(path):
        modulePathCache[moduleName] = path
        return path
  # d. Nimble packages
  for searchPath in nimSearchPaths:
    let path = searchPath / parts & ".nim"
    if fileExists(path):
      modulePathCache[moduleName] = path
      return path
    # Package: searchPath/name/name.nim
    let pkgPath = searchPath / parts / parts.lastPathPart & ".nim"
    if fileExists(pkgPath):
      modulePathCache[moduleName] = pkgPath
      return pkgPath

  modulePathCache[moduleName] = ""
  return ""

proc findDefinitionInText(text: string, word: string): (int, int) =
  let lines = text.split('\n')
  let patterns = [
    "proc " & word, "func " & word, "method " & word,
    "template " & word, "macro " & word, "iterator " & word,
    "converter " & word,
  ]
  # Search for proc/func/method/template/macro/iterator/converter definitions
  for i in 0..<lines.len:
    let stripped = lines[i].strip()
    for pattern in patterns:
      if stripped.startsWith(pattern):
        let afterLen = pattern.len
        if afterLen >= stripped.len or
           stripped[afterLen] in {'*', '(', '[', ' ', '\t', ':'}:
          let col = lines[i].find(pattern)
          if col >= 0:
            let nameCol = col + pattern.len - word.len
            return (i, nameCol)
  # Search for type definitions in type sections
  for i in 0..<lines.len:
    let stripped = lines[i].strip()
    # type Name = or Name* =
    if stripped.startsWith(word):
      let after = stripped[word.len..^1]
      if after.startsWith("*") or after.startsWith(" ") or after.startsWith("="):
        let rest = if after.startsWith("*"): after[1..^1].strip()
                   else: after.strip()
        if rest.startsWith("=") or rest.len == 0:
          # Check this is inside a type section or standalone
          let col = lines[i].find(word)
          if col >= 0:
            return (i, col)
  # Search for var/let/const definitions
  for i in 0..<lines.len:
    let stripped = lines[i].strip()
    for prefix in ["var ", "let ", "const "]:
      if stripped.startsWith(prefix & word):
        let after = stripped[prefix.len + word.len..^1]
        if after.len == 0 or after[0] in {'*', ':', '=', ' ', '\t'}:
          let col = lines[i].find(word)
          if col >= 0:
            return (i, col)
    # Standalone variable in var/let section (indented)
    if stripped.startsWith(word) and not stripped.startsWith("proc ") and
       not stripped.startsWith("func ") and not stripped.startsWith("type "):
      let after = stripped[word.len..^1]
      if after.startsWith("*") or (after.len > 0 and after[0] in {':', '='}):
        let rest = if after.startsWith("*"): after[1..^1].strip() else: after.strip()
        if rest.startsWith(":") or rest.startsWith("="):
          let indent = lines[i].len - stripped.len
          if indent > 0:  # indented = inside a var/let/const section
            let col = lines[i].find(word)
            if col >= 0:
              return (i, col)
  return (-1, -1)

proc parseTypes(text: string): seq[TypeInfo] =
  let lines = text.split('\n')
  for i in 0..<lines.len:
    let stripped = lines[i].strip()
    # Look for: Name = object of Base, Name* = object of Base, Name = ref object of Base
    var name = ""
    var rest = ""
    # Try to extract type name and rest
    for pattern in ["= object of ", "= ref object of ", "= object", "= ref object"]:
      let idx = stripped.find(pattern)
      if idx > 0:
        let beforeEq = stripped[0..<idx].strip()
        name = if beforeEq.endsWith("*"): beforeEq[0..^2].strip()
               else: beforeEq
        if pattern.endsWith("of "):
          rest = stripped[idx + pattern.len..^1].strip()
          # Remove trailing : or other chars
          var parentEnd = 0
          while parentEnd < rest.len and rest[parentEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
            inc parentEnd
          let parent = rest[0..<parentEnd]
          if name.len > 0 and parent.len > 0:
            let indent = lines[i].len - stripped.len
            var bodyIndent = indent + 2
            if i + 1 < lines.len:
              let nextLine = lines[i + 1]
              var nextIndent = 0
              for c in nextLine:
                if c == ' ': inc nextIndent
                elif c == '\t': nextIndent += 4
                else: break
              if nextIndent > indent: bodyIndent = nextIndent
            result.add(TypeInfo(name: name, parent: parent,
                                bodyStartLine: i + 1, bodyIndent: bodyIndent))
        elif name.len > 0:
          let indent = lines[i].len - stripped.len
          var bodyIndent = indent + 2
          if i + 1 < lines.len:
            let nextLine = lines[i + 1]
            var nextIndent = 0
            for c in nextLine:
              if c == ' ': inc nextIndent
              elif c == '\t': nextIndent += 4
              else: break
            if nextIndent > indent: bodyIndent = nextIndent
          result.add(TypeInfo(name: name, parent: "",
                              bodyStartLine: i + 1, bodyIndent: bodyIndent))
        break

proc findMethodForType(text: string, typeName: string, methodName: string): (int, int) =
  let lines = text.split('\n')
  # Search for proc/method/func with first param of typeName
  for i in 0..<lines.len:
    let stripped = lines[i].strip()
    for declKw in ["proc ", "func ", "method "]:
      let kwAndName = declKw & methodName
      if stripped.startsWith(kwAndName):
        let after = stripped[kwAndName.len..^1]
        let afterClean = if after.startsWith("*"): after[1..^1] else: after
        if afterClean.startsWith("(") or afterClean.startsWith("["):
          # Find the opening paren
          let parenStart = stripped.find('(')
          if parenStart >= 0:
            let parenContent = stripped[parenStart + 1..^1]
            # First parameter should be of typeName
            let colonIdx = parenContent.find(':')
            if colonIdx >= 0:
              let typeStr = parenContent[colonIdx + 1..^1].strip()
              let cleanType = if typeStr.startsWith("var "): typeStr[4..^1].strip() else: typeStr
              # Extract just the type name (before , or ) or ;)
              var typeEnd = 0
              while typeEnd < cleanType.len and cleanType[typeEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
                inc typeEnd
              let paramType = cleanType[0..<typeEnd]
              if paramType == typeName:
                let col = lines[i].find(methodName)
                if col >= 0:
                  return (i, col)
  return (-1, -1)

proc findMethodWithInheritance(text: string, typeName: string, methodName: string,
                                imports: seq[ImportInfo], fileDir: string,
                                visited: var HashSet[string],
                                depth: int = 0): (string, int, int) =
  if depth > 10: return ("", -1, -1)
  let key = typeName & "." & methodName
  if key in visited: return ("", -1, -1)
  visited.incl(key)

  # Search in current text
  let (foundLine, foundCol) = findMethodForType(text, typeName, methodName)
  if foundLine >= 0:
    return ("", foundLine, foundCol)

  # Find type and its parent
  let types = parseTypes(text)
  for t in types:
    if t.name == typeName and t.parent.len > 0:
      # Recurse into parent
      let (fp, bl, bc) = findMethodWithInheritance(text, t.parent, methodName,
                                                     imports, fileDir, visited, depth + 1)
      if bl >= 0: return (fp, bl, bc)
      # Try parent in imported modules
      for imp in imports:
        let modulePath = resolveNimModule(imp.module, fileDir)
        if modulePath.len > 0:
          let moduleText = readFile(modulePath)
          let (fp2, bl2, bc2) = findMethodWithInheritance(
            moduleText, t.parent, methodName,
            parseNimImports(moduleText, parentDir(modulePath)),
            parentDir(modulePath), visited, depth + 1)
          if bl2 >= 0:
            let resultPath = if fp2.len > 0: fp2 else: modulePath
            return (resultPath, bl2, bc2)

  # Type not found locally — try imports
  for imp in imports:
    let modulePath = resolveNimModule(imp.module, fileDir)
    if modulePath.len > 0:
      let moduleText = readFile(modulePath)
      let (fp, bl, bc) = findMethodWithInheritance(
        moduleText, typeName, methodName,
        parseNimImports(moduleText, parentDir(modulePath)),
        parentDir(modulePath), visited, depth + 1)
      if bl >= 0:
        let resultPath = if fp.len > 0: fp else: modulePath
        return (resultPath, bl, bc)

  return ("", -1, -1)

proc resolveQualifierType(text: string, qualifier: string, useLine: int): string =
  if qualifier.len > 0 and qualifier[0] in {'A'..'Z'}:
    return qualifier
  let lines = text.split('\n')
  # Search for assignment: qualifier = TypeName(
  for i in countdown(min(useLine, lines.len - 1), 0):
    let stripped = lines[i].strip()
    for prefix in ["var ", "let ", ""]:
      let target = prefix & qualifier
      if stripped.startsWith(target):
        let after = stripped[target.len..^1].strip()
        let rest = if after.startsWith("*"): after[1..^1].strip() else: after
        if rest.startsWith("="):
          let rhs = rest[1..^1].strip()
          var className = ""
          for c in rhs:
            if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: className.add(c)
            else: break
          if className.len > 0 and className[0] in {'A'..'Z'}:
            return className
        elif rest.startsWith(":"):
          # Type annotation: var x: TypeName = ...
          let typeStr = rest[1..^1].strip()
          var typeName = ""
          for c in typeStr:
            if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: typeName.add(c)
            else: break
          if typeName.len > 0 and typeName[0] in {'A'..'Z'}:
            return typeName
  # Search for type hint in proc parameters
  for i in countdown(min(useLine, lines.len - 1), 0):
    let ln = lines[i].strip()
    if ln.startsWith("proc ") or ln.startsWith("func ") or ln.startsWith("method "):
      let openParen = ln.find('(')
      let closeParen = ln.rfind(')')
      if openParen >= 0 and closeParen > openParen:
        let params = ln[openParen + 1..<closeParen]
        for param in params.split({',', ';'}):
          let p = param.strip()
          let colonIdx = p.find(':')
          if colonIdx >= 0:
            let paramName = p[0..<colonIdx].strip()
            let typeName = p[colonIdx + 1..^1].strip()
            if paramName == qualifier and typeName.len > 0:
              var baseType = typeName
              let bracketIdx = baseType.find('[')
              if bracketIdx >= 0: baseType = baseType[0..<bracketIdx]
              if baseType.startsWith("var "): baseType = baseType[4..^1].strip()
              return baseType
      break
  return ""

proc getDefinitionContext(text: string, line, col: int): (string, string) =
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
    # Check for Constructor(...).method pattern
    if qEnd >= 1 and ln[qEnd - 1] == ')':
      var depth = 1
      var qPos = qEnd - 2
      while qPos >= 0 and depth > 0:
        if ln[qPos] == ')': inc depth
        elif ln[qPos] == '(': dec depth
        dec qPos
      if depth == 0:
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
# Message I/O
# ---------------------------------------------------------------------------

proc readMessage(): string =
  var contentLength = -1
  while true:
    var line: string
    try:
      line = stdin.readLine().strip(chars = {'\r', '\n'})
    except EOFError:
      return ""
    if line.len == 0: break
    if line.startsWith("Content-Length:"):
      try: contentLength = parseInt(line.split(':')[1].strip())
      except ValueError: discard
  if contentLength <= 0: return ""
  var buf = newString(contentLength)
  let bytesRead = stdin.readBuffer(addr buf[0], contentLength)
  if bytesRead < contentLength: buf.setLen(bytesRead)
  return buf

proc sendMessage(msg: JsonNode) =
  let body = $msg
  stdout.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  stdout.flushFile()

proc sendResponse(id: JsonNode, resultNode: JsonNode) =
  sendMessage(%*{"jsonrpc": "2.0", "id": id, "result": resultNode})

proc sendNotification(meth: string, params: JsonNode) {.used.} =
  sendMessage(%*{"jsonrpc": "2.0", "method": meth, "params": params})

# ---------------------------------------------------------------------------
# Main server loop
# ---------------------------------------------------------------------------

proc main() =
  initLookupTables()
  var documents: seq[DocumentState]
  var running = true

  while running:
    let raw = readMessage()
    if raw.len == 0: break

    var msg: JsonNode
    try: msg = parseJson(raw)
    except JsonParsingError: continue

    let meth = msg.getOrDefault("method").getStr("")
    let id = msg.getOrDefault("id")

    case meth
    of "initialize":
      let params = msg.getOrDefault("params")
      if not params.isNil:
        let rootUri = params.getOrDefault("rootUri").getStr("")
        if rootUri.startsWith("file://"):
          projectRoot = rootUri[7..^1]
      initNimPaths()
      sendResponse(id, %*{
        "capabilities": {
          "textDocumentSync": 1,
          "semanticTokensProvider": {
            "legend": {
              "tokenTypes": ["keyword", "string", "number", "comment",
                             "function", "method", "type", "macro",
                             "builtinFunction", "operator", "parameter", "property",
                             "namespace", "builtinConstant", "decorator", "enumMember"],
              "tokenModifiers": []
            },
            "full": true,
            "range": true
          },
          "definitionProvider": true
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
          found = true; break
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
          documents.delete(i); break

    of "textDocument/semanticTokens/full":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      var text = ""
      for doc in documents:
        if doc.uri == uri: text = doc.text; break
      let (tokens, _) = tokenizeNimParallel(text)
      let data = encodeSemanticTokens(tokens)
      var dataJson = newJArray()
      for v in data: dataJson.add(%v)
      sendResponse(id, %*{"data": dataJson})

    of "textDocument/semanticTokens/range":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let rangeNode = params["range"]
      let startLine = rangeNode["start"]["line"].getInt()
      let endLine = rangeNode["end"]["line"].getInt()
      var text = ""
      for doc in documents:
        if doc.uri == uri: text = doc.text; break
      let tokens = tokenizeNimRange(text, startLine, endLine)
      let data = encodeSemanticTokens(tokens)
      var dataJson = newJArray()
      for v in data: dataJson.add(%v)
      sendResponse(id, %*{"data": dataJson})

    of "textDocument/definition":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let defLine = params["position"]["line"].getInt()
      let defCol = params["position"]["character"].getInt()
      var text = ""
      var filePath = ""
      for doc in documents:
        if doc.uri == uri:
          text = doc.text
          if uri.startsWith("file://"): filePath = uri[7..^1]
          break

      let fileDir = if filePath.len > 0: parentDir(filePath) else: projectRoot
      let (qualifier, name) = getDefinitionContext(text, defLine, defCol)

      if name.len == 0:
        sendResponse(id, newJArray())
      elif qualifier.len == 0:
        # No qualifier — try same-file first, then imports
        let (foundLine, foundCol) = findDefinitionInText(text, name)
        if foundLine >= 0:
          sendResponse(id, %*{
            "uri": uri,
            "range": {"start": {"line": foundLine, "character": foundCol},
                      "end": {"line": foundLine, "character": foundCol + name.len}}
          })
        else:
          var found = false
          let imports = parseNimImports(text, fileDir)
          for imp in imports:
            # Check from-import names
            if imp.names.len > 0:
              for n in imp.names:
                if n == name:
                  let modulePath = resolveNimModule(imp.module, fileDir)
                  if modulePath.len > 0:
                    let moduleText = readFile(modulePath)
                    let (mLine, mCol) = findDefinitionInText(moduleText, name)
                    if mLine >= 0:
                      sendResponse(id, %*{
                        "uri": "file://" & modulePath,
                        "range": {"start": {"line": mLine, "character": mCol},
                                  "end": {"line": mLine, "character": mCol + name.len}}
                      })
                      found = true; break
              if found: break
            else:
              # Bare import — check if name matches module name
              let modName = imp.module.split('/')[^1]
              let target = if imp.alias.len > 0: imp.alias else: modName
              if target == name:
                let modulePath = resolveNimModule(imp.module, fileDir)
                if modulePath.len > 0:
                  sendResponse(id, %*{
                    "uri": "file://" & modulePath,
                    "range": {"start": {"line": 0, "character": 0},
                              "end": {"line": 0, "character": 0}}
                  })
                  found = true; break
          # Try searching in all imported modules
          if not found:
            for imp in imports:
              if imp.names.len == 0:
                let modulePath = resolveNimModule(imp.module, fileDir)
                if modulePath.len > 0:
                  let moduleText = readFile(modulePath)
                  let (mLine, mCol) = findDefinitionInText(moduleText, name)
                  if mLine >= 0:
                    sendResponse(id, %*{
                      "uri": "file://" & modulePath,
                      "range": {"start": {"line": mLine, "character": mCol},
                                "end": {"line": mLine, "character": mCol + name.len}}
                    })
                    found = true; break
          if not found:
            sendResponse(id, newJArray())
      else:
        # Qualifier present (module.name or obj.method)
        var found = false
        let imports = parseNimImports(text, fileDir)

        # Try as module.name first
        for imp in imports:
          let modName = imp.module.split('/')[^1]
          let target = if imp.alias.len > 0: imp.alias else: modName
          if target == qualifier:
            let modulePath = resolveNimModule(imp.module, fileDir)
            if modulePath.len > 0:
              let moduleText = readFile(modulePath)
              let (mLine, mCol) = findDefinitionInText(moduleText, name)
              if mLine >= 0:
                sendResponse(id, %*{
                  "uri": "file://" & modulePath,
                  "range": {"start": {"line": mLine, "character": mCol},
                            "end": {"line": mLine, "character": mCol + name.len}}
                })
                found = true; break

        # Try as obj.method with type resolution + inheritance
        if not found:
          let className = resolveQualifierType(text, qualifier, defLine)
          if className.len > 0:
            var visited: HashSet[string]
            let (resultPath, mLine, mCol) = findMethodWithInheritance(
              text, className, name, imports, fileDir, visited)
            if mLine >= 0:
              if resultPath.len > 0:
                sendResponse(id, %*{
                  "uri": "file://" & resultPath,
                  "range": {"start": {"line": mLine, "character": mCol},
                            "end": {"line": mLine, "character": mCol + name.len}}
                })
              else:
                sendResponse(id, %*{
                  "uri": uri,
                  "range": {"start": {"line": mLine, "character": mCol},
                            "end": {"line": mLine, "character": mCol + name.len}}
                })
              found = true

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
          "jsonrpc": "2.0", "id": id,
          "error": {"code": -32601, "message": "Method not found: " & meth}
        })

main()
