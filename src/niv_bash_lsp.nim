## niv_bash_lsp — minimal Bash/Shell Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils, cpuinfo]

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
      var isKw = false
      for kw in bashKeywords:
        if word == kw:
          isKw = true
          break

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
# Parallel Tokenizer
# ---------------------------------------------------------------------------

const
  MaxTokenThreads = 4
  ParallelLineThreshold = 4000

type
  BashTokenizerState = object
    inHeredoc: bool
    heredocDelimiter: string
    inSingleQuote: bool
    inDoubleQuote: bool

  BashSectionArgs = object
    textPtr: ptr UncheckedArray[char]
    textLen: int
    startPos: int
    endPos: int
    startLine: int
    initState: BashTokenizerState
    chanIdx: int

var bashSectionChannels: array[MaxTokenThreads, Channel[seq[BashToken]]]
var bashSectionThreads: array[MaxTokenThreads, Thread[BashSectionArgs]]

proc preScanBashState(text: string, startPos, endPos: int, initState: BashTokenizerState): BashTokenizerState =
  ## Lightweight pre-scan tracking only cross-line state variables.
  result = initState
  var pos = startPos
  while pos < endPos:
    let c = text[pos]

    # Inside heredoc: scan for closing delimiter on its own line
    if result.inHeredoc:
      # Check if this line matches the delimiter
      let lineStart = pos
      var lineEnd = pos
      while lineEnd < endPos and text[lineEnd] != '\n':
        inc lineEnd
      let currentLine = text[lineStart..<lineEnd].strip()
      if currentLine == result.heredocDelimiter:
        result.inHeredoc = false
        result.heredocDelimiter = ""
      pos = lineEnd
      if pos < endPos: inc pos # skip \n
      continue

    # Inside single quote: scan for closing '
    if result.inSingleQuote:
      if c == '\'':
        result.inSingleQuote = false
      inc pos
      continue

    # Inside double quote: scan for closing " (handle escapes)
    if result.inDoubleQuote:
      if c == '\\' and pos + 1 < endPos:
        pos += 2
        continue
      if c == '"':
        result.inDoubleQuote = false
      inc pos
      continue

    # Skip comments
    if c == '#':
      while pos < endPos and text[pos] != '\n':
        inc pos
      continue

    # Heredoc operator <<
    if c == '<' and pos + 1 < endPos and text[pos + 1] == '<':
      pos += 2
      if pos < endPos and text[pos] == '-': inc pos
      # Skip whitespace
      while pos < endPos and text[pos] in {' ', '\t'}: inc pos
      # Read delimiter
      var delimiter = ""
      if pos < endPos and text[pos] in {'"', '\''}:
        let q = text[pos]; inc pos
        while pos < endPos and text[pos] != q and text[pos] != '\n':
          delimiter.add(text[pos]); inc pos
        if pos < endPos and text[pos] == q: inc pos
      else:
        while pos < endPos and text[pos] notin {' ', '\t', '\n', ';'}:
          delimiter.add(text[pos]); inc pos
      if delimiter.len > 0:
        result.inHeredoc = true
        result.heredocDelimiter = delimiter
      continue

    # Single quote open
    if c == '\'':
      result.inSingleQuote = true
      inc pos
      continue

    # Double quote open
    if c == '"':
      result.inDoubleQuote = true
      inc pos
      continue

    # Skip escaped characters
    if c == '\\' and pos + 1 < endPos:
      pos += 2
      continue

    inc pos

