## Syntax highlighting
##
## Two sources:
##   1. LSP semantic tokens (if server supports semanticTokensProvider)
##   2. Tree-sitter highlight queries (fallback)
##
## Priority: LSP semantic tokens > tree-sitter > plain text

import std/strutils

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

# ---------------------------------------------------------------------------
# Tree-sitter tokens
# ---------------------------------------------------------------------------

type
  TsToken* = object
    col*: int
    length*: int
    color*: int  ## 0xRRGGBB encoded color

var tsLines*: seq[seq[TsToken]]

proc captureColor*(captureName: string): int =
  ## Map tree-sitter capture name to 0xRRGGBB (Tokyo Night Storm).
  ## Handles dotted names by checking the base prefix.
  let base = if '.' in captureName: captureName.split('.')[0]
             else: captureName
  case base
  of "keyword": 0x9d7cd8       # Purple
  of "conditional": 0x9d7cd8
  of "repeat": 0x9d7cd8
  of "include": 0x9d7cd8
  of "exception": 0x9d7cd8
  of "string": 0x9ece6a        # Green
  of "character": 0x9ece6a
  of "comment": 0x565f89       # Gray
  of "number": 0xff9e64        # Orange
  of "float": 0xff9e64
  of "boolean": 0xff9e64
  of "constant": 0xff9e64
  of "operator": 0x89ddff      # Cyan
  of "type": 0x2ac3de          # Bright cyan
  of "constructor": 0x2ac3de
  of "label": 0x2ac3de
  of "attribute": 0x2ac3de
  of "function": 0x7aa2f7      # Blue
  of "method": 0x7aa2f7
  of "macro": 0x9d7cd8         # Purple
  of "namespace": 0x7aa2f7     # Blue
  of "tag": 0x7aa2f7
  of "variable": 0
  of "property": 0x73daca      # Teal
  of "parameter": 0xe0af68     # Yellow
  of "punctuation": 0
  else: 0

proc clearTsHighlight*() =
  tsLines = @[]
