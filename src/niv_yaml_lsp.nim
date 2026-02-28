## niv_yaml_lsp — minimal YAML Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils, cpuinfo]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  YamlTokenKind = enum
    ytKeyword      # true, false, null, ~, yes, no
    ytString       # "double", 'single', block scalars
    ytNumber       # int, float, hex, oct
    ytComment      # # comment
    ytProperty     # mapping keys (left of :)
    ytOperator     # : and - (sequence indicator)
    ytType         # ---, ..., tags !!str
    ytAnchor       # &anchor, *alias
    ytNamespace    # %YAML, %TAG directives

  YamlToken = object
    kind: YamlTokenKind
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
  stAnchor = 7
  stNamespace = 8

# ---------------------------------------------------------------------------
# Parallel Tokenizer Infrastructure
# ---------------------------------------------------------------------------

const
  MaxTokenThreads = 4
  ParallelLineThreshold = 4000

type
  YamlTokenizerState = object
    inBlockScalar: bool
    blockScalarIndent: int
    blockScalarType: char  # '|' or '>'

  YamlSectionArgs = object
    textPtr: ptr UncheckedArray[char]
    textLen: int
    startPos: int
    endPos: int
    startLine: int
    initState: YamlTokenizerState
    chanIdx: int

var yamlSectionChannels: array[MaxTokenThreads, Channel[seq[YamlToken]]]
var yamlSectionThreads: array[MaxTokenThreads, Thread[YamlSectionArgs]]

# ---------------------------------------------------------------------------
# YAML Tokenizer
# ---------------------------------------------------------------------------

proc isPlainChar(c: char): bool =
  c notin {'\0', '\n', '\r', '#', ':', ',', '[', ']', '{', '}'}

proc isNumber(val: string): bool =
  if val.len == 0: return false
  var i = 0
  if val[i] in {'+', '-'}: inc i
  if i >= val.len: return false
  if i + 1 < val.len and val[i] == '0' and val[i + 1] in {'x', 'X'}:
    i += 2
    if i >= val.len: return false
    while i < val.len:
      if val[i] notin {'0'..'9', 'a'..'f', 'A'..'F', '_'}: return false
      inc i
    return true
  if i + 1 < val.len and val[i] == '0' and val[i + 1] in {'o', 'O'}:
    i += 2
    if i >= val.len: return false
    while i < val.len:
      if val[i] notin {'0'..'7', '_'}: return false
      inc i
    return true
  if i + 1 < val.len and val[i] == '0' and val[i + 1] in {'b', 'B'}:
    i += 2
    if i >= val.len: return false
    while i < val.len:
      if val[i] notin {'0', '1', '_'}: return false
      inc i
    return true
  var hasDigit = false
  while i < val.len and val[i] in {'0'..'9', '_'}:
    if val[i] != '_': hasDigit = true
    inc i
  if i >= val.len: return hasDigit
  if val[i] == '.':
    inc i
    while i < val.len and val[i] in {'0'..'9', '_'}:
      if val[i] != '_': hasDigit = true
      inc i
  if i < val.len and val[i] in {'e', 'E'}:
    inc i
    if i < val.len and val[i] in {'+', '-'}: inc i
    var hasExp = false
    while i < val.len and val[i] in {'0'..'9', '_'}:
      if val[i] != '_': hasExp = true
      inc i
    if not hasExp: return false
  return i == val.len and hasDigit

