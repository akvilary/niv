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

# ---------------------------------------------------------------------------
# Tree-sitter tokens
# ---------------------------------------------------------------------------

type
  TsToken* = object
    col*: int
    length*: int
    color*: int  ## Direct ANSI color code

var tsLines*: seq[seq[TsToken]]

proc captureColor*(captureName: string): int =
  ## Map tree-sitter capture name (@keyword, @string.special, etc.) to ANSI color.
  ## Handles dotted names by checking the base prefix.
  let base = if '.' in captureName: captureName.split('.')[0]
             else: captureName
  case base
  of "keyword": 35       # Magenta
  of "conditional": 35   # Magenta
  of "repeat": 35        # Magenta
  of "include": 35       # Magenta
  of "exception": 35     # Magenta
  of "string": 32        # Green
  of "character": 32     # Green
  of "comment": 90       # Gray
  of "number": 33        # Yellow
  of "float": 33         # Yellow
  of "boolean": 33       # Yellow
  of "constant": 33      # Yellow
  of "operator": 91      # Bright red
  of "type": 36          # Cyan
  of "constructor": 36   # Cyan
  of "label": 36         # Cyan
  of "attribute": 36     # Cyan
  of "function": 33      # Yellow
  of "method": 33        # Yellow
  of "macro": 34         # Blue
  of "namespace": 34     # Blue
  of "tag": 34           # Blue
  of "variable": 0       # Default
  of "property": 0       # Default
  of "parameter": 0      # Default
  of "punctuation": 0    # Default
  else: 0

proc clearTsHighlight*() =
  tsLines = @[]