proc bashSectionWorker(args: BashSectionArgs) {.thread.} =
  ## Tokenize a section of Bash text with given initial state.
  var sectionLen = args.endPos - args.startPos
  var sectionText = newString(sectionLen)
  if sectionLen > 0:
    copyMem(addr sectionText[0], addr args.textPtr[args.startPos], sectionLen)

  var tokens: seq[BashToken]
  var pos = 0
  var line = args.startLine
  var col = 0

  template ch(): char =
    if pos < sectionText.len: sectionText[pos] else: '\0'

  template peek(offset: int): char =
    if pos + offset < sectionText.len: sectionText[pos + offset] else: '\0'

  template advance() =
    if pos < sectionText.len:
      if sectionText[pos] == '\n':
        inc line; col = 0
      else:
        inc col
      inc pos

  template skipSpaces() =
    while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
      advance()

  # Handle initial state: if we start inside a heredoc, consume it first
  if args.initState.inHeredoc:
    let delimiter = args.initState.heredocDelimiter
    while pos < sectionText.len:
      let lineStartLine = line
      let lineStartCol = col
      var currentLine = ""
      while pos < sectionText.len and sectionText[pos] != '\n':
        currentLine.add(sectionText[pos])
        advance()
      if currentLine.strip() == delimiter:
        if pos < sectionText.len: advance() # skip \n
        break
      else:
        if currentLine.len > 0:
          tokens.add(BashToken(kind: btString, line: lineStartLine,
                               col: lineStartCol, length: currentLine.len))
      if pos < sectionText.len: advance() # skip \n

  # Handle initial state: if we start inside a single quote, consume it
  if args.initState.inSingleQuote:
    let sCol = col
    let sLine = line
    while pos < sectionText.len and sectionText[pos] != '\'':
      if sectionText[pos] == '\n':
        advance()
      else:
        advance()
    if pos < sectionText.len: advance() # skip closing '
    if sLine == line:
      tokens.add(BashToken(kind: btString, line: sLine, col: sCol,
                           length: col - sCol))

  # Handle initial state: if we start inside a double quote, consume it
  if args.initState.inDoubleQuote:
    let sCol = col
    let sLine = line
    while pos < sectionText.len and sectionText[pos] != '"':
      if sectionText[pos] == '\\':
        advance()
        if pos < sectionText.len: advance()
      elif sectionText[pos] == '\n':
        advance()
      else:
        advance()
    if pos < sectionText.len: advance() # skip closing "
    if sLine == line:
      tokens.add(BashToken(kind: btString, line: sLine, col: sCol,
                           length: col - sCol))

  var afterNewline = true

  while pos < sectionText.len:
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
      while pos < sectionText.len and sectionText[pos] != '\n':
        advance()
      tokens.add(BashToken(kind: btNamespace, line: sLine, col: sCol,
                           length: col - sCol))
      continue

    # Comment
    if c == '#':
      let sCol = col
      let sLine = line
      while pos < sectionText.len and sectionText[pos] != '\n':
        advance()
      tokens.add(BashToken(kind: btComment, line: sLine, col: sCol,
                           length: col - sCol))
      continue

    # Here-doc operator << or <<-
    if c == '<' and peek(1) == '<':
      let sCol = col
      let sLine = line
      advance(); advance() # skip <<
      if pos < sectionText.len and sectionText[pos] == '-':
        advance() # skip -
      tokens.add(BashToken(kind: btOperator, line: sLine, col: sCol,
                           length: col - sCol))
      # Read delimiter
      skipSpaces()
      var stripQuotes = false
      var delimiter = ""
      if pos < sectionText.len and sectionText[pos] in {'"', '\''}:
        stripQuotes = true
        let q = sectionText[pos]
        advance()
        while pos < sectionText.len and sectionText[pos] != q and sectionText[pos] != '\n':
          delimiter.add(sectionText[pos])
          advance()
        if pos < sectionText.len and sectionText[pos] == q: advance()
      else:
        while pos < sectionText.len and sectionText[pos] notin {' ', '\t', '\n', ';'}:
          delimiter.add(sectionText[pos])
          advance()
      # Read here-doc body until delimiter on its own line
      if delimiter.len > 0:
        # Skip to next line
        while pos < sectionText.len and sectionText[pos] != '\n': advance()
        if pos < sectionText.len: advance() # skip \n
        while pos < sectionText.len:
          let lineStartLine = line
          let lineStartCol = col
          var currentLine = ""
          while pos < sectionText.len and sectionText[pos] != '\n':
            currentLine.add(sectionText[pos])
            advance()
          if currentLine.strip() == delimiter:
            break
          else:
            if currentLine.len > 0:
              tokens.add(BashToken(kind: btString, line: lineStartLine,
                                   col: lineStartCol, length: currentLine.len))
          if pos < sectionText.len: advance() # skip \n
      afterNewline = false
      continue

    # Double-quoted string "..."
    if c == '"':
      let sCol = col
      let sLine = line
      advance() # skip opening "
      while pos < sectionText.len and sectionText[pos] != '"':
        if sectionText[pos] == '\\':
          advance()
          if pos < sectionText.len: advance()
        elif sectionText[pos] == '$':
          advance()
        elif sectionText[pos] == '\n':
          advance()
        else:
          advance()
      if pos < sectionText.len: advance() # skip closing "
      tokens.add(BashToken(kind: btString, line: sLine, col: sCol,
                           length: if sLine == line: col - sCol
                                   else: 1))
      if sLine != line:
        tokens[^1].length = 0
        tokens.setLen(tokens.len - 1)
        let endOfFirstLine = sectionText.find('\n', sCol)
        if endOfFirstLine > 0:
          discard
      afterNewline = false
      continue

    # Single-quoted string '...'
    if c == '\'':
      let sCol = col
      let sLine = line
      advance() # skip opening '
      while pos < sectionText.len and sectionText[pos] != '\'':
        if sectionText[pos] == '\n':
          advance()
        else:
          advance()
      if pos < sectionText.len: advance() # skip closing '
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
      while pos < sectionText.len and sectionText[pos] != '\'':
        if sectionText[pos] == '\\' and pos + 1 < sectionText.len:
          advance()
        advance()
      if pos < sectionText.len: advance() # skip closing '
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
      while pos < sectionText.len and depth > 0:
        if sectionText[pos] == '(' and sectionText[pos - 1] == '$': inc depth
        elif sectionText[pos] == ')': dec depth
        if depth > 0: advance()
      if pos < sectionText.len: advance() # skip closing )
      tokens.add(BashToken(kind: btMacro, line: sLine, col: sCol,
                           length: if sLine == line: col - sCol else: 2))
      afterNewline = false
      continue

    # Variable ${...}
    if c == '$' and peek(1) == '{':
      let sCol = col
      let sLine = line
      advance(); advance() # skip ${
      while pos < sectionText.len and sectionText[pos] != '}' and sectionText[pos] != '\n':
        advance()
      if pos < sectionText.len and sectionText[pos] == '}': advance()
      tokens.add(BashToken(kind: btParameter, line: sLine, col: sCol,
                           length: col - sCol))
      afterNewline = false
      continue

    # Variable $name or $special
    if c == '$':
      let sCol = col
      let sLine = line
      advance() # skip $
      if pos < sectionText.len:
        if sectionText[pos] in {'@', '*', '#', '?', '-', '$', '!', '0'..'9'}:
          advance()
        elif isWordChar(sectionText[pos]):
          while pos < sectionText.len and isWordChar(sectionText[pos]):
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
      while pos < sectionText.len and sectionText[pos] != '`':
        if sectionText[pos] == '\\': advance()
        if pos < sectionText.len: advance()
      if pos < sectionText.len: advance() # skip closing `
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
      while pos < sectionText.len and (isWordChar(sectionText[pos]) or
            sectionText[pos] in {'/', '.', '-', ':', '+', '@'}):
        advance()

      let word = sectionText[sPos..<pos]

      # Check if this is a function definition: word()
      skipSpaces()
      if pos < sectionText.len and sectionText[pos] == '(' and peek(1) == ')':
        tokens.add(BashToken(kind: btFunction, line: sLine, col: sCol,
                             length: word.len))
        advance(); advance() # skip ()
        afterNewline = false
        continue

      # Check if keyword
      var isKw = false
      for kw in bashKeywords:
        if word == kw:
          isKw = true
          break

      if isKw:
        tokens.add(BashToken(kind: btKeyword, line: sLine, col: sCol,
                             length: word.len))
        # After "function" keyword, next word is function name
        if word == "function":
          skipSpaces()
          if pos < sectionText.len and isWordChar(sectionText[pos]):
            let fnCol = col
            let fnLine = line
            let fnPos = pos
            while pos < sectionText.len and isWordChar(sectionText[pos]):
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

  bashSectionChannels[args.chanIdx].send(tokens)

