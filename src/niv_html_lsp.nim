## niv_html_lsp — minimal HTML Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils, cpuinfo]

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
    htVariable     # template placeholder content: {{ expr }}

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
  stVariable = 7

# ---------------------------------------------------------------------------
# Parallel Tokenizer Types & Globals
# ---------------------------------------------------------------------------

const
  MaxTokenThreads = 4
  ParallelLineThreshold = 4000

type
  HtmlTokenizerState = object
    inComment: bool   # inside <!-- ... -->
    inTag: bool       # inside < ... > (open tag attributes)
    inScript: bool    # inside <script>...</script> content
    inStyle: bool     # inside <style>...</style> content

  HtmlSectionArgs = object
    textPtr: ptr UncheckedArray[char]
    textLen: int
    startPos: int
    endPos: int
    startLine: int
    initState: HtmlTokenizerState
    chanIdx: int

var htmlSectionChannels: array[MaxTokenThreads, Channel[seq[HtmlToken]]]
var htmlSectionThreads: array[MaxTokenThreads, Thread[HtmlSectionArgs]]

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

    # Template placeholder {{ ... }}
    if c == '{' and peek(1) == '{':
      let sCol = col
      let sLine = line
      advance(); advance() # skip {{
      tokens.add(HtmlToken(kind: htMacro, line: sLine, col: sCol, length: 2))
      # Skip whitespace
      while pos < text.len and text[pos] in {' ', '\t'}:
        advance()
      # Content
      let contentCol = col
      let contentLine = line
      let contentStart = pos
      while pos < text.len:
        if text[pos] == '}' and peek(1) == '}':
          break
        if text[pos] == '\n':
          break
        advance()
      let contentLen = pos - contentStart
      # Trim trailing whitespace from content
      var trimLen = contentLen
      while trimLen > 0 and text[contentStart + trimLen - 1] in {' ', '\t'}:
        dec trimLen
      if trimLen > 0:
        tokens.add(HtmlToken(kind: htVariable, line: contentLine, col: contentCol,
                              length: trimLen))
      # Skip whitespace before }}
      while pos < text.len and text[pos] in {' ', '\t'}:
        advance()
      # Closing }}
      if pos < text.len and text[pos] == '}' and peek(1) == '}':
        let closeCol = col
        advance(); advance()
        tokens.add(HtmlToken(kind: htMacro, line: line, col: closeCol, length: 2))
      continue

    # Template tag {% ... %}
    if c == '{' and peek(1) == '%':
      let sCol = col
      let sLine = line
      advance(); advance() # skip {%
      tokens.add(HtmlToken(kind: htMacro, line: sLine, col: sCol, length: 2))
      # Skip whitespace
      while pos < text.len and text[pos] in {' ', '\t'}:
        advance()
      # Content
      let contentCol = col
      let contentLine = line
      let contentStart = pos
      while pos < text.len:
        if text[pos] == '%' and peek(1) == '}':
          break
        if text[pos] == '\n':
          break
        advance()
      let contentLen = pos - contentStart
      # Trim trailing whitespace from content
      var trimLen = contentLen
      while trimLen > 0 and text[contentStart + trimLen - 1] in {' ', '\t'}:
        dec trimLen
      if trimLen > 0:
        tokens.add(HtmlToken(kind: htVariable, line: contentLine, col: contentCol,
                              length: trimLen))
      # Skip whitespace before %}
      while pos < text.len and text[pos] in {' ', '\t'}:
        advance()
      # Closing %}
      if pos < text.len and text[pos] == '%' and peek(1) == '}':
        let closeCol = col
        advance(); advance()
        tokens.add(HtmlToken(kind: htMacro, line: line, col: closeCol, length: 2))
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
              let openCol = col
              advance() # skip opening quote
              # Emit opening quote as string
              tokens.add(HtmlToken(kind: htString, line: line, col: openCol, length: 1))
              # Scan content, splitting on {{ }} and {% %}
              var segCol = col
              var segLine = line
              while pos < text.len and text[pos] != q:
                if text[pos] == '{' and (peek(1) == '{' or peek(1) == '%'):
                  let isPercent = peek(1) == '%'
                  let closeChar = if isPercent: '%' else: '}'
                  # Emit string segment before delimiter
                  if col > segCol or line > segLine:
                    if segLine == line:
                      tokens.add(HtmlToken(kind: htString, line: segLine, col: segCol,
                                            length: col - segCol))
                  # Emit {{ or {%
                  let brCol = col
                  advance(); advance()
                  tokens.add(HtmlToken(kind: htMacro, line: line, col: brCol, length: 2))
                  # Skip whitespace
                  while pos < text.len and text[pos] in {' ', '\t'}:
                    advance()
                  # Content
                  let cCol = col
                  let cLine = line
                  let cStart = pos
                  while pos < text.len and text[pos] != q:
                    if text[pos] == closeChar and peek(1) == '}':
                      break
                    if text[pos] == '\n': break
                    advance()
                  var trimLen = pos - cStart
                  while trimLen > 0 and text[cStart + trimLen - 1] in {' ', '\t'}:
                    dec trimLen
                  if trimLen > 0:
                    tokens.add(HtmlToken(kind: htVariable, line: cLine, col: cCol,
                                          length: trimLen))
                  # Skip whitespace before }} or %}
                  while pos < text.len and text[pos] in {' ', '\t'}:
                    advance()
                  # Emit }} or %}
                  if pos < text.len and text[pos] == closeChar and peek(1) == '}':
                    let clCol = col
                    advance(); advance()
                    tokens.add(HtmlToken(kind: htMacro, line: line, col: clCol, length: 2))
                  segCol = col
                  segLine = line
                else:
                  advance()
              # Emit remaining string segment
              if col > segCol or line > segLine:
                if segLine == line:
                  tokens.add(HtmlToken(kind: htString, line: segLine, col: segCol,
                                        length: col - segCol))
              # Emit closing quote
              if pos < text.len and text[pos] == q:
                let clqCol = col
                advance()
                tokens.add(HtmlToken(kind: htString, line: line, col: clqCol, length: 1))
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
# Parallel Tokenizer
# ---------------------------------------------------------------------------

