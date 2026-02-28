## niv_css_lsp — minimal CSS Language Server with semantic tokens
## Communicates via stdin/stdout using JSON-RPC 2.0 with Content-Length framing

import std/[json, strutils, cpuinfo]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  CssTokenKind = enum
    ctKeyword      # @media, @import, @keyframes, !important, and, or, not
    ctString       # "..." and '...'
    ctNumber       # numeric values with units: 10px, 1.5em, 50%, #fff
    ctComment      # /* ... */
    ctType         # tag selectors: div, span, body, a, *
    ctProperty     # property names: color, margin, display
    ctFunction     # CSS functions: rgb(), calc(), var(), url()
    ctOperator     # { } : ; > + ~ ,
    ctParameter    # CSS custom properties: --custom-var
    ctClass        # .class, #id, :pseudo-class, ::pseudo-element

  CssToken = object
    kind: CssTokenKind
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
  stType = 4
  stProperty = 5
  stFunction = 6
  stOperator = 7
  stParameter = 8
  stClass = 9

# Common CSS HTML tag names for selector detection
const cssTagNames = [
  "a", "abbr", "address", "area", "article", "aside", "audio",
  "b", "base", "bdi", "bdo", "blockquote", "body", "br", "button",
  "canvas", "caption", "cite", "code", "col", "colgroup",
  "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt",
  "em", "embed",
  "fieldset", "figcaption", "figure", "footer", "form",
  "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html",
  "i", "iframe", "img", "input", "ins",
  "kbd",
  "label", "legend", "li", "link",
  "main", "map", "mark", "math", "menu", "menuitem", "meta", "meter",
  "nav", "noscript",
  "object", "ol", "optgroup", "option", "output",
  "p", "param", "picture", "pre", "progress",
  "q",
  "rb", "rp", "rt", "rtc", "ruby",
  "s", "samp", "script", "section", "select", "slot", "small", "source",
  "span", "strong", "style", "sub", "summary", "sup", "svg",
  "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
  "time", "title", "tr", "track",
  "u", "ul",
  "var", "video",
  "wbr",
]

const cssAtKeywords = [
  "media", "import", "keyframes", "font-face", "charset", "supports",
  "layer", "container", "property", "namespace", "page", "counter-style",
  "font-feature-values", "scope", "starting-style",
]

# ---------------------------------------------------------------------------
# CSS Tokenizer
# ---------------------------------------------------------------------------

proc isWordChar(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}

proc isIdentStart(c: char): bool =
  c in {'A'..'Z', 'a'..'z', '_'}

proc isDigit(c: char): bool =
  c in {'0'..'9'}

proc isHexDigit(c: char): bool =
  c in {'0'..'9', 'a'..'f', 'A'..'F'}

proc isTagName(word: string): bool =
  for tag in cssTagNames:
    if tag == word: return true
  return false