proc tokenizeFlow(tokens: var seq[YamlToken], line: string, lineNum, start, endPos: int) =
  var pos = start
  while pos < endPos:
    let c = line[pos]
    case c
    of ' ', '\t', ',', '[', ']', '{', '}':
      inc pos
    of ':':
      if pos + 1 >= endPos or line[pos + 1] in {' ', ',', '}', ']'}:
        tokens.add(YamlToken(kind: ytOperator, line: lineNum, col: pos, length: 1))
      inc pos
    of '#':
      tokens.add(YamlToken(kind: ytComment, line: lineNum, col: pos,
                           length: endPos - pos))
      return
    of '"':
      let sCol = pos
      inc pos
      while pos < endPos and line[pos] != '"':
        if line[pos] == '\\' and pos + 1 < endPos: inc pos
        inc pos
      if pos < endPos: inc pos
      var sp = pos
      while sp < endPos and line[sp] == ' ': inc sp
      if sp < endPos and line[sp] == ':':
        tokens.add(YamlToken(kind: ytProperty, line: lineNum, col: sCol,
                             length: pos - sCol))
      else:
        tokens.add(YamlToken(kind: ytString, line: lineNum, col: sCol,
                             length: pos - sCol))
    of '\'':
      let sCol = pos
      inc pos
      while pos < endPos and line[pos] != '\'': inc pos
      if pos < endPos: inc pos
      var sp = pos
      while sp < endPos and line[sp] == ' ': inc sp
      if sp < endPos and line[sp] == ':':
        tokens.add(YamlToken(kind: ytProperty, line: lineNum, col: sCol,
                             length: pos - sCol))
      else:
        tokens.add(YamlToken(kind: ytString, line: lineNum, col: sCol,
                             length: pos - sCol))
    of '&':
      let anchorStart = pos
      inc pos
      while pos < endPos and line[pos] notin {' ', ',', ']', '}', '\n'}: inc pos
      tokens.add(YamlToken(kind: ytAnchor, line: lineNum, col: anchorStart,
                           length: pos - anchorStart))
    of '*':
      let aliasStart = pos
      inc pos
      while pos < endPos and line[pos] notin {' ', ',', ']', '}', '\n'}: inc pos
      tokens.add(YamlToken(kind: ytAnchor, line: lineNum, col: aliasStart,
                           length: pos - aliasStart))
    of '!':
      let tagStart = pos
      inc pos
      while pos < endPos and line[pos] notin {' ', ',', ']', '}', '\n'}: inc pos
      tokens.add(YamlToken(kind: ytType, line: lineNum, col: tagStart,
                           length: pos - tagStart))
    else:
      let valStart = pos
      while pos < endPos and line[pos] notin {',', ']', '}', '#', '\n'}:
        if line[pos] == ':' and pos + 1 < endPos and line[pos + 1] in {' ', ',', ']', '}'}:
          break
        inc pos
      var valEndTrim = pos
      while valEndTrim > valStart and line[valEndTrim - 1] in {' ', '\t'}:
        dec valEndTrim
      if valEndTrim > valStart:
        var sp = pos
        while sp < endPos and line[sp] == ' ': inc sp
        if sp < endPos and line[sp] == ':':
          tokens.add(YamlToken(kind: ytProperty, line: lineNum, col: valStart,
                               length: valEndTrim - valStart))
        else:
          let val = line[valStart..<valEndTrim]
          if val in ["null", "~", "Null", "NULL"]:
            tokens.add(YamlToken(kind: ytKeyword, line: lineNum, col: valStart,
                                 length: valEndTrim - valStart))
          elif val in ["true", "false", "True", "False", "TRUE", "FALSE",
                       "yes", "no", "Yes", "No", "YES", "NO",
                       "on", "off", "On", "Off", "ON", "OFF"]:
            tokens.add(YamlToken(kind: ytKeyword, line: lineNum, col: valStart,
                                 length: valEndTrim - valStart))
          elif isNumber(val):
            tokens.add(YamlToken(kind: ytNumber, line: lineNum, col: valStart,
                                 length: valEndTrim - valStart))