proc preScanHtmlState(text: string, startPos, endPos: int, initState: HtmlTokenizerState): HtmlTokenizerState =
  ## Lightweight pre-scan tracking only cross-line state variables.
  result = initState
  var pos = startPos
  while pos < endPos:
    let c = text[pos]

    # Inside comment: scan for -->
    if result.inComment:
      if pos + 2 < endPos and c == '-' and text[pos+1] == '-' and text[pos+2] == '>':
        pos += 3
        result.inComment = false
      else:
        inc pos
      continue

    # Inside script content: scan for </script
    if result.inScript:
      if c == '<' and pos + 8 < endPos and text[pos+1] == '/' and
         text[pos+2..pos+7].toLowerAscii() == "script":
        result.inScript = false
        pos += 8
        # skip to >
        while pos < endPos and text[pos] != '>':
          inc pos
        if pos < endPos: inc pos
      else:
        inc pos
      continue

    # Inside style content: scan for </style
    if result.inStyle:
      if c == '<' and pos + 7 < endPos and text[pos+1] == '/' and
         text[pos+2..pos+6].toLowerAscii() == "style":
        result.inStyle = false
        pos += 7
        while pos < endPos and text[pos] != '>':
          inc pos
        if pos < endPos: inc pos
      else:
        inc pos
      continue

    # Inside tag: track strings and closing >
    if result.inTag:
      if c in {'"', '\''}:
        let q = c; inc pos
        while pos < endPos and text[pos] != q:
          inc pos
        if pos < endPos: inc pos
        continue
      if c == '/':
        if pos + 1 < endPos and text[pos+1] == '>':
          result.inTag = false
          pos += 2
          continue
      if c == '>':
        result.inTag = false
        inc pos
        continue
      inc pos
      continue

    # Comment start <!--
    if c == '<' and pos + 3 < endPos and text[pos+1] == '!' and text[pos+2] == '-' and text[pos+3] == '-':
      result.inComment = true
      pos += 4
      continue

    # Tag start <
    if c == '<':
      let isClosing = pos + 1 < endPos and text[pos+1] == '/'
      if isClosing:
        pos += 2
      else:
        inc pos
      # skip whitespace
      while pos < endPos and text[pos] in {' ', '\t', '\n', '\r'}:
        inc pos
      # read tag name
      var nameStart = pos
      while pos < endPos and text[pos] in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', ':'}:
        inc pos
      let tagNameLower = text[nameStart..<pos].toLowerAscii()
      if isClosing:
        # closing tag: skip to >
        while pos < endPos and text[pos] != '>':
          inc pos
        if pos < endPos: inc pos
        # closing a script/style tag handled above
        continue
      # opening tag: mark inTag
      result.inTag = true
      # scan to end of tag
      while pos < endPos:
        if text[pos] in {'"', '\''}:
          let q = text[pos]; inc pos
          while pos < endPos and text[pos] != q:
            inc pos
          if pos < endPos: inc pos
          continue
        if text[pos] == '/' and pos + 1 < endPos and text[pos+1] == '>':
          result.inTag = false
          pos += 2
          break
        if text[pos] == '>':
          result.inTag = false
          inc pos
          break
        inc pos
      # After tag closed, check if script/style
      if not result.inTag:
        if tagNameLower == "script":
          result.inScript = true
        elif tagNameLower == "style":
          result.inStyle = true
      continue

    inc pos