proc tokenizeCss(text: string): seq[CssToken] =
  var tokens: seq[CssToken]
  var pos = 0
  var line = 0
  var col = 0
  var braceDepth = 0 # track { } nesting
  var inValue = false # after : inside declaration block
  var inAtRuleBlock: seq[bool] # stack: true = at-rule block (selectors inside), false = decl block
  var afterAtRule = false # next { is from an at-rule

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

  while pos < text.len:
    let c = ch()

    # Newline
    if c == '\n':
      advance()
      continue

    # Whitespace
    if c in {' ', '\t', '\r'}:
      advance()
      continue

    # Comment /* ... */
    if c == '/' and peek(1) == '*':
      let sCol = col
      let sLine = line
      advance(); advance() # skip /*
      while pos < text.len:
        if text[pos] == '*' and peek(1) == '/':
          advance(); advance() # skip */
          break
        advance()
      # Emit per-line tokens for multi-line comments
      if sLine == line:
        tokens.add(CssToken(kind: ctComment, line: sLine, col: sCol,
                             length: col - sCol))
      else:
        # First line
        let firstLineText = text.split('\n')
        var lineTexts: seq[string]
        var scanPos = 0
        var currentLineStart = 0
        for i in 0..<text.len:
          if text[i] == '\n':
            lineTexts.add(text[currentLineStart..<i])
            currentLineStart = i + 1
        lineTexts.add(text[currentLineStart..<text.len])
        if sLine < lineTexts.len:
          tokens.add(CssToken(kind: ctComment, line: sLine, col: sCol,
                               length: lineTexts[sLine].len - sCol))
        for ln in (sLine + 1)..<line:
          if ln < lineTexts.len:
            tokens.add(CssToken(kind: ctComment, line: ln, col: 0,
                                 length: lineTexts[ln].len))
        if line < lineTexts.len:
          tokens.add(CssToken(kind: ctComment, line: line, col: 0,
                               length: col))
      continue

    # String "..." or '...'
    if c == '"' or c == '\'':
      let q = c
      let sCol = col
      let sLine = line
      advance() # skip opening quote
      while pos < text.len and text[pos] != q:
        if text[pos] == '\\' and pos + 1 < text.len:
          advance()
        advance()
      if pos < text.len: advance() # skip closing quote
      if sLine == line:
        tokens.add(CssToken(kind: ctString, line: sLine, col: sCol,
                             length: col - sCol))
      continue

    # At-rules: @media, @import, etc.
    if c == '@':
      let sCol = col
      let sLine = line
      advance() # skip @
      let wordStart = pos
      while pos < text.len and isWordChar(text[pos]):
        advance()
      let word = text[wordStart..<pos]
      tokens.add(CssToken(kind: ctKeyword, line: sLine, col: sCol,
                           length: 1 + word.len))
      # At-rules that contain nested rules (not just declarations)
      if word in ["media", "supports", "layer", "container", "scope",
                   "starting-style", "keyframes"]:
        afterAtRule = true
      continue

    # Helper: are we in selector context?
    let inSelectorCtx = braceDepth == 0 or
      (inAtRuleBlock.len > 0 and inAtRuleBlock[^1])

    # Hex color: #fff or #aabbcc (inside value context)
    if c == '#' and not inSelectorCtx and inValue:
      let sCol = col
      let sLine = line
      advance() # skip #
      while pos < text.len and isHexDigit(text[pos]):
        advance()
      tokens.add(CssToken(kind: ctNumber, line: sLine, col: sCol,
                           length: col - sCol))
      continue

    # Class selector .name or ID selector #name (in selector context)
    if (c == '.' or c == '#') and inSelectorCtx:
      let sCol = col
      let sLine = line
      advance() # skip . or #
      while pos < text.len and isWordChar(text[pos]):
        advance()
      if col - sCol > 1:
        tokens.add(CssToken(kind: ctClass, line: sLine, col: sCol,
                             length: col - sCol))
      continue

    # Pseudo-class :name or pseudo-element ::name (in selector context)
    if c == ':' and inSelectorCtx:
      let sCol = col
      let sLine = line
      advance() # skip first :
      if pos < text.len and text[pos] == ':':
        advance() # skip second : for ::pseudo-element
      if pos < text.len and isIdentStart(text[pos]):
        while pos < text.len and isWordChar(text[pos]):
          advance()
        tokens.add(CssToken(kind: ctClass, line: sLine, col: sCol,
                             length: col - sCol))
      else:
        # Just a colon in selector context
        tokens.add(CssToken(kind: ctOperator, line: sLine, col: sCol, length: 1))
      continue

    # Colon inside declaration block — property/value separator
    if c == ':' and not inSelectorCtx:
      let sCol = col
      advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      inValue = true
      continue

    # Semicolon — end of declaration
    if c == ';':
      let sCol = col
      advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      inValue = false
      continue

    # Opening brace
    if c == '{':
      let sCol = col
      advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      inc braceDepth
      inAtRuleBlock.add(afterAtRule)
      afterAtRule = false
      inValue = false
      continue

    # Closing brace
    if c == '}':
      let sCol = col
      advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      if braceDepth > 0: dec braceDepth
      if inAtRuleBlock.len > 0: discard inAtRuleBlock.pop()
      inValue = false
      continue

    # Comma
    if c == ',':
      let sCol = col
      advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      continue

    # Combinators > + ~ in selector context
    if c in {'>', '+', '~'} and inSelectorCtx:
      let sCol = col
      advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      continue

    # !important
    if c == '!' and braceDepth > 0:
      let sCol = col
      let sLine = line
      advance() # skip !
      # skip whitespace
      while pos < text.len and text[pos] in {' ', '\t'}:
        advance()
      let wordStart = pos
      while pos < text.len and text[pos] in {'a'..'z', 'A'..'Z'}:
        advance()
      let word = text[wordStart..<pos]
      if word == "important":
        tokens.add(CssToken(kind: ctKeyword, line: sLine, col: sCol,
                             length: col - sCol))
      continue

    # Number (possibly with unit) or hex color inside values
    if isDigit(c) or (c == '.' and isDigit(peek(1))):
      let sCol = col
      let sLine = line
      # Integer part
      while pos < text.len and isDigit(text[pos]):
        advance()
      # Decimal part
      if pos < text.len and text[pos] == '.' and pos + 1 < text.len and isDigit(text[pos + 1]):
        advance() # skip .
        while pos < text.len and isDigit(text[pos]):
          advance()
      # Unit suffix: px, em, rem, %, vh, vw, etc.
      if pos < text.len and text[pos] == '%':
        advance()
      elif pos < text.len and text[pos] in {'a'..'z', 'A'..'Z'}:
        while pos < text.len and text[pos] in {'a'..'z', 'A'..'Z'}:
          advance()
      tokens.add(CssToken(kind: ctNumber, line: sLine, col: sCol,
                           length: col - sCol))
      continue

    # Universal selector *
    if c == '*' and inSelectorCtx:
      let sCol = col
      advance()
      tokens.add(CssToken(kind: ctType, line: line, col: sCol, length: 1))
      continue

    # Attribute selector [...] — skip for now
    if c == '[':
      advance()
      while pos < text.len and text[pos] != ']':
        if text[pos] == '"' or text[pos] == '\'':
          let q = text[pos]
          advance()
          while pos < text.len and text[pos] != q:
            if text[pos] == '\\': advance()
            advance()
          if pos < text.len: advance()
        else:
          advance()
      if pos < text.len: advance() # skip ]
      continue

    # Parentheses (for function arguments, media queries)
    if c == '(':
      advance()
      continue
    if c == ')':
      advance()
      continue

    # Word: identifier, property name, tag name, value keyword, function name
    if isIdentStart(c) or c == '-':
      let sCol = col
      let sLine = line
      let sPos = pos

      # Handle -- custom property
      if c == '-' and peek(1) == '-':
        advance(); advance() # skip --
        while pos < text.len and isWordChar(text[pos]):
          advance()
        tokens.add(CssToken(kind: ctParameter, line: sLine, col: sCol,
                             length: col - sCol))
        continue

      # Regular word
      while pos < text.len and isWordChar(text[pos]):
        advance()
      let word = text[sPos..<pos]

      # Skip single - that isn't part of identifier
      if word == "-":
        continue

      # Check if function call: word(
      if pos < text.len and text[pos] == '(':
        tokens.add(CssToken(kind: ctFunction, line: sLine, col: sCol,
                             length: word.len))
        continue

      # Media query keywords
      if word in ["and", "or", "not", "only"]:
        tokens.add(CssToken(kind: ctKeyword, line: sLine, col: sCol,
                             length: word.len))
        continue

      # Context-dependent classification
      if inSelectorCtx:
        # In selector context
        if isTagName(word):
          tokens.add(CssToken(kind: ctType, line: sLine, col: sCol,
                               length: word.len))
        # else: skip unknown selectors (could be custom element names etc.)
        continue

      # Inside declaration block
      if not inValue:
        # Property name (before colon)
        tokens.add(CssToken(kind: ctProperty, line: sLine, col: sCol,
                             length: word.len))
      # else: value words (auto, none, block, etc.) — leave unhighlighted
      continue

    # Skip unknown characters
    advance()

  return tokens