proc tokenizeValue(tokens: var seq[YamlToken], line: string, lineNum, valStart, valEnd: int) =
  var pos = valStart
  if pos < valEnd and line[pos] == '!':
    let tagStart = pos
    inc pos
    while pos < valEnd and line[pos] notin {' ', '\n', '\r'}:
      inc pos
    tokens.add(YamlToken(kind: ytType, line: lineNum, col: tagStart,
                         length: pos - tagStart))
    while pos < valEnd and line[pos] == ' ': inc pos
    if pos >= valEnd: return
  if pos < valEnd and line[pos] == '&':
    let anchorStart = pos
    inc pos
    while pos < valEnd and line[pos] notin {' ', '\n', '\r', ',', ']', '}'}:
      inc pos
    tokens.add(YamlToken(kind: ytAnchor, line: lineNum, col: anchorStart,
                         length: pos - anchorStart))
    while pos < valEnd and line[pos] == ' ': inc pos
    if pos >= valEnd: return
  if pos < valEnd and line[pos] == '*':
    let aliasStart = pos
    inc pos
    while pos < valEnd and line[pos] notin {' ', '\n', '\r', ',', ']', '}'}:
      inc pos
    tokens.add(YamlToken(kind: ytAnchor, line: lineNum, col: aliasStart,
                         length: pos - aliasStart))
    return
  if pos < valEnd and line[pos] == '"':
    let sCol = pos
    inc pos
    while pos < valEnd and line[pos] != '"':
      if line[pos] == '\\' and pos + 1 < valEnd:
        inc pos
      inc pos
    if pos < valEnd: inc pos
    tokens.add(YamlToken(kind: ytString, line: lineNum, col: sCol,
                         length: pos - sCol))
    return
  if pos < valEnd and line[pos] == '\'':
    let sCol = pos
    inc pos
    while pos < valEnd and line[pos] != '\'':
      inc pos
    if pos < valEnd: inc pos
    tokens.add(YamlToken(kind: ytString, line: lineNum, col: sCol,
                         length: pos - sCol))
    return
  if pos < valEnd and line[pos] in {'[', '{'}:
    tokenizeFlow(tokens, line, lineNum, pos, valEnd)
    return
  var end2 = valEnd
  while end2 > pos and line[end2 - 1] in {' ', '\t'}:
    dec end2
  let val = line[pos..<end2]
  if val in ["null", "~", "Null", "NULL"]:
    tokens.add(YamlToken(kind: ytKeyword, line: lineNum, col: pos, length: end2 - pos))
    return
  if val in ["true", "false", "True", "False", "TRUE", "FALSE",
             "yes", "no", "Yes", "No", "YES", "NO",
             "on", "off", "On", "Off", "ON", "OFF"]:
    tokens.add(YamlToken(kind: ytKeyword, line: lineNum, col: pos, length: end2 - pos))
    return
  if val in [".inf", "-.inf", "+.inf", ".Inf", "-.Inf", "+.Inf",
             ".INF", "-.INF", "+.INF", ".nan", ".NaN", ".NAN"]:
    tokens.add(YamlToken(kind: ytKeyword, line: lineNum, col: pos, length: end2 - pos))
    return
  if val.len > 0 and isNumber(val):
    tokens.add(YamlToken(kind: ytNumber, line: lineNum, col: pos, length: end2 - pos))
    return

