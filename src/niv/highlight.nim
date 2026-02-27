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
  of "function", "method", "builtinFunction":
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