# ---------------------------------------------------------------------------
# Parallel Tokenizer
# ---------------------------------------------------------------------------

const
  MaxTokenThreads = 4
  ParallelLineThreshold = 4000

type
  CssTokenizerState = object
    braceDepth: int
    inValue: bool
    inAtRuleBlock: seq[bool]
    afterAtRule: bool

  CssSectionArgs = object
    textPtr: ptr UncheckedArray[char]
    textLen: int
    startPos: int
    endPos: int
    startLine: int
    initState: CssTokenizerState
    chanIdx: int

var cssSectionChannels: array[MaxTokenThreads, Channel[seq[CssToken]]]
var cssSectionThreads: array[MaxTokenThreads, Thread[CssSectionArgs]]

proc preScanCssState(text: string, startPos, endPos: int, initState: CssTokenizerState): CssTokenizerState =
  ## Lightweight pre-scan tracking only cross-line state variables.
  result = initState
  var pos = startPos
  while pos < endPos:
    # Skip comments
    if pos + 1 < endPos and text[pos] == '/' and text[pos+1] == '*':
      pos += 2
      while pos + 1 < endPos:
        if text[pos] == '*' and text[pos+1] == '/':
          pos += 2
          break
        inc pos
      continue
    # Skip strings
    if text[pos] in {'"', '\''}:
      let q = text[pos]; inc pos
      while pos < endPos and text[pos] != q and text[pos] != '\n':
        if text[pos] == '\\' and pos + 1 < endPos: inc pos
        inc pos
      if pos < endPos and text[pos] == q: inc pos
      continue
    case text[pos]
    of '{':
      inc result.braceDepth
      result.inAtRuleBlock.add(result.afterAtRule)
      result.afterAtRule = false
      result.inValue = false
    of '}':
      if result.braceDepth > 0: dec result.braceDepth
      if result.inAtRuleBlock.len > 0: discard result.inAtRuleBlock.pop()
      result.inValue = false
    of ';':
      result.inValue = false
    of ':':
      let inSelectorCtx = result.braceDepth == 0 or
        (result.inAtRuleBlock.len > 0 and result.inAtRuleBlock[^1])
      if not inSelectorCtx:
        result.inValue = true
    of '@':
      inc pos
      var wordStart = pos
      while pos < endPos and text[pos] in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}:
        inc pos
      let word = text[wordStart..<pos]
      if word in ["media", "supports", "layer", "container", "scope",
                   "starting-style", "keyframes"]:
        result.afterAtRule = true
      continue
    else: discard
    inc pos