proc tokenizeYaml(text: string): seq[YamlToken] =
  var tokens: seq[YamlToken]
  let lines = text.split('\n')

  var inBlockScalar = false
  var blockIndent = -1
  var blockStartLine = -1

  for lineNum in 0..<lines.len:
    let line = lines[lineNum]
    if line.len == 0:
      if inBlockScalar:
        inBlockScalar = false
        blockIndent = -1
      continue

    var pos = 0

    # Measure leading whitespace
    var indent = 0
    while pos < line.len and line[pos] == ' ':
      inc pos
      inc indent

    # Block scalar continuation
    if inBlockScalar:
      if indent > blockIndent or (pos < line.len and line[pos] == '\n'):
        # Content line of block scalar
        if pos < line.len:
          tokens.add(YamlToken(kind: ytString, line: lineNum, col: pos,
                               length: line.len - pos))
        continue
      else:
        inBlockScalar = false
        blockIndent = -1

    if pos >= line.len:
      continue

    # Document markers --- and ...
    if indent == 0 and line.len >= 3:
      if line[0..2] == "---" and (line.len == 3 or line[3] in {' ', '\n', '\r'}):
        tokens.add(YamlToken(kind: ytType, line: lineNum, col: 0, length: 3))
        pos = 3
        # May have content after ---
        while pos < line.len and line[pos] == ' ': inc pos
        if pos >= line.len:
          continue
        # Fall through to parse rest of line
      elif line[0..2] == "..." and (line.len == 3 or line[3] in {' ', '\n', '\r'}):
        tokens.add(YamlToken(kind: ytType, line: lineNum, col: 0, length: 3))
        continue

    # Directives: %YAML, %TAG
    if indent == 0 and pos < line.len and line[pos] == '%':
      tokens.add(YamlToken(kind: ytNamespace, line: lineNum, col: pos,
                           length: line.len - pos))
      continue

    # Comment line (only whitespace before #)
    if pos < line.len and line[pos] == '#':
      tokens.add(YamlToken(kind: ytComment, line: lineNum, col: pos,
                           length: line.len - pos))
      continue

    # Sequence indicator -
    if pos < line.len and line[pos] == '-' and
       pos + 1 < line.len and line[pos + 1] == ' ':
      tokens.add(YamlToken(kind: ytOperator, line: lineNum, col: pos, length: 1))
      pos += 2
      while pos < line.len and line[pos] == ' ': inc pos
      if pos >= line.len:
        continue

    # Check for key: value pattern
    # Find the colon that separates key from value
    var colonPos = -1
    var searchPos = pos

    # Handle quoted keys
    if searchPos < line.len and line[searchPos] in {'"', '\''}:
      let quote = line[searchPos]
      let keyStart = searchPos
      inc searchPos
      while searchPos < line.len and line[searchPos] != quote:
        if line[searchPos] == '\\' and quote == '"':
          inc searchPos
        inc searchPos
      if searchPos < line.len:
        inc searchPos # skip closing quote
      # Look for colon after quoted key
      var sp = searchPos
      while sp < line.len and line[sp] == ' ': inc sp
      if sp < line.len and line[sp] == ':' and
         (sp + 1 >= line.len or line[sp + 1] in {' ', '\n', '\r'}):
        colonPos = sp
        # Emit quoted key as property
        tokens.add(YamlToken(kind: ytProperty, line: lineNum, col: keyStart,
                             length: searchPos - keyStart))
    else:
      # Bare key - scan for ": " or ":\n" or ":$"
      var sp = searchPos
      while sp < line.len:
        if line[sp] == ':' and
           (sp + 1 >= line.len or line[sp + 1] in {' ', '\n', '\r'}):
          colonPos = sp
          break
        if line[sp] == '#' and sp > 0 and line[sp - 1] == ' ':
          break
        inc sp

      if colonPos > pos:
        # Trim trailing whitespace from key
        var keyEnd = colonPos
        while keyEnd > pos and line[keyEnd - 1] == ' ':
          dec keyEnd
        if keyEnd > pos:
          tokens.add(YamlToken(kind: ytProperty, line: lineNum, col: pos,
                               length: keyEnd - pos))

    if colonPos >= 0:
      # Emit colon as operator
      tokens.add(YamlToken(kind: ytOperator, line: lineNum, col: colonPos,
                           length: 1))
      pos = colonPos + 1
      while pos < line.len and line[pos] == ' ': inc pos

      if pos >= line.len:
        continue

      # Check for inline comment
      let vc = line[pos]

      # Comment after value position
      if vc == '#':
        tokens.add(YamlToken(kind: ytComment, line: lineNum, col: pos,
                             length: line.len - pos))
        continue

      # Tag (!!type or !tag)
      if vc == '!':
        let tagStart = pos
        inc pos
        while pos < line.len and line[pos] notin {' ', '\n', '\r'}:
          inc pos
        tokens.add(YamlToken(kind: ytType, line: lineNum, col: tagStart,
                             length: pos - tagStart))
        while pos < line.len and line[pos] == ' ': inc pos
        if pos >= line.len:
          continue
        # Fall through to parse value after tag

      # Anchor &name
      if pos < line.len and line[pos] == '&':
        let anchorStart = pos
        inc pos
        while pos < line.len and line[pos] notin {' ', '\n', '\r', ',', ']', '}'}:
          inc pos
        tokens.add(YamlToken(kind: ytAnchor, line: lineNum, col: anchorStart,
                             length: pos - anchorStart))
        while pos < line.len and line[pos] == ' ': inc pos
        if pos >= line.len:
          continue

      # Alias *name
      if pos < line.len and line[pos] == '*':
        let aliasStart = pos
        inc pos
        while pos < line.len and line[pos] notin {' ', '\n', '\r', ',', ']', '}'}:
          inc pos
        tokens.add(YamlToken(kind: ytAnchor, line: lineNum, col: aliasStart,
                             length: pos - aliasStart))
        continue

      # Block scalar indicators | or >
      if pos < line.len and line[pos] in {'|', '>'}:
        tokens.add(YamlToken(kind: ytOperator, line: lineNum, col: pos, length: 1))
        inBlockScalar = true
        blockIndent = indent
        blockStartLine = lineNum
        # Skip optional chomping indicator and comment
        inc pos
        while pos < line.len and line[pos] in {'+', '-', '0'..'9'}: inc pos
        while pos < line.len and line[pos] == ' ': inc pos
        if pos < line.len and line[pos] == '#':
          tokens.add(YamlToken(kind: ytComment, line: lineNum, col: pos,
                               length: line.len - pos))
        continue

      # Parse the value
      if pos < line.len:
        let valStart = pos
        # Find end of value (before inline comment)
        var valEnd = line.len
        var inQuote = false
        var quoteChar = '\0'
        var vp = pos
        while vp < line.len:
          if inQuote:
            if line[vp] == '\\' and quoteChar == '"':
              inc vp
            elif line[vp] == quoteChar:
              inQuote = false
          else:
            if line[vp] in {'"', '\''}:
              inQuote = true
              quoteChar = line[vp]
            elif line[vp] == '#' and vp > 0 and line[vp - 1] == ' ':
              # Inline comment
              tokens.add(YamlToken(kind: ytComment, line: lineNum, col: vp,
                                   length: line.len - vp))
              valEnd = vp
              while valEnd > valStart and line[valEnd - 1] == ' ':
                dec valEnd
              break
          inc vp

        if valStart < valEnd:
          tokenizeValue(tokens, line, lineNum, valStart, valEnd)

    elif colonPos < 0:
      # No colon found - this is a plain value line (e.g. sequence item value)
      if pos < line.len:
        let valStart = pos
        var valEnd = line.len
        # Check for inline comment
        var vp = pos
        var inQuote = false
        var quoteChar = '\0'
        while vp < line.len:
          if inQuote:
            if line[vp] == '\\' and quoteChar == '"':
              inc vp
            elif line[vp] == quoteChar:
              inQuote = false
          else:
            if line[vp] in {'"', '\''}:
              inQuote = true
              quoteChar = line[vp]
            elif line[vp] == '#' and vp > 0 and line[vp - 1] == ' ':
              tokens.add(YamlToken(kind: ytComment, line: lineNum, col: vp,
                                   length: line.len - vp))
              valEnd = vp
              while valEnd > valStart and line[valEnd - 1] == ' ':
                dec valEnd
              break
          inc vp

        if valStart < valEnd:
          tokenizeValue(tokens, line, lineNum, valStart, valEnd)

  return tokens

