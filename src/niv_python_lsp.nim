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

import std/[json, strutils, os, tables, osproc, sets, sequtils]

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
    ptDunder         # 17 - __name__, __init__, etc.

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

  ImportInfo = object
    module: string
    name: string
    alias: string

  ClassInfo = object
    name: string
    bases: seq[string]
    bodyStartLine: int
    bodyIndent: int

  KnownSymbols = object
    types: HashSet[string]
    functions: HashSet[string]
    enums: HashSet[string]
    localClasses: Table[string, ClassInfo]  # className → ClassInfo for current doc
    symbolModules: Table[string, string]  # symbolName → modulePath
    imports: seq[ImportInfo]

  DocumentState = object
    uri: string
    text: string
    version: int
    known: KnownSymbols
    lines: seq[string]

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
  stDunder = 17

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
  "case", "def", "del", "elif", "else", "except", "finally", "for", "from",
  "global", "if", "import", "lambda", "match", "nonlocal", "pass", "raise",
  "return", "try", "while", "with", "yield",
]

const pythonKeywordOperators = ["and", "or", "not", "in", "is"]

const pythonBuiltinConstants = ["True", "False", "None"]

const pythonBuiltinTypes = [
  "int", "str", "float", "list", "dict", "set", "tuple", "bool",
  "bytes", "bytearray", "memoryview", "complex", "frozenset", "object",
  # typing module
  "Optional", "Union", "List", "Dict", "Set", "Tuple", "FrozenSet",
  "Sequence", "Mapping", "MutableMapping", "MutableSequence", "MutableSet",
  "Iterable", "Iterator", "Generator", "Coroutine", "AsyncIterator",
  "AsyncGenerator", "Awaitable", "Callable", "Type", "ClassVar",
  "Any", "NoReturn", "Final", "Literal", "TypeVar", "Generic",
  "Protocol", "TypedDict", "NamedTuple", "Annotated", "TypeAlias",
  "TypeGuard", "ParamSpec", "Concatenate", "Unpack", "Self",
  "Never", "LiteralString", "Required", "NotRequired", "OrderedDict",
  "DefaultDict", "Counter", "Deque", "ChainMap",
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
let selfParamSet = ["self", "cls"].toHashSet()

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

proc tokenizePython(text: string, startLine: int = 0, endLine: int = int.high;
                    known: KnownSymbols = default(KnownSymbols)): (seq[PythonToken], seq[DiagInfo]) =
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

  # Function parameter tracking (only for definitions: def/class)
  var inFuncParams = false
  var funcParamDepth = 0
  var isFirstParam = true
  var afterParamColon = false
  var expectParam = false  # after * or ** prefix
  var expectDefParams = false  # true after def name, waiting for '('

  # Import tracking: detect 'import' and 'from' lines
  var inImportLine = false  # after 'import' keyword
  var inFromLine = false    # after 'from' keyword, before 'import'
  var inImportParens = false  # inside parenthesized import list
  var afterDot = false      # identifier after a dot
  var lastIdent = ""        # last seen identifier (for enum member detection)

  # Function call parenthesis depth (for keyword argument detection)
  var callDepth = 0

  proc isIdentChar(c: char): bool =
    c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

  proc isUpperConst(s: string): bool =
    for c in s:
      if c notin {'A'..'Z', '0'..'9', '_'}: return false
    return s.len > 0

  proc isDunder(s: string): bool =
    if s.len < 5: return false
    if s[0] != '_' or s[1] != '_' or s[^1] != '_' or s[^2] != '_': return false
    for i in 2..<s.len - 2:
      if s[i] notin {'a'..'z', '_'}: return false
    return true

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
        if not inImportParens:
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
        lastIdent = word

        # Classify the identifier
        if word == "def" or word == "class":
          tokens.add(PythonToken(kind: ptKeyword, line: sLine, col: sCol, length: length))
          lastKeyword = word
        elif word == "import":
          tokens.add(PythonToken(kind: ptKeyword, line: sLine, col: sCol, length: length))
          if inFromLine:
            inFromLine = false
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
          expectDefParams = true
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
        elif inImportLine and not inFromLine:
          # Module name after bare 'import'
          tokens.add(PythonToken(kind: ptNamespace, line: sLine, col: sCol, length: length))
        elif inFromLine:
          # Module name after 'from'
          tokens.add(PythonToken(kind: ptNamespace, line: sLine, col: sCol, length: length))
        elif wasDot:
          # Identifier after dot → enum member, method call, or property
          if lastIdent in known.enums:
            tokens.add(PythonToken(kind: ptBuiltinConst, line: sLine, col: sCol, length: length))
          else:
            var lookPos = pos
            while lookPos < text.len and text[lookPos] in {' ', '\t'}:
              inc lookPos
            if lookPos < text.len and text[lookPos] == '(':
              tokens.add(PythonToken(kind: ptFunction, line: sLine, col: sCol, length: length))
            else:
              tokens.add(PythonToken(kind: ptProperty, line: sLine, col: sCol, length: length))
        elif callDepth > 0 and (block:
          var lp = pos
          while lp < text.len and text[lp] in {' ', '\t'}: inc lp
          lp < text.len and text[lp] == '=' and
            (lp + 1 >= text.len or text[lp + 1] != '=')):
          # Keyword argument: identifier= inside function call (not ==)
          tokens.add(PythonToken(kind: ptParameter, line: sLine, col: sCol, length: length))
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
        elif word in selfParamSet:
          tokens.add(PythonToken(kind: ptSelfParam, line: sLine, col: sCol, length: length))
        elif word in known.types:
          tokens.add(PythonToken(kind: ptType, line: sLine, col: sCol, length: length))
        elif word in known.functions:
          tokens.add(PythonToken(kind: ptFunction, line: sLine, col: sCol, length: length))
        else:
          # Lookahead: identifier followed by '(' → function call
          var lookPos = pos
          while lookPos < text.len and text[lookPos] in {' ', '\t'}:
            inc lookPos
          if lookPos < text.len and text[lookPos] == '(':
            tokens.add(PythonToken(kind: ptFunction, line: sLine, col: sCol, length: length))
          elif isDunder(word):
            tokens.add(PythonToken(kind: ptDunder, line: sLine, col: sCol, length: length))
          elif isUpperConst(word):
            tokens.add(PythonToken(kind: ptBuiltinConst, line: sLine, col: sCol, length: length))
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
      tokens.add(PythonToken(kind: ptDecorator, line: sLine, col: sCol, length: 1))

    # Parentheses (track function definition params and call depth)
    of '(':
      lastKeyword = ""
      afterDot = false
      if inImportLine:
        inImportParens = true
      elif inFuncParams:
        inc funcParamDepth
      elif expectDefParams and funcParamDepth == 0 and tokens.len > 0 and
           tokens[^1].kind in {ptFunction, ptMethod}:
        inFuncParams = true
        funcParamDepth = 1
        isFirstParam = true
        afterParamColon = false
        expectParam = false
      else:
        inc callDepth
      expectDefParams = false
      advance()
    of ')':
      lastKeyword = ""
      afterDot = false
      if inImportParens:
        inImportParens = false
        inImportLine = false
      elif inFuncParams:
        dec funcParamDepth
        if funcParamDepth <= 0:
          inFuncParams = false
          funcParamDepth = 0
      elif callDepth > 0:
        dec callDepth
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

  if tokens.len > 0:
    # Filter tokens to requested range [startLine, endLine]
    var lo = 0
    while lo < tokens.len and tokens[lo].line < startLine: inc lo
    var hi = tokens.len - 1
    while hi >= lo and tokens[hi].line > endLine: dec hi
    if lo > 0 or hi < tokens.len - 1:
      if hi >= lo:
        tokens = tokens[lo..hi]
      else:
        tokens = @[]
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
      of ptDunder: stDunder
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
      "python3 -c \"import sys; print('\\n'.join(sys.path))\"")
    if exitCode == 0:
      for line in output.strip().splitLines():
        let p = line.strip()
        if p.len == 0:
          pythonSearchPaths.add(getCurrentDir())
        elif dirExists(p):
          pythonSearchPaths.add(p)
  except OSError:
    discard