proc tokenizeBashParallel(text: string): seq[BashToken] =
  if text.len == 0: return @[]

  var lineOffsets: seq[int] = @[0]
  for i in 0..<text.len:
    if text[i] == '\n': lineOffsets.add(i + 1)
  let totalLines = lineOffsets.len

  if totalLines < ParallelLineThreshold:
    return tokenizeBash(text)

  let threadCount = min(countProcessors(), MaxTokenThreads)
  if threadCount <= 1:
    return tokenizeBash(text)

  let textPtr = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
  let linesPerSection = totalLines div threadCount

  # Pre-scan to determine state at each section boundary (sequential, cumulative)
  var states: seq[BashTokenizerState] = @[BashTokenizerState()]
  for t in 0..<threadCount - 1:
    let sLine = t * linesPerSection
    let eLine = (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    states.add(preScanBashState(text, startPos, endPos, states[t]))

  for t in 0..<threadCount:
    let sLine = t * linesPerSection
    let eLine = if t == threadCount - 1: totalLines - 1
                else: (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    bashSectionChannels[t].open()
    createThread(bashSectionThreads[t], bashSectionWorker, BashSectionArgs(
      textPtr: textPtr, textLen: text.len,
      startPos: startPos, endPos: endPos,
      startLine: sLine, initState: states[t], chanIdx: t
    ))

  var allTokens: seq[BashToken] = @[]
  for t in 0..<threadCount:
    joinThread(bashSectionThreads[t])
    let (hasData, sectionTokens) = bashSectionChannels[t].tryRecv()
    if hasData: allTokens.add(sectionTokens)
    bashSectionChannels[t].close()

  return allTokens

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizeBashRange(text: string, startLine, endLine: int): seq[BashToken] =
  let allTokens = tokenizeBashParallel(text)
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
      let tokens = tokenizeBashParallel(text)
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
      let tokens = tokenizeBashRange(text, startLine, endLine)
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