# ---------------------------------------------------------------------------
# Parallel Tokenizer
# ---------------------------------------------------------------------------

proc preScanYamlState(text: string, startPos, endPos: int, initState: YamlTokenizerState): YamlTokenizerState =
  ## Lightweight pre-scan tracking only cross-line state (block scalar).
  ## Processes text[startPos..<endPos] line-by-line to determine the state
  ## at the end of this section.
  result = initState
  var pos = startPos
  while pos < endPos:
    # Find start and end of current line
    let lineStart = pos
    while pos < endPos and text[pos] != '\n':
      inc pos
    let lineEnd = pos
    if pos < endPos: inc pos  # skip \n

    let lineLen = lineEnd - lineStart
    if lineLen == 0:
      # Empty line ends block scalar
      if result.inBlockScalar:
        result.inBlockScalar = false
        result.blockScalarIndent = -1
      continue

    # Measure indent
    var indent = 0
    var lp = lineStart
    while lp < lineEnd and text[lp] == ' ':
      inc lp
      inc indent

    # Block scalar continuation check
    if result.inBlockScalar:
      if indent > result.blockScalarIndent or (lp < lineEnd and text[lp] == '\n'):
        continue  # still in block scalar
      else:
        result.inBlockScalar = false
        result.blockScalarIndent = -1

    if lp >= lineEnd: continue

    # Skip comment lines
    if text[lp] == '#': continue

    # Skip directives
    if indent == 0 and text[lp] == '%': continue

    # Skip document markers
    if indent == 0 and lineLen >= 3:
      if lineEnd - lineStart >= 3 and text[lineStart] == '-' and text[lineStart+1] == '-' and text[lineStart+2] == '-':
        discard
      elif lineEnd - lineStart >= 3 and text[lineStart] == '.' and text[lineStart+1] == '.' and text[lineStart+2] == '.':
        continue

    # Skip sequence indicator
    if lp < lineEnd and text[lp] == '-' and lp + 1 < lineEnd and text[lp+1] == ' ':
      lp += 2
      while lp < lineEnd and text[lp] == ' ': inc lp

    # Look for colon to find key: value
    var colonPos = -1
    var sp = lp
    # Handle quoted keys
    if sp < lineEnd and text[sp] in {'"', '\''}:
      let quote = text[sp]
      inc sp
      while sp < lineEnd and text[sp] != quote:
        if text[sp] == '\\' and quote == '"': inc sp
        inc sp
      if sp < lineEnd: inc sp
      var qsp = sp
      while qsp < lineEnd and text[qsp] == ' ': inc qsp
      if qsp < lineEnd and text[qsp] == ':' and
         (qsp + 1 >= lineEnd or text[qsp + 1] in {' ', '\n', '\r'}):
        colonPos = qsp
    else:
      while sp < lineEnd:
        if text[sp] == ':' and
           (sp + 1 >= lineEnd or text[sp + 1] in {' ', '\n', '\r'}):
          colonPos = sp
          break
        if text[sp] == '#' and sp > lineStart and text[sp - 1] == ' ':
          break
        inc sp

    if colonPos >= 0:
      # Skip past colon and whitespace to find value
      var vp = colonPos + 1
      while vp < lineEnd and text[vp] == ' ': inc vp
      # Check for block scalar indicators
      if vp < lineEnd and text[vp] in {'|', '>'}:
        result.inBlockScalar = true
        result.blockScalarIndent = indent
        result.blockScalarType = text[vp]