proc collectImportNames(lines: openArray[string], startIdx: int, firstPart: string): (string, int) =
  ## Collect names from potentially multiline parenthesized import.
  ## Returns (names string with parens stripped, last consumed line index).
  var raw = firstPart
  if not raw.startsWith("("):
    return (raw, startIdx)
  raw = raw[1..^1]  # strip opening paren
  let closeIdx = raw.find(')')
  if closeIdx >= 0:
    return (raw[0..<closeIdx], startIdx)
  var idx = startIdx + 1
  while idx < lines.len:
    let ln = lines[idx].strip()
    let ci = ln.find(')')
    if ci >= 0:
      if ci > 0:
        raw.add(", " & ln[0..<ci])
      return (raw, idx)
    if ln.len > 0:
      raw.add(", " & ln)
    inc idx
  return (raw, idx)

proc addParsedImports(result: var seq[ImportInfo], module: string, names: string) =
  for part in names.split(','):
    let trimmed = part.strip()
    if trimmed.len == 0: continue
    let asParts = trimmed.split(" as ")
    let name = asParts[0].strip()
    if name.len == 0: continue
    let alias = if asParts.len > 1: asParts[1].strip() else: ""
    result.add(ImportInfo(module: module, name: name, alias: alias))

proc parseImports(lines: seq[string], packageDir: string = ""): seq[ImportInfo] =
  var i = 0

  while i < lines.len:
    let line = lines[i].strip()
    if line.startsWith("from "):
      let rest = line[5..^1].strip()
      let importIdx = rest.find(" import ")
      if importIdx < 0:
        inc i
        continue
      var module = rest[0..<importIdx].strip()
      if module.startsWith(".") and packageDir.len > 0:
        var dots = 0
        while dots < module.len and module[dots] == '.': inc dots
        var baseDir = packageDir
        for _ in 1..<dots: baseDir = parentDir(baseDir)
        let relName = module[dots..^1].strip()
        if relName.len > 0:
          let relPath = relName.replace(".", "/")
          let asFile = baseDir / relPath & ".py"
          if fileExists(asFile): module = asFile
          else:
            let asPackage = baseDir / relPath / "__init__.py"
            if fileExists(asPackage): module = asPackage
            else:
              inc i
              continue
        else:
          # from . import name — name could be a submodule file
          let namesRaw = rest[importIdx + 8..^1].strip()
          let (names, endIdx) = collectImportNames(lines, i, namesRaw)
          i = endIdx
          for part in names.split(','):
            let trimmed = part.strip()
            if trimmed.len == 0: continue
            let asParts = trimmed.split(" as ")
            let name = asParts[0].strip()
            let alias = if asParts.len > 1: asParts[1].strip() else: ""
            let subFile = baseDir / name & ".py"
            let subPkg = baseDir / name / "__init__.py"
            if fileExists(subFile):
              result.add(ImportInfo(module: subFile, name: name, alias: alias))
            elif fileExists(subPkg):
              result.add(ImportInfo(module: subPkg, name: name, alias: alias))
            else:
              # Might be a name in __init__.py
              let initFile = baseDir / "__init__.py"
              if fileExists(initFile):
                result.add(ImportInfo(module: initFile, name: name, alias: alias))
          inc i
          continue
      elif module.startsWith("."):
        inc i
        continue
      let namesRaw = rest[importIdx + 8..^1].strip()
      let (names, endIdx) = collectImportNames(lines, i, namesRaw)
      i = endIdx
      addParsedImports(result, module, names)
    elif line.startsWith("import "):
      let rest = line[7..^1].strip()
      for part in rest.split(','):
        let trimmed = part.strip()
        if trimmed.len == 0: continue
        let asParts = trimmed.split(" as ")
        let module = asParts[0].strip()
        let alias = if asParts.len > 1: asParts[1].strip() else: ""
        result.add(ImportInfo(module: module, name: "", alias: alias))
    inc i

proc parseClasses(lines: seq[string]): seq[ClassInfo] =
  ## Extract class definitions with their base classes
  for i in 0..<lines.len:
    let ln = lines[i]
    var lineIndent = 0
    for c in ln:
      if c == ' ': inc lineIndent
      elif c == '\t': lineIndent += 4
      else: break
    let stripped = ln.strip()
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

