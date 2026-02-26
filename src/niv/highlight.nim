## Syntax highlighting via LSP semantic tokens
##
## LSP semantic tokens are delta-encoded:
##   data: [deltaLine, deltaStartChar, length, tokenType, tokenModifiers, ...]
## We decode them into per-line token lists for efficient rendering.

type
  SemanticToken* = object
    col*: int        ## Start column (0-indexed)
    length*: int     ## Token length in characters
    tokenType*: int  ## Index into tokenLegend

## Global state: populated from LSP responses
var tokenLegend*: seq[string]       ## Token type names from server capabilities
var semanticLines*: seq[seq[SemanticToken]]  ## Per-line tokens

## Color mapping: token type name -> ANSI color code
proc tokenColor*(typeName: string): int =
  case typeName
  of "keyword", "modifier":
    35   # Magenta
  of "string", "regexp":
    32   # Green
  of "comment":
    90   # Gray
  of "number":
    33   # Yellow
  of "operator":
    91   # Bright red
  of "type", "class", "enum", "interface", "struct", "typeParameter":
    36   # Cyan
  of "function", "method":
    33   # Yellow
  of "macro", "decorator":
    34   # Blue
  of "parameter":
    0    # Default
  of "variable", "property", "enumMember":
    0    # Default
  of "namespace":
    34   # Blue
  else:
    0    # Default (no color)

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