proc yamlSectionWorker(args: YamlSectionArgs) {.thread.} =
  ## Tokenize a section of YAML text with given initial state.
  ## The YAML tokenizer is line-based, so we split the section into lines.
  var sectionLen = args.endPos - args.startPos
  var sectionText = newString(sectionLen)
  if sectionLen > 0:
    copyMem(addr sectionText[0], addr args.textPtr[args.startPos], sectionLen)

  var tokens: seq[YamlToken]
  let lines = sectionText.split('\n')

  var inBlockScalar = args.initState.inBlockScalar
  var blockIndent = args.initState.blockScalarIndent
  var blockStartLine = -1

  for lineIdx in 0..<lines.len:
    let lineNum = args.startLine + lineIdx
    let line = lines[lineIdx]
    if line.len == 0:
      if inBlockScalar:
        inBlockScalar = false
        blockIndent = -1
      continue

    var pos = 0

    # Measure leading whitespace
    var indent = 0
    while pos < line.len and line[pos] == ' ':
      inc pos
      inc indent

    # Block scalar continuation
    if inBlockScalar:
      if indent > blockIndent or (pos < line.len and line[pos] == '\n'):
        # Content line of block scalar
        if pos < line.len:
          tokens.add(YamlToken(kind: ytString, line: lineNum, col: pos,
                               length: line.len - pos))
        continue
      else:
        inBlockScalar = false
        blockIndent = -1

    if pos >= line.len:
      continue

    # Document markers --- and ...
    if indent == 0 and line.len >= 3:
      if line[0..2] == "---" and (line.len == 3 or line[3] in {' ', '\n', '\r'}):
        tokens.add(YamlToken(kind: ytType, line: lineNum, col: 0, length: 3))
        pos = 3
        while pos < line.len and line[pos] == ' ': inc pos
        if pos >= line.len:
          continue
      elif line[0..2] == "..." and (line.len == 3 or line[3] in {' ', '\n', '\r'}):
        tokens.add(YamlToken(kind: ytType, line: lineNum, col: 0, length: 3))
        continue

    # Directives: %YAML, %TAG
    if indent == 0 and pos < line.len and line[pos] == '%':
      tokens.add(YamlToken(kind: ytNamespace, line: lineNum, col: pos,
                           length: line.len - pos))
      continue

    # Comment line
    if pos < line.len and line[pos] == '#':
      tokens.add(YamlToken(kind: ytComment, line: lineNum, col: pos,
                           length: line.len - pos))
      continue

    # Sequence indicator -
    if pos < line.len and line[pos] == '-' and
       pos + 1 < line.len and line[pos + 1] == ' ':
      tokens.add(YamlToken(kind: ytOperator, line: lineNum, col: pos, length: 1))
      pos += 2
      while pos < line.len and line[pos] == ' ': inc pos
      if pos >= line.len:
        continue

    # Check for key: value pattern
    var colonPos = -1
    var searchPos = pos

    # Handle quoted keys
    if searchPos < line.len and line[searchPos] in {'"', '\''}:
      let quote = line[searchPos]
      let keyStart = searchPos
      inc searchPos
      while searchPos < line.len and line[searchPos] != quote:
        if line[searchPos] == '\\' and quote == '"':
          inc searchPos
        inc searchPos
      if searchPos < line.len:
        inc searchPos
      var sp = searchPos
      while sp < line.len and line[sp] == ' ': inc sp
      if sp < line.len and line[sp] == ':' and
         (sp + 1 >= line.len or line[sp + 1] in {' ', '\n', '\r'}):
        colonPos = sp
        tokens.add(YamlToken(kind: ytProperty, line: lineNum, col: keyStart,
                             length: searchPos - keyStart))
    else:
      var sp = searchPos
      while sp < line.len:
        if line[sp] == ':' and
           (sp + 1 >= line.len or line[sp + 1] in {' ', '\n', '\r'}):
          colonPos = sp
          break
        if line[sp] == '#' and sp > 0 and line[sp - 1] == ' ':
          break
        inc sp

      if colonPos > pos:
        var keyEnd = colonPos
        while keyEnd > pos and line[keyEnd - 1] == ' ':
          dec keyEnd
        if keyEnd > pos:
          tokens.add(YamlToken(kind: ytProperty, line: lineNum, col: pos,
                               length: keyEnd - pos))

    if colonPos >= 0:
      tokens.add(YamlToken(kind: ytOperator, line: lineNum, col: colonPos,
                           length: 1))
      pos = colonPos + 1
      while pos < line.len and line[pos] == ' ': inc pos

      if pos >= line.len:
        continue

      let vc = line[pos]

      if vc == '#':
        tokens.add(YamlToken(kind: ytComment, line: lineNum, col: pos,
                             length: line.len - pos))
        continue

      if vc == '!':
        let tagStart = pos
        inc pos
        while pos < line.len and line[pos] notin {' ', '\n', '\r'}:
          inc pos
        tokens.add(YamlToken(kind: ytType, line: lineNum, col: tagStart,
                             length: pos - tagStart))
        while pos < line.len and line[pos] == ' ': inc pos
        if pos >= line.len:
          continue

      if pos < line.len and line[pos] == '&':
        let anchorStart = pos
        inc pos
        while pos < line.len and line[pos] notin {' ', '\n', '\r', ',', ']', '}'}:
          inc pos
        tokens.add(YamlToken(kind: ytAnchor, line: lineNum, col: anchorStart,
                             length: pos - anchorStart))
        while pos < line.len and line[pos] == ' ': inc pos
        if pos >= line.len:
          continue

      if pos < line.len and line[pos] == '*':
        let aliasStart = pos
        inc pos
        while pos < line.len and line[pos] notin {' ', '\n', '\r', ',', ']', '}'}:
          inc pos
        tokens.add(YamlToken(kind: ytAnchor, line: lineNum, col: aliasStart,
                             length: pos - aliasStart))
        continue

      # Block scalar indicators | or >
      if pos < line.len and line[pos] in {'|', '>'}:
        tokens.add(YamlToken(kind: ytOperator, line: lineNum, col: pos, length: 1))
        inBlockScalar = true
        blockIndent = indent
        blockStartLine = lineNum
        inc pos
        while pos < line.len and line[pos] in {'+', '-', '0'..'9'}: inc pos
        while pos < line.len and line[pos] == ' ': inc pos
        if pos < line.len and line[pos] == '#':
          tokens.add(YamlToken(kind: ytComment, line: lineNum, col: pos,
                               length: line.len - pos))
        continue

      # Parse the value
      if pos < line.len:
        let valStart = pos
        var valEnd = line.len
        var inQuote = false
        var quoteChar = '\0'
        var vp = pos
        while vp < line.len:
          if inQuote:
            if line[vp] == '\\' and quoteChar == '"':
              inc vp
            elif line[vp] == quoteChar:
              inQuote = false
          else:
            if line[vp] in {'"', '\''}:
              inQuote = true
              quoteChar = line[vp]
            elif line[vp] == '#' and vp > 0 and line[vp - 1] == ' ':
              tokens.add(YamlToken(kind: ytComment, line: lineNum, col: vp,
                                   length: line.len - vp))
              valEnd = vp
              while valEnd > valStart and line[valEnd - 1] == ' ':
                dec valEnd
              break
          inc vp

        if valStart < valEnd:
          tokenizeValue(tokens, line, lineNum, valStart, valEnd)

    elif colonPos < 0:
      if pos < line.len:
        let valStart = pos
        var valEnd = line.len
        var vp = pos
        var inQuote = false
        var quoteChar = '\0'
        while vp < line.len:
          if inQuote:
            if line[vp] == '\\' and quoteChar == '"':
              inc vp
            elif line[vp] == quoteChar:
              inQuote = false
          else:
            if line[vp] in {'"', '\''}:
              inQuote = true
              quoteChar = line[vp]
            elif line[vp] == '#' and vp > 0 and line[vp - 1] == ' ':
              tokens.add(YamlToken(kind: ytComment, line: lineNum, col: vp,
                                   length: line.len - vp))
              valEnd = vp
              while valEnd > valStart and line[valEnd - 1] == ' ':
                dec valEnd
              break
          inc vp

        if valStart < valEnd:
          tokenizeValue(tokens, line, lineNum, valStart, valEnd)

  yamlSectionChannels[args.chanIdx].send(tokens)