proc htmlSectionWorker(args: HtmlSectionArgs) {.thread.} =
  ## Tokenize a section of HTML text with given initial state.
  var sectionLen = args.endPos - args.startPos
  var sectionText = newString(sectionLen)
  if sectionLen > 0:
    copyMem(addr sectionText[0], addr args.textPtr[args.startPos], sectionLen)

  var tokens: seq[HtmlToken]
  var pos = 0
  var line = args.startLine
  var col = 0

  # Cross-line state from pre-scan
  var inComment = args.initState.inComment
  var inTag = args.initState.inTag
  var inScript = args.initState.inScript
  var inStyle = args.initState.inStyle

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

  proc getLineLen(text: string, lineNum: int, baseStartLine: int): int =
    var ln = baseStartLine
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

  # If we start inside a comment, continue scanning for -->
  if inComment:
    let sLine = line
    let sCol = col
    while pos < sectionText.len:
      if sectionText[pos] == '-' and peek(1) == '-' and peek(2) == '>':
        advance(); advance(); advance()
        break
      advance()
    inComment = false
    # Emit per-line comment tokens
    if sLine == line:
      if col - sCol > 0:
        tokens.add(HtmlToken(kind: htComment, line: sLine, col: sCol, length: col - sCol))
    else:
      let firstLen = getLineLen(sectionText, sLine, args.startLine)
      if firstLen - sCol > 0:
        tokens.add(HtmlToken(kind: htComment, line: sLine, col: sCol, length: firstLen - sCol))
      for ln in (sLine + 1)..<line:
        let lnLen = getLineLen(sectionText, ln, args.startLine)
        if lnLen > 0:
          tokens.add(HtmlToken(kind: htComment, line: ln, col: 0, length: lnLen))
      if col > 0:
        tokens.add(HtmlToken(kind: htComment, line: line, col: 0, length: col))

  # If we start inside script/style content, skip to closing tag
  if inScript:
    while pos < sectionText.len:
      if sectionText[pos] == '<' and pos + 8 < sectionText.len:
        let slice = sectionText[pos..<pos + 8].toLowerAscii()
        if slice == "</script":
          break
      advance()
    inScript = false

  if inStyle:
    while pos < sectionText.len:
      if sectionText[pos] == '<' and pos + 7 < sectionText.len:
        let slice = sectionText[pos..<pos + 7].toLowerAscii()
        if slice == "</style":
          break
      advance()
    inStyle = false

  # If we start inside a tag (attributes area), continue scanning attributes
  if inTag:
    while pos < sectionText.len:
      while pos < sectionText.len and sectionText[pos] in {' ', '\t', '\n', '\r'}:
        advance()
      if pos >= sectionText.len: break

      # Self-closing />
      if sectionText[pos] == '/' and peek(1) == '>':
        let opCol = col
        advance(); advance()
        tokens.add(HtmlToken(kind: htOperator, line: line, col: opCol, length: 2))
        inTag = false
        break

      # Closing >
      if sectionText[pos] == '>':
        let opCol = col
        advance()
        tokens.add(HtmlToken(kind: htOperator, line: line, col: opCol, length: 1))
        inTag = false
        break

      # Attribute name
      if isNameStart(sectionText[pos]) or sectionText[pos] == '-':
        let attrCol = col
        let attrLine = line
        while pos < sectionText.len and isNameChar(sectionText[pos]):
          advance()
        tokens.add(HtmlToken(kind: htProperty, line: attrLine, col: attrCol, length: col - attrCol))

        while pos < sectionText.len and sectionText[pos] in {' ', '\t', '\n', '\r'}:
          advance()

        # = sign
        if pos < sectionText.len and sectionText[pos] == '=':
          let eqCol = col
          advance()
          tokens.add(HtmlToken(kind: htOperator, line: line, col: eqCol, length: 1))

          while pos < sectionText.len and sectionText[pos] in {' ', '\t', '\n', '\r'}:
            advance()

          # Attribute value
          if pos < sectionText.len and sectionText[pos] in {'"', '\''}:
            let q = sectionText[pos]
            let openCol = col
            advance()
            tokens.add(HtmlToken(kind: htString, line: line, col: openCol, length: 1))
            var segCol = col
            var segLine = line
            while pos < sectionText.len and sectionText[pos] != q:
              if sectionText[pos] == '{' and (peek(1) == '{' or peek(1) == '%'):
                let isPercent = peek(1) == '%'
                let closeChar = if isPercent: '%' else: '}'
                if col > segCol or line > segLine:
                  if segLine == line:
                    tokens.add(HtmlToken(kind: htString, line: segLine, col: segCol, length: col - segCol))
                let brCol = col
                advance(); advance()
                tokens.add(HtmlToken(kind: htMacro, line: line, col: brCol, length: 2))
                while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
                  advance()
                let cCol = col
                let cLine = line
                let cStart = pos
                while pos < sectionText.len and sectionText[pos] != q:
                  if sectionText[pos] == closeChar and peek(1) == '}':
                    break
                  if sectionText[pos] == '\n': break
                  advance()
                var trimLen = pos - cStart
                while trimLen > 0 and sectionText[cStart + trimLen - 1] in {' ', '\t'}:
                  dec trimLen
                if trimLen > 0:
                  tokens.add(HtmlToken(kind: htVariable, line: cLine, col: cCol, length: trimLen))
                while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
                  advance()
                if pos < sectionText.len and sectionText[pos] == closeChar and peek(1) == '}':
                  let clCol = col
                  advance(); advance()
                  tokens.add(HtmlToken(kind: htMacro, line: line, col: clCol, length: 2))
                segCol = col
                segLine = line
              else:
                advance()
            if col > segCol or line > segLine:
              if segLine == line:
                tokens.add(HtmlToken(kind: htString, line: segLine, col: segCol, length: col - segCol))
            if pos < sectionText.len and sectionText[pos] == q:
              let clqCol = col
              advance()
              tokens.add(HtmlToken(kind: htString, line: line, col: clqCol, length: 1))
          elif pos < sectionText.len and sectionText[pos] notin {' ', '\t', '\n', '\r', '>', '/'}:
            let valCol = col
            let valLine = line
            while pos < sectionText.len and sectionText[pos] notin {' ', '\t', '\n', '\r', '>', '"', '\''}:
              advance()
            tokens.add(HtmlToken(kind: htString, line: valLine, col: valCol, length: col - valCol))
        continue

      advance()
    # inTag is now false (or we ran out of section)

  # Main tokenization loop
  while pos < sectionText.len:
    let c = ch()

    # Comment <!-- ... -->
    if c == '<' and peek(1) == '!' and peek(2) == '-' and peek(3) == '-':
      let sCol = col
      let sLine = line
      advance(); advance(); advance(); advance() # skip <!--
      while pos < sectionText.len:
        if sectionText[pos] == '-' and peek(1) == '-' and peek(2) == '>':
          advance(); advance(); advance() # skip -->
          break
        advance()
      if sLine == line:
        tokens.add(HtmlToken(kind: htComment, line: sLine, col: sCol, length: col - sCol))
      else:
        let firstLen = getLineLen(sectionText, sLine, args.startLine)
        tokens.add(HtmlToken(kind: htComment, line: sLine, col: sCol, length: firstLen - sCol))
        for ln in (sLine + 1)..<line:
          let lnLen = getLineLen(sectionText, ln, args.startLine)
          if lnLen > 0:
            tokens.add(HtmlToken(kind: htComment, line: ln, col: 0, length: lnLen))
        if col > 0:
          tokens.add(HtmlToken(kind: htComment, line: line, col: 0, length: col))
      continue

    # Template placeholder {{ ... }}
    if c == '{' and peek(1) == '{':
      let sCol = col
      let sLine = line
      advance(); advance()
      tokens.add(HtmlToken(kind: htMacro, line: sLine, col: sCol, length: 2))
      while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
        advance()
      let contentCol = col
      let contentLine = line
      let contentStart = pos
      while pos < sectionText.len:
        if sectionText[pos] == '}' and peek(1) == '}':
          break
        if sectionText[pos] == '\n':
          break
        advance()
      let contentLen = pos - contentStart
      var trimLen = contentLen
      while trimLen > 0 and sectionText[contentStart + trimLen - 1] in {' ', '\t'}:
        dec trimLen
      if trimLen > 0:
        tokens.add(HtmlToken(kind: htVariable, line: contentLine, col: contentCol, length: trimLen))
      while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
        advance()
      if pos < sectionText.len and sectionText[pos] == '}' and peek(1) == '}':
        let closeCol = col
        advance(); advance()
        tokens.add(HtmlToken(kind: htMacro, line: line, col: closeCol, length: 2))
      continue

    # Template tag {% ... %}
    if c == '{' and peek(1) == '%':
      let sCol = col
      let sLine = line
      advance(); advance()
      tokens.add(HtmlToken(kind: htMacro, line: sLine, col: sCol, length: 2))
      while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
        advance()
      let contentCol = col
      let contentLine = line
      let contentStart = pos
      while pos < sectionText.len:
        if sectionText[pos] == '%' and peek(1) == '}':
          break
        if sectionText[pos] == '\n':
          break
        advance()
      let contentLen = pos - contentStart
      var trimLen = contentLen
      while trimLen > 0 and sectionText[contentStart + trimLen - 1] in {' ', '\t'}:
        dec trimLen
      if trimLen > 0:
        tokens.add(HtmlToken(kind: htVariable, line: contentLine, col: contentCol, length: trimLen))
      while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
        advance()
      if pos < sectionText.len and sectionText[pos] == '%' and peek(1) == '}':
        let closeCol = col
        advance(); advance()
        tokens.add(HtmlToken(kind: htMacro, line: line, col: closeCol, length: 2))
      continue

    # DOCTYPE: <!DOCTYPE ...>
    if c == '<' and peek(1) == '!':
      let remaining = sectionText.len - pos
      if remaining >= 10:
        let upper = sectionText[pos..min(pos + 9, sectionText.len - 1)].toUpperAscii()
        if upper.startsWith("<!DOCTYPE"):
          let sCol = col
          let sLine = line
          while pos < sectionText.len and sectionText[pos] != '>':
            advance()
          if pos < sectionText.len: advance()
          tokens.add(HtmlToken(kind: htKeyword, line: sLine, col: sCol, length: col - sCol))
          continue

    # Opening tag < or closing tag </
    if c == '<':
      let sCol = col
      let sLine = line
      let isClosing = peek(1) == '/'

      if isClosing:
        advance(); advance()
        tokens.add(HtmlToken(kind: htOperator, line: sLine, col: sCol, length: 2))
      else:
        advance()
        tokens.add(HtmlToken(kind: htOperator, line: sLine, col: sCol, length: 1))

      while pos < sectionText.len and sectionText[pos] in {' ', '\t', '\n', '\r'}:
        advance()

      var tagNameLower = ""
      if pos < sectionText.len and isNameStart(sectionText[pos]):
        let nameCol = col
        let nameLine = line
        let nameStart = pos
        while pos < sectionText.len and isNameChar(sectionText[pos]):
          advance()
        tokens.add(HtmlToken(kind: htType, line: nameLine, col: nameCol, length: col - nameCol))
        tagNameLower = sectionText[nameStart..<pos].toLowerAscii()

      if isClosing:
        while pos < sectionText.len and sectionText[pos] in {' ', '\t', '\n', '\r'}:
          advance()
        if pos < sectionText.len and sectionText[pos] == '>':
          let gCol = col
          advance()
          tokens.add(HtmlToken(kind: htOperator, line: line, col: gCol, length: 1))
        continue

      # Attributes
      while pos < sectionText.len:
        while pos < sectionText.len and sectionText[pos] in {' ', '\t', '\n', '\r'}:
          advance()
        if pos >= sectionText.len: break

        if sectionText[pos] == '/' and peek(1) == '>':
          let opCol = col
          advance(); advance()
          tokens.add(HtmlToken(kind: htOperator, line: line, col: opCol, length: 2))
          break

        if sectionText[pos] == '>':
          let opCol = col
          advance()
          tokens.add(HtmlToken(kind: htOperator, line: line, col: opCol, length: 1))
          break

        if isNameStart(sectionText[pos]) or sectionText[pos] == '-':
          let attrCol = col
          let attrLine = line
          while pos < sectionText.len and isNameChar(sectionText[pos]):
            advance()
          tokens.add(HtmlToken(kind: htProperty, line: attrLine, col: attrCol, length: col - attrCol))

          while pos < sectionText.len and sectionText[pos] in {' ', '\t', '\n', '\r'}:
            advance()

          if pos < sectionText.len and sectionText[pos] == '=':
            let eqCol = col
            advance()
            tokens.add(HtmlToken(kind: htOperator, line: line, col: eqCol, length: 1))

            while pos < sectionText.len and sectionText[pos] in {' ', '\t', '\n', '\r'}:
              advance()

            if pos < sectionText.len and sectionText[pos] in {'"', '\''}:
              let q = sectionText[pos]
              let openCol = col
              advance()
              tokens.add(HtmlToken(kind: htString, line: line, col: openCol, length: 1))
              var segCol = col
              var segLine = line
              while pos < sectionText.len and sectionText[pos] != q:
                if sectionText[pos] == '{' and (peek(1) == '{' or peek(1) == '%'):
                  let isPercent = peek(1) == '%'
                  let closeChar = if isPercent: '%' else: '}'
                  if col > segCol or line > segLine:
                    if segLine == line:
                      tokens.add(HtmlToken(kind: htString, line: segLine, col: segCol, length: col - segCol))
                  let brCol = col
                  advance(); advance()
                  tokens.add(HtmlToken(kind: htMacro, line: line, col: brCol, length: 2))
                  while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
                    advance()
                  let cCol = col
                  let cLine = line
                  let cStart = pos
                  while pos < sectionText.len and sectionText[pos] != q:
                    if sectionText[pos] == closeChar and peek(1) == '}':
                      break
                    if sectionText[pos] == '\n': break
                    advance()
                  var trimLen2 = pos - cStart
                  while trimLen2 > 0 and sectionText[cStart + trimLen2 - 1] in {' ', '\t'}:
                    dec trimLen2
                  if trimLen2 > 0:
                    tokens.add(HtmlToken(kind: htVariable, line: cLine, col: cCol, length: trimLen2))
                  while pos < sectionText.len and sectionText[pos] in {' ', '\t'}:
                    advance()
                  if pos < sectionText.len and sectionText[pos] == closeChar and peek(1) == '}':
                    let clCol = col
                    advance(); advance()
                    tokens.add(HtmlToken(kind: htMacro, line: line, col: clCol, length: 2))
                  segCol = col
                  segLine = line
                else:
                  advance()
              if col > segCol or line > segLine:
                if segLine == line:
                  tokens.add(HtmlToken(kind: htString, line: segLine, col: segCol, length: col - segCol))
              if pos < sectionText.len and sectionText[pos] == q:
                let clqCol = col
                advance()
                tokens.add(HtmlToken(kind: htString, line: line, col: clqCol, length: 1))
            elif pos < sectionText.len and sectionText[pos] notin {' ', '\t', '\n', '\r', '>', '/'}:
              let valCol = col
              let valLine = line
              while pos < sectionText.len and sectionText[pos] notin {' ', '\t', '\n', '\r', '>', '"', '\''}:
                advance()
              tokens.add(HtmlToken(kind: htString, line: valLine, col: valCol, length: col - valCol))
          continue

        advance()

      # Skip content of script and style tags
      if tagNameLower in ["script", "style"]:
        let closeTag = "</" & tagNameLower
        while pos < sectionText.len:
          if sectionText[pos] == '<' and pos + closeTag.len <= sectionText.len:
            let slice = sectionText[pos..<pos + closeTag.len].toLowerAscii()
            if slice == closeTag:
              break
          advance()
      continue

    # HTML entity
    if c == '&':
      let sCol = col
      let sLine = line
      advance()
      if pos < sectionText.len and sectionText[pos] == '#':
        advance()
        if pos < sectionText.len and sectionText[pos] in {'x', 'X'}:
          advance()
          while pos < sectionText.len and sectionText[pos] in {'0'..'9', 'a'..'f', 'A'..'F'}:
            advance()
        else:
          while pos < sectionText.len and sectionText[pos] in {'0'..'9'}:
            advance()
      else:
        while pos < sectionText.len and sectionText[pos] in {'a'..'z', 'A'..'Z', '0'..'9'}:
          advance()
      if pos < sectionText.len and sectionText[pos] == ';':
        advance()
        tokens.add(HtmlToken(kind: htMacro, line: sLine, col: sCol, length: col - sCol))
      continue

    advance()

  htmlSectionChannels[args.chanIdx].send(tokens)

