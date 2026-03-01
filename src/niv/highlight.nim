## Syntax highlighting via LSP semantic tokens

type
  SemanticToken* = object
    col*: int        ## Start column (0-indexed)
    length*: int     ## Token length in characters
    tokenType*: int  ## Index into tokenLegend

## Global state: populated from LSP responses
var tokenLegend*: seq[string]       ## Token type names from server capabilities
var semanticLines*: seq[seq[SemanticToken]]  ## Per-line tokens

## Color mapping: token type name -> 0xRRGGBB (Tokyo Night Storm)
proc tokenColor*(typeName: string): int =
  case typeName
  of "keyword", "modifier":
    0x9d7cd8   # Purple
  of "string", "regexp":
    0x9ece6a   # Green
  of "comment":
    0x565f89   # Gray
  of "number":
    0xff9e64   # Orange
  of "operator":
    0x89ddff   # Cyan
  of "type", "class", "enum", "interface", "struct", "typeParameter":
    0x2ac3de   # Bright cyan
  of "function", "method", "builtinFunction", "heading":
    0x7aa2f7   # Blue
  of "macro", "decorator":
    0x9d7cd8   # Purple
  of "namespace":
    0x7aa2f7   # Blue
  of "parameter":
    0xe0af68   # Yellow
  of "selfParameter", "clsParameter":
    0xf7768e   # Red
  of "property":
    0x73daca   # Teal
  of "builtinConstant":
    0xff9e64   # Orange
  of "variable", "enumMember":
    0          # Default
  else:
    0

proc parseLegend*(serverCapabilities: seq[string]) =
  ## Store the token type legend from the server's initialize response
  tokenLegend = serverCapabilities

proc parseSemanticTokens*(data: seq[int], lineCount: int) =
  ## Decode delta-encoded semantic tokens into per-line lists
  semanticLines = newSeq[seq[SemanticToken]](lineCount)

  var currentLine = 0
  var currentCol = 0
  var i = 0

  while i + 4 < data.len:
    let deltaLine = data[i]
    let deltaStart = data[i + 1]
    let length = data[i + 2]
    let tokenType = data[i + 3]
    # data[i + 4] = tokenModifiers (unused for now)
    i += 5

    if deltaLine > 0:
      currentLine += deltaLine
      currentCol = deltaStart
    else:
      currentCol += deltaStart

    if currentLine < lineCount:
      semanticLines[currentLine].add(SemanticToken(
        col: currentCol,
        length: length,
        tokenType: tokenType,
      ))

proc clearSemanticTokens*() =
  semanticLines = @[]

proc clearTokenLegend*() =
  tokenLegend = @[]

# ---------------------------------------------------------------------------
# Token shifting for Insert mode edits
# ---------------------------------------------------------------------------

proc shiftTokensRight*(lineNum: int, fromCol: int, amount: int) =
  ## After insertChar: shift tokens right from insertion point
  if lineNum >= semanticLines.len: return
  for i in 0..<semanticLines[lineNum].len:
    if semanticLines[lineNum][i].col >= fromCol:
      semanticLines[lineNum][i].col += amount
    elif semanticLines[lineNum][i].col + semanticLines[lineNum][i].length > fromCol:
      semanticLines[lineNum][i].length += amount

proc shiftTokensLeft*(lineNum: int, fromCol: int, amount: int) =
  ## After deleteChar: shift tokens left from deletion point
  if lineNum >= semanticLines.len: return
  var toRemove: seq[int]
  for i in 0..<semanticLines[lineNum].len:
    if semanticLines[lineNum][i].col > fromCol:
      semanticLines[lineNum][i].col -= amount
    elif semanticLines[lineNum][i].col + semanticLines[lineNum][i].length > fromCol:
      semanticLines[lineNum][i].length -= amount
      if semanticLines[lineNum][i].length <= 0:
        toRemove.add(i)
  for i in countdown(toRemove.len - 1, 0):
    semanticLines[lineNum].delete(toRemove[i])

proc splitSemanticLine*(lineNum: int, splitCol: int) =
  ## After splitLine (Enter): split tokens at splitCol into two lines
  if lineNum >= semanticLines.len:
    if semanticLines.len > lineNum:
      semanticLines.insert(@[], lineNum + 1)
    return
  var keepTokens: seq[SemanticToken]
  var moveTokens: seq[SemanticToken]
  for tok in semanticLines[lineNum]:
    if tok.col + tok.length <= splitCol:
      keepTokens.add(tok)
    elif tok.col >= splitCol:
      moveTokens.add(SemanticToken(col: tok.col - splitCol,
                                    length: tok.length,
                                    tokenType: tok.tokenType))
    else:
      keepTokens.add(SemanticToken(col: tok.col,
                                    length: splitCol - tok.col,
                                    tokenType: tok.tokenType))
      let remainder = tok.length - (splitCol - tok.col)
      if remainder > 0:
        moveTokens.add(SemanticToken(col: 0, length: remainder,
                                      tokenType: tok.tokenType))
  semanticLines[lineNum] = keepTokens
  semanticLines.insert(moveTokens, lineNum + 1)

proc insertSemanticLine*(lineNum: int) =
  ## Insert an empty semantic token line at lineNum, shifting lines below down
  if lineNum <= semanticLines.len:
    semanticLines.insert(@[], lineNum)

proc deleteSemanticLine*(lineNum: int) =
  ## Remove semantic token line at lineNum, shifting lines below up
  if lineNum < semanticLines.len:
    semanticLines.delete(lineNum)

proc joinSemanticLines*(lineNum: int, joinCol: int) =
  ## After joinLines (Backspace at line start): merge lineNum+1 into lineNum
  if lineNum >= semanticLines.len: return
  if lineNum + 1 < semanticLines.len:
    for tok in semanticLines[lineNum + 1]:
      semanticLines[lineNum].add(SemanticToken(
        col: tok.col + joinCol,
        length: tok.length,
        tokenType: tok.tokenType))
    semanticLines.delete(lineNum + 1)