proc findClassInText(lines: seq[string], name: string): (bool, ClassInfo) =
  ## Find a specific class by name in lines. Stops at first match.
  for i in 0..<lines.len:
    let ln = lines[i]
    var lineIndent = 0
    for c in ln:
      if c == ' ': inc lineIndent
      elif c == '\t': lineIndent += 4
      else: break
    let stripped = ln.strip()
    if stripped.startsWith("class "):
      var rest = stripped[6..^1]
      var nameEnd = 0
      while nameEnd < rest.len and rest[nameEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        inc nameEnd
      if nameEnd == 0: continue
      let className = rest[0..<nameEnd]
      if className != name: continue
      var bases: seq[string]
      if nameEnd < rest.len and rest[nameEnd] == '(':
        let closeIdx = rest.find(')', nameEnd)
        if closeIdx > nameEnd + 1:
          let basesStr = rest[nameEnd + 1..<closeIdx]
          for base in basesStr.split(','):
            let b = base.strip()
            let bracketIdx = b.find('[')
            let baseName = if bracketIdx >= 0: b[0..<bracketIdx].strip() else: b
            if baseName.len > 0:
              bases.add(baseName)
      var bodyIndent = lineIndent + 4
      if i + 1 < lines.len:
        let nextLine = lines[i + 1]
        var nextIndent = 0
        for c in nextLine:
          if c == ' ': inc nextIndent
          elif c == '\t': nextIndent += 4
          else: break
        if nextIndent > lineIndent:
          bodyIndent = nextIndent
      return (true, ClassInfo(
        name: className, bases: bases,
        bodyStartLine: i + 1, bodyIndent: bodyIndent
      ))
  return (false, ClassInfo())

var modulePathCache: Table[string, string]
var moduleClassCache: Table[string, Table[string, ClassInfo]]
var moduleLinesCache: Table[string, seq[string]]

proc getModuleLines(modulePath: string): seq[string] =
  ## Get lines of a module file, using cache. Reads and splits on first access.
  if modulePath in moduleLinesCache:
    return moduleLinesCache[modulePath]
  var moduleText: string
  try:
    moduleText = readFile(modulePath)
  except IOError:
    return @[]
  result = moduleText.split('\n')
  moduleLinesCache[modulePath] = result

proc getModuleClassInfo(modulePath: string, className: string): (bool, ClassInfo) =
  ## Get ClassInfo from a module file, using cache. Parses all classes on first access.
  if modulePath in moduleClassCache:
    if className in moduleClassCache[modulePath]:
      return (true, moduleClassCache[modulePath][className])
    return (false, ClassInfo())
  let moduleLines = getModuleLines(modulePath)
  if moduleLines.len == 0 and not fileExists(modulePath):
    return (false, ClassInfo())
  var classTable: Table[string, ClassInfo]
  for ci in parseClasses(moduleLines):
    classTable[ci.name] = ci
  moduleClassCache[modulePath] = classTable
  if className in classTable:
    return (true, classTable[className])
  return (false, ClassInfo())

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
  modulePathCache[moduleName] = ""
  return ""

var moduleImportCache: Table[string, seq[ImportInfo]]

proc getModuleImports(modulePath: string): seq[ImportInfo] =
  ## Get imports from a module file, using cache. Parses on first access.
  if modulePath in moduleImportCache:
    return moduleImportCache[modulePath]
  let moduleLines = getModuleLines(modulePath)
  result = parseImports(moduleLines, parentDir(modulePath))
  moduleImportCache[modulePath] = result

proc findClassInfo(lines: seq[string], name: string,
                    known: KnownSymbols = default(KnownSymbols),
                    imports: seq[ImportInfo] = @[]): (bool, ClassInfo, string) =
  ## Find class by name. Searches localClasses, then lines, then symbolModules, then imports.
  ## Returns (found, classInfo, filePath). filePath="" means found in given lines.
  if name in known.localClasses:
    return (true, known.localClasses[name], "")
  if name in known.symbolModules:
    let modulePath = known.symbolModules[name]
    if modulePath.len > 0:
      let (mFound, mCi) = getModuleClassInfo(modulePath, name)
      if mFound: return (true, mCi, modulePath)
  for imp in imports:
    let target = if imp.alias.len > 0: imp.alias else: imp.name
    if target == name and imp.name.len > 0:
      let modulePath = resolveModulePath(imp.module)
      if modulePath.len > 0:
        let (iFound, iCi) = getModuleClassInfo(modulePath, imp.name)
        if iFound: return (true, iCi, modulePath)
  let (found, ci) = findClassInText(lines, name)
  if found: return (true, ci, "")
  return (false, ClassInfo(), "")

proc isPascalCase(s: string): bool =
  if s.len == 0 or s[0] notin {'A'..'Z'}: return false
  for i in 1..<s.len:
    if s[i] in {'a'..'z'}: return true
  return false

const enumBaseSet = ["Enum", "IntEnum", "StrEnum", "Flag", "IntFlag"].toHashSet()

type SymbolKind = enum
  skClass, skEnum, skFunction, skUnknown

var symbolCheckCache: Table[string, Table[string, SymbolKind]]

proc findSymbolInModule(modulePath: string, name: string, depth: int = 0): SymbolKind =
  ## Check if `name` is a class or function defined or re-exported in the module.
  ## Follows import chains up to depth 5.
  if depth > 5: return skUnknown
  if modulePath in symbolCheckCache and name in symbolCheckCache[modulePath]:
    return symbolCheckCache[modulePath][name]
  if modulePath notin symbolCheckCache:
    symbolCheckCache[modulePath] = initTable[string, SymbolKind]()
  symbolCheckCache[modulePath][name] = skUnknown  # prevent cycles
  # Use moduleClassCache for class lookup
  let (hasClass, ci) = getModuleClassInfo(modulePath, name)
  if hasClass:
    let kind = if ci.bases.anyIt(it in enumBaseSet): skEnum else: skClass
    symbolCheckCache[modulePath][name] = kind
    return kind
  # Function check — early exit, no seq allocation
  let moduleLines = getModuleLines(modulePath)
  for i in 0..<moduleLines.len:
    let mln = moduleLines[i]
    if mln.len > 4 and mln[0] == 'd' and mln[1] == 'e' and mln[2] == 'f' and mln[3] == ' ':
      var nameEnd = 0
      while nameEnd < mln.len - 4 and mln[4 + nameEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        inc nameEnd
      if nameEnd > 0 and mln[4..<4 + nameEnd] == name:
        symbolCheckCache[modulePath][name] = skFunction
        return skFunction
  # Check imports in this module for re-exports (use cache)
  for imp in getModuleImports(modulePath):
    if imp.name == name:
      let impPath = resolveModulePath(imp.module)
      if impPath.len > 0:
        let kind = findSymbolInModule(impPath, name, depth + 1)
        if kind != skUnknown:
          symbolCheckCache[modulePath][name] = kind
          return kind
  return skUnknown

proc collectKnownSymbols*(textLines: seq[string], filePath: string = ""): KnownSymbols =
  ## Single pass over lines to collect classes, top-level functions, and imports.
  let packageDir = if filePath.len > 0: parentDir(filePath) else: ""
  var i = 0
  while i < textLines.len:
    let tln = textLines[i]
    var leadingWs = 0
    for c in tln:
      if c in {' ', '\t'}: inc leadingWs
      else: break
    if leadingWs >= tln.len:
      inc i
      continue
    let firstChar = tln[leadingWs]
    if firstChar notin {'c', 'd', 'f', 'i'}:
      inc i
      continue
    let stripped = tln[leadingWs..^1].strip(leading = false)
    if stripped.startsWith("class "):
      var rest = stripped[6..^1]
      var nameEnd = 0
      while nameEnd < rest.len and rest[nameEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        inc nameEnd
      if nameEnd > 0:
        let className = rest[0..<nameEnd]
        result.types.incl(className)
        var bases: seq[string]
        if nameEnd < rest.len and rest[nameEnd] == '(':
          let closeIdx = rest.find(')', nameEnd)
          if closeIdx > nameEnd + 1:
            let basesStr = rest[nameEnd + 1..<closeIdx]
            for base in basesStr.split(','):
              let b = base.strip()
              let bracketIdx = b.find('[')
              let baseName = if bracketIdx >= 0: b[0..<bracketIdx].strip() else: b
              if baseName.len > 0:
                bases.add(baseName)
              if baseName in enumBaseSet:
                result.enums.incl(className)
        var lineIndent = 0
        for c in textLines[i]:
          if c == ' ': inc lineIndent
          elif c == '\t': lineIndent += 4
          else: break
        var bodyIndent = lineIndent + 4
        if i + 1 < textLines.len:
          let nextLine = textLines[i + 1]
          var nextIndent = 0
          for c in nextLine:
            if c == ' ': inc nextIndent
            elif c == '\t': nextIndent += 4
            else: break
          if nextIndent > lineIndent:
            bodyIndent = nextIndent
        result.localClasses[className] = ClassInfo(
          name: className, bases: bases,
          bodyStartLine: i + 1, bodyIndent: bodyIndent
        )
    elif stripped.startsWith("def ") and textLines[i][0] == 'd':
      var rest = stripped[4..^1]
      var nameEnd = 0
      while nameEnd < rest.len and rest[nameEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        inc nameEnd
      if nameEnd > 0:
        result.functions.incl(rest[0..<nameEnd])
    elif stripped.startsWith("from "):
      let rest = stripped[5..^1].strip()
      let importIdx = rest.find(" import ")
      if importIdx < 0:
        inc i
        continue
      var module = rest[0..<importIdx].strip()
      if module.startsWith(".") and packageDir.len > 0:
        var dots = 0
        while dots < module.len and module[dots] == '.': inc dots
        var baseDir = packageDir
        for _ in 1..<dots: baseDir = parentDir(baseDir)
        let relName = module[dots..^1].strip()
        if relName.len > 0:
          let relPath = relName.replace(".", "/")
          let asFile = baseDir / relPath & ".py"
          if fileExists(asFile): module = asFile
          else:
            let asPackage = baseDir / relPath / "__init__.py"
            if fileExists(asPackage): module = asPackage
            else:
              inc i
              continue
        else:
          let namesRaw = rest[importIdx + 8..^1].strip()
          let (names, endIdx) = collectImportNames(textLines, i, namesRaw)
          i = endIdx
          for part in names.split(','):
            let trimmed = part.strip()
            if trimmed.len == 0: continue
            let asParts = trimmed.split(" as ")
            let name = asParts[0].strip()
            let alias = if asParts.len > 1: asParts[1].strip() else: ""
            let subFile = baseDir / name & ".py"
            let subPkg = baseDir / name / "__init__.py"
            if fileExists(subFile):
              result.imports.add(ImportInfo(module: subFile, name: name, alias: alias))
            elif fileExists(subPkg):
              result.imports.add(ImportInfo(module: subPkg, name: name, alias: alias))
            else:
              let initFile = baseDir / "__init__.py"
              if fileExists(initFile):
                result.imports.add(ImportInfo(module: initFile, name: name, alias: alias))
          inc i
          continue
      elif module.startsWith("."):
        inc i
        continue
      let namesRaw = rest[importIdx + 8..^1].strip()
      let (names, endIdx) = collectImportNames(textLines, i, namesRaw)
      i = endIdx
      addParsedImports(result.imports, module, names)
    elif stripped.startsWith("import "):
      let rest = stripped[7..^1].strip()
      for part in rest.split(','):
        let trimmed = part.strip()
        if trimmed.len == 0: continue
        let asParts = trimmed.split(" as ")
        let module = asParts[0].strip()
        let alias = if asParts.len > 1: asParts[1].strip() else: ""
        result.imports.add(ImportInfo(module: module, name: "", alias: alias))
    inc i
  for imp in result.imports:
    if imp.name.len == 0: continue
    let target = if imp.alias.len > 0: imp.alias else: imp.name
    let modulePath = resolveModulePath(imp.module)
    if modulePath.len > 0:
      result.symbolModules[target] = modulePath
      let kind = findSymbolInModule(modulePath, imp.name)
      case kind
      of skClass: result.types.incl(target)
      of skEnum:
        result.types.incl(target)
        result.enums.incl(target)
      of skFunction: result.functions.incl(target)
      of skUnknown:
        if isPascalCase(imp.name):
          result.types.incl(target)
    elif isPascalCase(imp.name):
      result.types.incl(target)

proc findDefinitionInText(lines: seq[string], word: string): (int, int) =
  ## Find `def word` or `class word` in lines. Returns (line, col) or (-1, -1).
  ## Single pass: def/class has priority over assignment.
  let defPattern = "def " & word
  let classPattern = "class " & word
  var assignLine = -1
  var assignCol = -1
  for i in 0..<lines.len:
    let ln = lines[i]
    var leadingWs = 0
    for c in ln:
      if c in {' ', '\t'}: inc leadingWs
      else: break
    let stripped = ln[leadingWs..^1].strip(leading = false)
    for pattern in [defPattern, classPattern]:
      if stripped.startsWith(pattern):
        let afterLen = pattern.len
        if afterLen >= stripped.len or
           stripped[afterLen] in {'(', ':', ' ', '\t'}:
          let nameCol = leadingWs + pattern.len - word.len
          return (i, nameCol)
    if assignLine < 0 and stripped.startsWith(word) and stripped.len > word.len:
      let after = stripped[word.len..^1].strip()
      if after.startsWith("=") and not after.startsWith("=="):
        assignLine = i
        assignCol = leadingWs
  if assignLine >= 0:
    return (assignLine, assignCol)
  return (-1, -1)

proc findDefinitionViaKnown(name: string, known: KnownSymbols): (string, int, int) =
  ## Find definition of name using cached module path from KnownSymbols.
  if name notin known.symbolModules: return ("", -1, -1)
  let modulePath = known.symbolModules[name]
  let moduleLines = getModuleLines(modulePath)
  let (ml, mc) = findDefinitionInText(moduleLines, name)
  if ml >= 0:
    return (modulePath, ml, mc)
  return ("", -1, -1)

proc findMemberInClassBody(lines: seq[string], classInfo: ClassInfo, memberName: string): (int, int) =
  ## Search for method (def name) or attribute (self.name/cls.name/class-level) in class body
  let defPattern = "def " & memberName
  let selfPattern = "self." & memberName
  let clsPattern = "cls." & memberName
  const selfDotPos = 4  # "self." → dot at index 4
  const clsDotPos = 3   # "cls." → dot at index 3

  for i in classInfo.bodyStartLine..<lines.len:
    let ln = lines[i]
    var indent = 0
    var leadingWs = 0
    for c in ln:
      if c == ' ': inc indent; inc leadingWs
      elif c == '\t': indent += 4; inc leadingWs
      else: break
    let stripped = ln[leadingWs..^1].strip(leading = false)
    if stripped.len > 0 and indent < classInfo.bodyIndent:
      break

    # Method: def memberName(
    if stripped.startsWith(defPattern):
      let afterLen = defPattern.len
      if afterLen >= stripped.len or stripped[afterLen] in {'(', ':', ' ', '\t'}:
        return (i, leadingWs + 4)  # +4 to skip "def "

    # Attribute assignment: self.memberName = / self.memberName: / cls.memberName = / cls.memberName:
    for (pattern, dotPos) in [(selfPattern, selfDotPos), (clsPattern, clsDotPos)]:
      let idx = stripped.find(pattern)
      if idx >= 0:
        let afterLen = idx + pattern.len
        if afterLen < stripped.len and
           stripped[afterLen] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
          # Must be an assignment or annotation, not just usage
          let rest = stripped[afterLen..^1].strip()
          if rest.len > 0 and rest[0] in {'=', ':'}:
            if rest[0] == '=' and rest.len > 1 and rest[1] == '=':
              discard  # == is comparison, skip
            else:
              return (i, leadingWs + idx + dotPos + 1)

    # Class-level attribute: memberName = ... or memberName: type
    if indent == classInfo.bodyIndent and stripped.startsWith(memberName):
      let afterLen = memberName.len
      if afterLen < stripped.len and
         stripped[afterLen] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        let rest = stripped[afterLen..^1].strip()
        if rest.len > 0 and rest[0] in {'=', ':'}:
          if rest[0] == '=' and rest.len > 1 and rest[1] == '=':
            discard
          else:
            return (i, indent)

  return (-1, -1)

proc findMemberWithMRO(lines: seq[string], className: string, methodName: string,
                        imports: seq[ImportInfo], visited: var HashSet[string],
                        known: KnownSymbols = default(KnownSymbols),
                        depth: int = 0): (string, int, int) =
  ## Search for method in class and its bases (MRO). Returns (filePath, line, col).
  ## filePath="" means current file.
  if depth > 10: return ("", -1, -1)
  let key = className & "." & methodName
  if key in visited: return ("", -1, -1)
  visited.incl(key)

  let (classFound, cls, classPath) = findClassInfo(lines, className, known, imports)
  if not classFound: return ("", -1, -1)

  let workLines = if classPath.len > 0: getModuleLines(classPath) else: lines

  let (foundLine, foundCol) = findMemberInClassBody(workLines, cls, methodName)
  if foundLine >= 0:
    return (classPath, foundLine, foundCol)

  # Not found → search in base classes
  let workImports = if classPath.len > 0: getModuleImports(classPath) else: imports
  for base in cls.bases:
    let (baseFound, baseCi, basePath) = findClassInfo(workLines, base, known, workImports)
    if not baseFound: continue
    let bLines = if basePath.len > 0: getModuleLines(basePath) else: workLines
    let bImports = if basePath.len > 0: getModuleImports(basePath) else: workImports
    let (fp, bl, bc) = findMemberWithMRO(bLines, baseCi.name, methodName, bImports, visited, known, depth + 1)
    if bl >= 0:
      let resultPath = if fp.len > 0: fp
                        elif basePath.len > 0: basePath
                        elif classPath.len > 0: classPath
                        else: ""
      return (resultPath, bl, bc)
  return ("", -1, -1)

proc findMemberTransitive(className: string, memberName: string,
                           imports: seq[ImportInfo],
                           visitedPaths: var HashSet[string]): (string, int, int) =
  ## Search for member through transitive imports (no depth limit).
  for imp in imports:
    let modulePath = resolveModulePath(imp.module)
    if modulePath.len == 0 or modulePath in visitedPaths: continue
    visitedPaths.incl(modulePath)
    # Quick check: does this module define the target class?
    let (hasClass, _) = getModuleClassInfo(modulePath, className)
    let moduleImports = getModuleImports(modulePath)
    if hasClass:
      # Class found — do full MRO search (needs file lines)
      let moduleLines = getModuleLines(modulePath)
      var visited: HashSet[string]
      let (fp, ml, mc) = findMemberWithMRO(
        moduleLines, className, memberName, moduleImports, visited)
      if ml >= 0:
        let resultPath = if fp.len > 0: fp else: modulePath
        return (resultPath, ml, mc)
    # Recurse into this module's imports
    let (rfp, rml, rmc) = findMemberTransitive(
      className, memberName, moduleImports, visitedPaths)
    if rml >= 0: return (rfp, rml, rmc)
  return ("", -1, -1)

proc findEnclosingClass(lines: seq[string], useLine: int): string =
  ## Find the class that encloses the given line by comparing indentation.
  ## Single backward scan: find def indent, then continue to find class.
  var defIndent = -1
  for i in countdown(min(useLine, lines.len - 1), 0):
    let ln = lines[i]
    var indent = 0
    var leadingWs = 0
    for c in ln:
      if c == ' ': inc indent; inc leadingWs
      elif c == '\t': indent += 4; inc leadingWs
      else: break
    if leadingWs >= ln.len: continue
    let stripped = ln[leadingWs..^1].strip(leading = false)
    if defIndent < 0:
      if stripped.startsWith("def "):
        defIndent = indent
    else:
      if stripped.startsWith("class "):
        if indent < defIndent:
          let afterClass = stripped[6..^1]
          var name = ""
          for c in afterClass:
            if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
              name.add(c)
            else: break
          return name
  return ""

proc resolveQualifierType(lines: seq[string], qualifier: string, useLine: int): string =
  ## Try to determine the type of a variable.
  ## Returns class name or "".
  # 1. self/cls → find enclosing class
  if qualifier == "self" or qualifier == "cls":
    return findEnclosingClass(lines, useLine)

  # 2. If qualifier starts with uppercase → likely a class itself
  if qualifier.len > 0 and qualifier[0] in {'A'..'Z'}:
    return qualifier

  # 3. Single backward scan: assignment + parameter type hint
  let qFirstChar = qualifier[0]
  for i in countdown(min(useLine, lines.len - 1), 0):
    let ln = lines[i]
    var leadingWs = 0
    for c in ln:
      if c in {' ', '\t'}: inc leadingWs
      else: break
    let stripped = ln[leadingWs..^1].strip(leading = false)
    if stripped.len == 0: continue
    # Check assignment: qualifier = ClassName(
    if stripped[0] == qFirstChar and stripped.startsWith(qualifier) and stripped.len > qualifier.len:
      let afterVar = stripped[qualifier.len..^1].strip()
      if afterVar.startsWith("=") and not afterVar.startsWith("=="):
        let rhs = afterVar[1..^1].strip()
        var className = ""
        for c in rhs:
          if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
            className.add(c)
          else: break
        if className.len > 0 and className[0] in {'A'..'Z'}:
          return className
    # Check function parameter type hint
    if stripped.startsWith("def "):
      let openParen = stripped.find('(')
      let closeParen = stripped.rfind(')')
      if openParen >= 0 and closeParen > openParen:
        let params = stripped[openParen + 1..<closeParen]
        for param in params.split(','):
          let p = param.strip()
          let colonIdx = p.find(':')
          if colonIdx >= 0:
            let paramName = p[0..<colonIdx].strip()
            let typeName = p[colonIdx + 1..^1].strip()
            let eqIdx = typeName.find('=')
            let cleanType = if eqIdx >= 0: typeName[0..<eqIdx].strip() else: typeName
            if paramName == qualifier and cleanType.len > 0:
              var baseType = cleanType
              let bracketIdx = baseType.find('[')
              if bracketIdx >= 0:
                baseType = baseType[0..<bracketIdx]
              if baseType == "Optional" or baseType == "List" or baseType == "Dict":
                discard
              else:
                return baseType
      break  # only check the immediately enclosing function
  return ""

proc resolveAttributeType(lines: seq[string], className: string, attrName: string,
                          imports: seq[ImportInfo], visited: var HashSet[string],
                          known: KnownSymbols = default(KnownSymbols),
                          depth: int = 0): string =
  ## Determine the type of className.attrName by scanning the class body.
  ## Returns the type name or "".
  if depth > 10: return ""
  let key = className & "." & attrName
  if key in visited: return ""
  visited.incl(key)

  const identChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  const wrapperTypes = ["Optional", "List", "Dict", "Set", "Tuple", "Union",
                        "Sequence", "Iterable"]

  let (classFound, cls, classPath) = findClassInfo(lines, className, known, imports)
  if not classFound: return ""

  let workLines = if classPath.len > 0: getModuleLines(classPath) else: lines
  let selfPattern = "self." & attrName
  let clsPattern = "cls." & attrName

  for i in cls.bodyStartLine..<workLines.len:
    let ln = workLines[i]
    var indent = 0
    var leadingWs = 0
    for c in ln:
      if c == ' ': inc indent; inc leadingWs
      elif c == '\t': indent += 4; inc leadingWs
      else: break
    let stripped = ln[leadingWs..^1].strip(leading = false)
    if stripped.len > 0 and indent < cls.bodyIndent:
      break

    # self.attr / cls.attr
    for pattern in [selfPattern, clsPattern]:
      let idx = stripped.find(pattern)
      if idx >= 0:
        let afterLen = idx + pattern.len
        if afterLen < stripped.len and stripped[afterLen] notin identChars:
          let rest = stripped[afterLen..^1].strip()
          if rest.len > 0 and rest[0] == ':':
            # Type annotation: self.attr: Type
            let typeStr = rest[1..^1].strip()
            let eqIdx = typeStr.find('=')
            let cleanType = if eqIdx >= 0: typeStr[0..<eqIdx].strip() else: typeStr
            var typeName = ""
            for c in cleanType:
              if c in identChars: typeName.add(c)
              else: break
            if typeName.len > 0 and typeName notin wrapperTypes:
              return typeName
          elif rest.len > 0 and rest[0] == '=' and not (rest.len > 1 and rest[1] == '='):
            # Assignment: self.attr = Type(...)
            let rhs = rest[1..^1].strip()
            var typeName = ""
            for c in rhs:
              if c in identChars: typeName.add(c)
              else: break
            if typeName.len > 0 and typeName[0] in {'A'..'Z'} and typeName notin wrapperTypes:
              return typeName

    # @property method: @property followed by def attrName(...) -> Type:
    if stripped == "@property" and i + 1 < workLines.len:
      let nextStripped = workLines[i + 1].strip()
      let defPattern = "def " & attrName
      if nextStripped.startsWith(defPattern) and
         nextStripped.len > defPattern.len and
         nextStripped[defPattern.len] in {'(', ' ', '\t'}:
        let arrowIdx = nextStripped.find("->")
        if arrowIdx >= 0:
          let retPart = nextStripped[arrowIdx + 2..^1].strip()
          # Strip trailing ':'
          let colonIdx = retPart.find(':')
          let cleanRet = if colonIdx >= 0: retPart[0..<colonIdx].strip() else: retPart
          var typeName = ""
          for c in cleanRet:
            if c in identChars: typeName.add(c)
            else: break
          if typeName.len > 0 and typeName notin wrapperTypes:
            return typeName

    # Class-level attribute: attrName: Type or attrName = Type(...)
    if indent == cls.bodyIndent and stripped.startsWith(attrName):
      let afterLen = attrName.len
      if afterLen < stripped.len and stripped[afterLen] notin identChars:
        let rest = stripped[afterLen..^1].strip()
        if rest.len > 0 and rest[0] == ':':
          let typeStr = rest[1..^1].strip()
          let eqIdx = typeStr.find('=')
          let cleanType = if eqIdx >= 0: typeStr[0..<eqIdx].strip() else: typeStr
          var typeName = ""
          for c in cleanType:
            if c in identChars: typeName.add(c)
            else: break
          if typeName.len > 0 and typeName notin wrapperTypes:
            return typeName
        elif rest.len > 0 and rest[0] == '=' and not (rest.len > 1 and rest[1] == '='):
          let rhs = rest[1..^1].strip()
          var typeName = ""
          for c in rhs:
            if c in identChars: typeName.add(c)
            else: break
          if typeName.len > 0 and typeName[0] in {'A'..'Z'} and typeName notin wrapperTypes:
            return typeName

  # Not found in class body — search base classes
  let workImports = if classPath.len > 0: getModuleImports(classPath) else: imports
  for base in cls.bases:
    let (baseFound, baseCi, basePath) = findClassInfo(workLines, base, known, workImports)
    if not baseFound: continue
    let bLines = if basePath.len > 0: getModuleLines(basePath) else: workLines
    let bImports = if basePath.len > 0: getModuleImports(basePath) else: workImports
    let baseResult = resolveAttributeType(bLines, baseCi.name, attrName, bImports, visited, known, depth + 1)
    if baseResult.len > 0: return baseResult
  return ""

proc joinParenContent(lines: seq[string], line, col: int): (string, int) =
  ## If cursor is inside a multiline non-call (...), join its content into
  ## a single line and return adjusted column. Otherwise return original line/col.
  const identChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  var depth = 0
  var openLine = -1
  var openCol = -1

  # Scan backward from cursor for unmatched '('
  for i in countdown(min(col, lines[line].len - 1), 0):
    if lines[line][i] == ')': inc depth
    elif lines[line][i] == '(':
      if depth > 0: dec depth
      else: openLine = line; openCol = i; break

  if openLine < 0:
    for sl in countdown(line - 1, max(0, line - 100)):
      for i in countdown(lines[sl].len - 1, 0):
        if lines[sl][i] == ')': inc depth
        elif lines[sl][i] == '(':
          if depth > 0: dec depth
          else: openLine = sl; openCol = i; break
      if openLine >= 0: break

  if openLine < 0 or openLine == line:
    return (lines[line], col)
  if openCol > 0 and lines[openLine][openCol - 1] in identChars:
    return (lines[line], col)  # function call, don't join

  # Find matching ')'
  var closeLine = -1
  var d = 1
  for jl in openLine..<lines.len:
    let si = if jl == openLine: openCol + 1 else: 0
    for j in si..<lines[jl].len:
      if lines[jl][j] == '(': inc d
      elif lines[jl][j] == ')':
        dec d
        if d == 0: closeLine = jl; break
    if closeLine >= 0: break
  if closeLine < 0:
    return (lines[line], col)

  # Join lines, collapsing leading whitespace to single space
  var joined = lines[openLine]
  var newCol = col
  for jl in openLine + 1..closeLine:
    joined.add(' ')
    var trim = 0
    while trim < lines[jl].len and lines[jl][trim] in {' ', '\t'}: inc trim
    if jl == line: newCol = joined.len + col - trim
    joined.add(lines[jl][trim..^1])
  return (joined, newCol)

proc getDefinitionContext(lines: seq[string], line, col: int): (string, string) =
  ## Returns (qualifier, name). E.g. "json.loads" → ("json", "loads")
  ## Walks full dot chain: "self.inner.method" → ("self.inner", "method")
  ## Treats content inside non-call parentheses as a single expression.
  if line >= lines.len: return ("", "")
  const identChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}

  let (ln, workCol) = joinParenContent(lines, line, col)
  if workCol >= ln.len: return ("", "")
  if ln[workCol] notin identChars:
    return ("", "")
  var startCol = workCol
  while startCol > 0 and ln[startCol - 1] in identChars:
    dec startCol
  var endCol = workCol
  while endCol < ln.len and ln[endCol] in identChars:
    inc endCol
  let name = ln[startCol..<endCol]

  # Walk backward through full dot chain (whitespace-tolerant around dots)
  var parts: seq[string]
  var pos = startCol - 1
  while pos >= 0 and ln[pos] in {' ', '\t'}: dec pos  # skip space before name
  while pos >= 0 and ln[pos] == '.':
    var beforeDot = pos - 1
    while beforeDot >= 0 and ln[beforeDot] in {' ', '\t'}: dec beforeDot  # skip space before dot
    if beforeDot < 0: break
    if ln[beforeDot] == ')':
      # ClassName(...).x or super().x — match parens
      var depth = 1
      var qPos = beforeDot - 1
      while qPos >= 0 and depth > 0:
        if ln[qPos] == ')': inc depth
        elif ln[qPos] == '(': dec depth
        dec qPos
      if depth != 0: break
      var cEnd = qPos + 1
      var cStart = cEnd
      while cStart > 0 and ln[cStart - 1] in identChars:
        dec cStart
      let ident = ln[cStart..<cEnd]
      if ident.len == 0: break
      parts.add(ident)
      pos = cStart - 1
      while pos >= 0 and ln[pos] in {' ', '\t'}: dec pos
    elif ln[beforeDot] in identChars:
      var qEnd = beforeDot + 1
      var qStart = beforeDot
      while qStart > 0 and ln[qStart - 1] in identChars:
        dec qStart
      let ident = ln[qStart..<qEnd]
      if ident.len == 0: break
      parts.add(ident)
      pos = qStart - 1
      while pos >= 0 and ln[pos] in {' ', '\t'}: dec pos
    else:
      break

  if parts.len > 0:
    # Reverse: parts were collected right-to-left
    var qualifier = ""
    for i in countdown(parts.len - 1, 0):
      if qualifier.len > 0: qualifier.add('.')
      qualifier.add(parts[i])
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
                             "namespace", "builtinConstant", "magicVariable"],
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
      var filePath = ""
      if uri.startsWith("file://"): filePath = uri[7..^1]
      let docLines = text.split('\n')
      let knsyms = collectKnownSymbols(docLines, filePath)
      documents[uri] = DocumentState(uri: uri, text: text, version: version, known: knsyms, lines: docLines)
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
          var filePath = ""
          if uri.startsWith("file://"): filePath = uri[7..^1]
          documents[uri].lines = newText.split('\n')
          documents[uri].known = collectKnownSymbols(documents[uri].lines, filePath)
          if filePath.len > 0:
            moduleLinesCache.del(filePath)
            moduleClassCache.del(filePath)
            moduleImportCache.del(filePath)
            symbolCheckCache.del(filePath)
          if newText.len < 1_000_000:
            publishDiagnostics(uri, newText)

    of "textDocument/didClose":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      documents.del(uri)

    of "textDocument/semanticTokens/full":
      let uri = msg["params"]["textDocument"]["uri"].getStr()
      let text = if uri in documents: documents[uri].text else: ""
      let knsyms = if uri in documents: documents[uri].known else: default(KnownSymbols)
      let (tokens, _) = tokenizePython(text, known = knsyms)
      let data = encodeSemanticTokens(tokens)
      sendTokensResponse(id, data)

    of "textDocument/semanticTokens/range":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let rangeNode = params["range"]
      let startLine = rangeNode["start"]["line"].getInt()
      let endLine = rangeNode["end"]["line"].getInt()
      let text = if uri in documents: documents[uri].text else: ""
      let knsyms = if uri in documents: documents[uri].known else: default(KnownSymbols)
      let (tokens, _) = tokenizePython(text, startLine, endLine, knsyms)
      let data = encodeSemanticTokens(tokens)
      sendTokensResponse(id, data)

    of "textDocument/definition":
      let params = msg["params"]
      let uri = params["textDocument"]["uri"].getStr()
      let defLine = params["position"]["line"].getInt()
      let defCol = params["position"]["character"].getInt()
      let lines = if uri in documents: documents[uri].lines else: @[""]
      var filePath = ""
      if uri.startsWith("file://"):
        filePath = uri[7..^1]
      let known = if uri in documents: documents[uri].known else: default(KnownSymbols)

      let (qualifier, name) = getDefinitionContext(lines, defLine, defCol)

      if name.len == 0:
        sendResponse(id, newJArray())
      elif qualifier.len == 0:
        # No qualifier — try same-file first, then imports
        let (foundLine, foundCol) = findDefinitionInText(lines, name)
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
          let (kfp, kml, kmc) = findDefinitionViaKnown(name, known)
          if kml >= 0:
            sendResponse(id, %*{
              "uri": "file://" & kfp,
              "range": {
                "start": {"line": kml, "character": kmc},
                "end": {"line": kml, "character": kmc + name.len}
              }
            })
            found = true
          if not found:
            # Try as module name: `import json` + gd on `json`
            for imp in known.imports:
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
        let imports = known.imports

        # Chained qualifier: self.x.y, cls.x.y, super.x.y, ClassName.x.y
        if qualifier.contains('.'):
          let chainParts = qualifier.split('.')
          let root = chainParts[0]

          # Determine root classes to try
          var rootClasses: seq[string]
          if root == "super":
            let enclosing = findEnclosingClass(lines, defLine)
            if enclosing.len > 0:
              let (cf, ci, _) = findClassInfo(lines, enclosing, known)
              if cf: rootClasses = ci.bases
          elif root == "self" or root == "cls":
            let enc = findEnclosingClass(lines, defLine)
            if enc.len > 0: rootClasses = @[enc]
          elif root.len > 0 and root[0] in {'A'..'Z'}:
            rootClasses = @[root]
          else:
            let t = resolveQualifierType(lines, root, defLine)
            if t.len > 0: rootClasses = @[t]

          for startClass in rootClasses:
            var currentClass = startClass
            var chainLines = lines
            var chainImports = imports
            var chainKnown = known
            var ok = true
            for i in 1..<chainParts.len:
              # Find where currentClass is defined to get its module context
              let (cf, _, cp) = findClassInfo(chainLines, currentClass, chainKnown, chainImports)
              if not cf:
                ok = false
                break
              let workLines = if cp.len > 0: getModuleLines(cp) else: chainLines
              let workImports = if cp.len > 0: getModuleImports(cp) else: chainImports
              let workKnown = if cp.len > 0: default(KnownSymbols) else: chainKnown
              var visited: HashSet[string]
              let nextClass = resolveAttributeType(
                workLines, currentClass, chainParts[i], workImports, visited, workKnown)
              if nextClass.len == 0:
                ok = false
                break
              chainLines = workLines
              chainImports = workImports
              chainKnown = workKnown
              currentClass = nextClass

            if ok and currentClass.len > 0:
              var visited: HashSet[string]
              let (fp, ml, mc) = findMemberWithMRO(
                chainLines, currentClass, name, chainImports, visited, chainKnown)
              if ml >= 0:
                let resultUri = if fp.len > 0: "file://" & fp else: uri
                sendResponse(id, %*{
                  "uri": resultUri,
                  "range": {
                    "start": {"line": ml, "character": mc},
                    "end": {"line": ml, "character": mc + name.len}
                  }
                })
                found = true
              # Transitive import lookup
              if not found:
                var visitedPaths: HashSet[string]
                let (fp3, ml3, mc3) = findMemberTransitive(
                  currentClass, name, chainImports, visitedPaths)
                if ml3 >= 0:
                  sendResponse(id, %*{
                    "uri": "file://" & fp3,
                    "range": {
                      "start": {"line": ml3, "character": mc3},
                      "end": {"line": ml3, "character": mc3 + name.len}
                    }
                  })
                  found = true
            if found: break

        # super() → search base classes of enclosing class, skipping current
        if not found and qualifier == "super":
          let enclosingClass = findEnclosingClass(lines, defLine)
          if enclosingClass.len > 0:
            let (cf, ci, _) = findClassInfo(lines, enclosingClass, known)
            if cf:
              for base in ci.bases:
                var visited: HashSet[string]
                let (fp, ml, mc) = findMemberWithMRO(
                  lines, base, name, imports, visited, known)
                if ml >= 0:
                  let resultUri = if fp.len > 0: "file://" & fp else: uri
                  sendResponse(id, %*{
                    "uri": resultUri,
                    "range": {
                      "start": {"line": ml, "character": mc},
                      "end": {"line": ml, "character": mc + name.len}
                    }
                  })
                  found = true
                  break

        # Try as module.function first (e.g. json.loads) — cheap check
        if not found and qualifier != "self" and qualifier != "cls":
          for imp in imports:
            if imp.name.len == 0:  # `import X` or `import X as Y`
              let target = if imp.alias.len > 0: imp.alias else: imp.module.split('.')[^1]
              if target == qualifier:
                let modulePath = resolveModulePath(imp.module)
                if modulePath.len > 0:
                  let moduleLines = getModuleLines(modulePath)
                  let (mLine, mCol) = findDefinitionInText(moduleLines, name)
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

        # Try to resolve qualifier as a type and do MRO-based member search
        let className = if not found: resolveQualifierType(lines, qualifier, defLine)
                        else: ""
        if className.len > 0:
          var visited: HashSet[string]
          let (resultPath, mLine, mCol) = findMemberWithMRO(
            lines, className, name, imports, visited, known)
          if mLine >= 0:
            let resultUri = if resultPath.len > 0: "file://" & resultPath else: uri
            sendResponse(id, %*{
              "uri": resultUri,
              "range": {
                "start": {"line": mLine, "character": mCol},
                "end": {"line": mLine, "character": mCol + name.len}
              }
            })
            found = true
          else:
            # Transitive import lookup
            var visitedPaths: HashSet[string]
            let (tfp, tml, tmc) = findMemberTransitive(
              className, name, imports, visitedPaths)
            if tml >= 0:
              sendResponse(id, %*{
                "uri": "file://" & tfp,
                "range": {
                  "start": {"line": tml, "character": tmc},
                  "end": {"line": tml, "character": tmc + name.len}
                }
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
          "jsonrpc": "2.0",
          "id": id,
          "error": {"code": -32601, "message": "Method not found: " & meth}
        })

when isMainModule:
  main()