proc tokenizeYamlParallel(text: string): seq[YamlToken] =
  if text.len == 0: return @[]

  var lineOffsets: seq[int] = @[0]
  for i in 0..<text.len:
    if text[i] == '\n': lineOffsets.add(i + 1)
  let totalLines = lineOffsets.len

  if totalLines < ParallelLineThreshold:
    return tokenizeYaml(text)

  let threadCount = min(countProcessors(), MaxTokenThreads)
  if threadCount <= 1:
    return tokenizeYaml(text)

  let textPtr = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
  let linesPerSection = totalLines div threadCount

  # Pre-scan to determine state at each section boundary (sequential, cumulative)
  var states: seq[YamlTokenizerState] = @[YamlTokenizerState(
    inBlockScalar: false, blockScalarIndent: -1, blockScalarType: '\0')]
  for t in 0..<threadCount - 1:
    let sLine = t * linesPerSection
    let eLine = (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    states.add(preScanYamlState(text, startPos, endPos, states[t]))

  for t in 0..<threadCount:
    let sLine = t * linesPerSection
    let eLine = if t == threadCount - 1: totalLines - 1
                else: (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    yamlSectionChannels[t].open()
    createThread(yamlSectionThreads[t], yamlSectionWorker, YamlSectionArgs(
      textPtr: textPtr, textLen: text.len,
      startPos: startPos, endPos: endPos,
      startLine: sLine, initState: states[t], chanIdx: t
    ))

  var allTokens: seq[YamlToken] = @[]
  for t in 0..<threadCount:
    joinThread(yamlSectionThreads[t])
    let (hasData, sectionTokens) = yamlSectionChannels[t].tryRecv()
    if hasData: allTokens.add(sectionTokens)
    yamlSectionChannels[t].close()

  return allTokens

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizeYamlRange(text: string, startLine, endLine: int): seq[YamlToken] =
  let allTokens = tokenizeYamlParallel(text)
  result = @[]
  for tok in allTokens:
    if tok.line >= startLine and tok.line <= endLine:
      result.add(tok)

# ---------------------------------------------------------------------------
# Semantic Token Encoding (LSP delta encoding)
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[YamlToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of ytKeyword: stKeyword
      of ytString: stString
      of ytNumber: stNumber
      of ytComment: stComment
      of ytProperty: stProperty
      of ytOperator: stOperator
      of ytType: stType
      of ytAnchor: stAnchor
      of ytNamespace: stNamespace
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
                             "property", "operator", "type", "macro", "namespace"],
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
      let tokens = tokenizeYamlParallel(text)
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
      let tokens = tokenizeYamlRange(text, startLine, endLine)
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