proc cssSectionWorker(args: CssSectionArgs) {.thread.} =
  ## Tokenize a section of CSS text with given initial state.
  var sectionLen = args.endPos - args.startPos
  var sectionText = newString(sectionLen)
  if sectionLen > 0:
    copyMem(addr sectionText[0], addr args.textPtr[args.startPos], sectionLen)

  var tokens: seq[CssToken]
  var pos = 0
  var line = args.startLine
  var col = 0
  var braceDepth = args.initState.braceDepth
  var inValue = args.initState.inValue
  var inAtRuleBlock = args.initState.inAtRuleBlock
  var afterAtRule = args.initState.afterAtRule

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

  while pos < sectionText.len:
    let c = ch()

    if c == '\n': advance(); continue
    if c in {' ', '\t', '\r'}: advance(); continue

    # Comment /* ... */
    if c == '/' and peek(1) == '*':
      let sCol = col
      let sLine = line
      advance(); advance()
      while pos < sectionText.len:
        if sectionText[pos] == '*' and peek(1) == '/':
          advance(); advance()
          break
        advance()
      if sLine == line:
        tokens.add(CssToken(kind: ctComment, line: sLine, col: sCol, length: col - sCol))
      else:
        var lineTexts: seq[string]
        var currentLineStart = 0
        for i in 0..<sectionText.len:
          if sectionText[i] == '\n':
            lineTexts.add(sectionText[currentLineStart..<i])
            currentLineStart = i + 1
        lineTexts.add(sectionText[currentLineStart..<sectionText.len])
        let relSLine = sLine - args.startLine
        let relLine = line - args.startLine
        if relSLine < lineTexts.len:
          tokens.add(CssToken(kind: ctComment, line: sLine, col: sCol,
                               length: lineTexts[relSLine].len - sCol))
        for ln in (sLine + 1)..<line:
          let relLn = ln - args.startLine
          if relLn < lineTexts.len:
            tokens.add(CssToken(kind: ctComment, line: ln, col: 0,
                                 length: lineTexts[relLn].len))
        if relLine < lineTexts.len:
          tokens.add(CssToken(kind: ctComment, line: line, col: 0, length: col))
      continue

    # String
    if c == '"' or c == '\'':
      let q = c
      let sCol = col; let sLine = line
      advance()
      while pos < sectionText.len and sectionText[pos] != q:
        if sectionText[pos] == '\\' and pos + 1 < sectionText.len: advance()
        advance()
      if pos < sectionText.len: advance()
      if sLine == line:
        tokens.add(CssToken(kind: ctString, line: sLine, col: sCol, length: col - sCol))
      continue

    # At-rules
    if c == '@':
      let sCol = col; let sLine = line
      advance()
      let wordStart = pos
      while pos < sectionText.len and isWordChar(sectionText[pos]): advance()
      let word = sectionText[wordStart..<pos]
      tokens.add(CssToken(kind: ctKeyword, line: sLine, col: sCol, length: 1 + word.len))
      if word in ["media", "supports", "layer", "container", "scope",
                   "starting-style", "keyframes"]:
        afterAtRule = true
      continue

    let inSelectorCtx = braceDepth == 0 or
      (inAtRuleBlock.len > 0 and inAtRuleBlock[^1])

    # Hex color
    if c == '#' and not inSelectorCtx and inValue:
      let sCol = col; let sLine = line
      advance()
      while pos < sectionText.len and isHexDigit(sectionText[pos]): advance()
      tokens.add(CssToken(kind: ctNumber, line: sLine, col: sCol, length: col - sCol))
      continue

    # Class/ID selector
    if (c == '.' or c == '#') and inSelectorCtx:
      let sCol = col; let sLine = line
      advance()
      while pos < sectionText.len and isWordChar(sectionText[pos]): advance()
      if col - sCol > 1:
        tokens.add(CssToken(kind: ctClass, line: sLine, col: sCol, length: col - sCol))
      continue

    # Pseudo-class/element
    if c == ':' and inSelectorCtx:
      let sCol = col; let sLine = line
      advance()
      if pos < sectionText.len and sectionText[pos] == ':': advance()
      if pos < sectionText.len and isIdentStart(sectionText[pos]):
        while pos < sectionText.len and isWordChar(sectionText[pos]): advance()
        tokens.add(CssToken(kind: ctClass, line: sLine, col: sCol, length: col - sCol))
      else:
        tokens.add(CssToken(kind: ctOperator, line: sLine, col: sCol, length: 1))
      continue

    # Colon in declaration
    if c == ':' and not inSelectorCtx:
      let sCol = col
      advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      inValue = true
      continue

    if c == ';':
      let sCol = col; advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      inValue = false
      continue

    if c == '{':
      let sCol = col; advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      inc braceDepth
      inAtRuleBlock.add(afterAtRule)
      afterAtRule = false
      inValue = false
      continue

    if c == '}':
      let sCol = col; advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      if braceDepth > 0: dec braceDepth
      if inAtRuleBlock.len > 0: discard inAtRuleBlock.pop()
      inValue = false
      continue

    if c == ',':
      let sCol = col; advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      continue

    if c in {'>', '+', '~'} and inSelectorCtx:
      let sCol = col; advance()
      tokens.add(CssToken(kind: ctOperator, line: line, col: sCol, length: 1))
      continue

    if c == '!' and braceDepth > 0:
      let sCol = col; let sLine = line
      advance()
      while pos < sectionText.len and sectionText[pos] in {' ', '\t'}: advance()
      let wordStart = pos
      while pos < sectionText.len and sectionText[pos] in {'a'..'z', 'A'..'Z'}: advance()
      let word = sectionText[wordStart..<pos]
      if word == "important":
        tokens.add(CssToken(kind: ctKeyword, line: sLine, col: sCol, length: col - sCol))
      continue

    if isDigit(c) or (c == '.' and isDigit(peek(1))):
      let sCol = col; let sLine = line
      while pos < sectionText.len and isDigit(sectionText[pos]): advance()
      if pos < sectionText.len and sectionText[pos] == '.' and pos + 1 < sectionText.len and isDigit(sectionText[pos + 1]):
        advance()
        while pos < sectionText.len and isDigit(sectionText[pos]): advance()
      if pos < sectionText.len and sectionText[pos] == '%':
        advance()
      elif pos < sectionText.len and sectionText[pos] in {'a'..'z', 'A'..'Z'}:
        while pos < sectionText.len and sectionText[pos] in {'a'..'z', 'A'..'Z'}: advance()
      tokens.add(CssToken(kind: ctNumber, line: sLine, col: sCol, length: col - sCol))
      continue

    if c == '*' and inSelectorCtx:
      let sCol = col; advance()
      tokens.add(CssToken(kind: ctType, line: line, col: sCol, length: 1))
      continue

    if c == '[':
      advance()
      while pos < sectionText.len and sectionText[pos] != ']':
        if sectionText[pos] in {'"', '\''}:
          let q = sectionText[pos]; advance()
          while pos < sectionText.len and sectionText[pos] != q:
            if sectionText[pos] == '\\': advance()
            advance()
          if pos < sectionText.len: advance()
        else: advance()
      if pos < sectionText.len: advance()
      continue

    if c == '(': advance(); continue
    if c == ')': advance(); continue

    if isIdentStart(c) or c == '-':
      let sCol = col; let sLine = line; let sPos = pos
      if c == '-' and peek(1) == '-':
        advance(); advance()
        while pos < sectionText.len and isWordChar(sectionText[pos]): advance()
        tokens.add(CssToken(kind: ctParameter, line: sLine, col: sCol, length: col - sCol))
        continue
      while pos < sectionText.len and isWordChar(sectionText[pos]): advance()
      let word = sectionText[sPos..<pos]
      if word == "-": continue
      if pos < sectionText.len and sectionText[pos] == '(':
        tokens.add(CssToken(kind: ctFunction, line: sLine, col: sCol, length: word.len))
        continue
      if word in ["and", "or", "not", "only"]:
        tokens.add(CssToken(kind: ctKeyword, line: sLine, col: sCol, length: word.len))
        continue
      if inSelectorCtx:
        if isTagName(word):
          tokens.add(CssToken(kind: ctType, line: sLine, col: sCol, length: word.len))
        continue
      if not inValue:
        tokens.add(CssToken(kind: ctProperty, line: sLine, col: sCol, length: word.len))
      continue

    advance()

  cssSectionChannels[args.chanIdx].send(tokens)