proc tokenizeHtmlParallel(text: string): seq[HtmlToken] =
  if text.len == 0: return @[]

  var lineOffsets: seq[int] = @[0]
  for i in 0..<text.len:
    if text[i] == '\n': lineOffsets.add(i + 1)
  let totalLines = lineOffsets.len

  if totalLines < ParallelLineThreshold:
    return tokenizeHtml(text)

  let threadCount = min(countProcessors(), MaxTokenThreads)
  if threadCount <= 1:
    return tokenizeHtml(text)

  let textPtr = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
  let linesPerSection = totalLines div threadCount

  # Pre-scan to determine state at each section boundary (sequential, cumulative)
  var states: seq[HtmlTokenizerState] = @[HtmlTokenizerState()]
  for t in 0..<threadCount - 1:
    let sLine = t * linesPerSection
    let eLine = (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    states.add(preScanHtmlState(text, startPos, endPos, states[t]))

  for t in 0..<threadCount:
    let sLine = t * linesPerSection
    let eLine = if t == threadCount - 1: totalLines - 1
                else: (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    htmlSectionChannels[t].open()
    createThread(htmlSectionThreads[t], htmlSectionWorker, HtmlSectionArgs(
      textPtr: textPtr, textLen: text.len,
      startPos: startPos, endPos: endPos,
      startLine: sLine, initState: states[t], chanIdx: t
    ))

  var allTokens: seq[HtmlToken] = @[]
  for t in 0..<threadCount:
    joinThread(htmlSectionThreads[t])
    let (hasData, sectionTokens) = htmlSectionChannels[t].tryRecv()
    if hasData: allTokens.add(sectionTokens)
    htmlSectionChannels[t].close()

  return allTokens

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizeHtmlRange(text: string, startLine, endLine: int): seq[HtmlToken] =
  let allTokens = tokenizeHtmlParallel(text)
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
      of htVariable: stVariable
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
                             "type", "property", "operator", "macro",
                             "variable"],
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
      let tokens = tokenizeHtmlParallel(text)
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