proc tokenizeCssParallel(text: string): seq[CssToken] =
  if text.len == 0: return @[]

  var lineOffsets: seq[int] = @[0]
  for i in 0..<text.len:
    if text[i] == '\n': lineOffsets.add(i + 1)
  let totalLines = lineOffsets.len

  if totalLines < ParallelLineThreshold:
    return tokenizeCss(text)

  let threadCount = min(countProcessors(), MaxTokenThreads)
  if threadCount <= 1:
    return tokenizeCss(text)

  let textPtr = cast[ptr UncheckedArray[char]](unsafeAddr text[0])
  let linesPerSection = totalLines div threadCount

  # Pre-scan to determine state at each section boundary (sequential, cumulative)
  var states: seq[CssTokenizerState] = @[CssTokenizerState()]
  for t in 0..<threadCount - 1:
    let sLine = t * linesPerSection
    let eLine = (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    states.add(preScanCssState(text, startPos, endPos, states[t]))

  for t in 0..<threadCount:
    let sLine = t * linesPerSection
    let eLine = if t == threadCount - 1: totalLines - 1
                else: (t + 1) * linesPerSection - 1
    let startPos = lineOffsets[sLine]
    let endPos = if eLine + 1 < lineOffsets.len: lineOffsets[eLine + 1] else: text.len
    cssSectionChannels[t].open()
    createThread(cssSectionThreads[t], cssSectionWorker, CssSectionArgs(
      textPtr: textPtr, textLen: text.len,
      startPos: startPos, endPos: endPos,
      startLine: sLine, initState: states[t], chanIdx: t
    ))

  var allTokens: seq[CssToken] = @[]
  for t in 0..<threadCount:
    joinThread(cssSectionThreads[t])
    let (hasData, sectionTokens) = cssSectionChannels[t].tryRecv()
    if hasData: allTokens.add(sectionTokens)
    cssSectionChannels[t].close()

  return allTokens

# ---------------------------------------------------------------------------
# Range Tokenizer
# ---------------------------------------------------------------------------

proc tokenizeCssRange(text: string, startLine, endLine: int): seq[CssToken] =
  let allTokens = tokenizeCssParallel(text)
  result = @[]
  for tok in allTokens:
    if tok.line >= startLine and tok.line <= endLine:
      result.add(tok)

# ---------------------------------------------------------------------------
# Semantic Token Encoding (LSP delta encoding)
# ---------------------------------------------------------------------------

proc encodeSemanticTokens(tokens: seq[CssToken]): seq[int] =
  result = @[]
  var prevLine = 0
  var prevCol = 0
  for tok in tokens:
    if tok.length <= 0: continue
    let deltaLine = tok.line - prevLine
    let deltaCol = if deltaLine == 0: tok.col - prevCol else: tok.col
    let tokenType = case tok.kind
      of ctKeyword: stKeyword
      of ctString: stString
      of ctNumber: stNumber
      of ctComment: stComment
      of ctType: stType
      of ctProperty: stProperty
      of ctFunction: stFunction
      of ctOperator: stOperator
      of ctParameter: stParameter
      of ctClass: stClass
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
                             "type", "property", "function", "operator",
                             "parameter", "class"],
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
      let tokens = tokenizeCssParallel(text)
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
      let tokens = tokenizeCssRange(text, startLine, endLine)
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
