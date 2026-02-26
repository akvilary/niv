## Tree-sitter based syntax highlighting
##
## Loads grammar .so files via dlopen, parses files into AST,
## runs highlight queries, and populates tsLines for rendering.

import std/[dynlib, os]
import ts_bindings
import ts_manager
import highlight

type
  TsHighlightState* = object
    parser*: ptr TSParser
    tree*: ptr TSTree
    query*: ptr TSQuery
    language*: ptr TSLanguage
    langName*: string
    libHandle*: LibHandle
    active*: bool

var tsState*: TsHighlightState

proc tsCleanup*() =
  ## Free all tree-sitter resources
  if tsState.tree != nil:
    ts_tree_delete(tsState.tree)
    tsState.tree = nil
  if tsState.query != nil:
    ts_query_delete(tsState.query)
    tsState.query = nil
  if tsState.parser != nil:
    ts_parser_delete(tsState.parser)
    tsState.parser = nil
  if tsState.libHandle != nil:
    unloadLib(tsState.libHandle)
    tsState.libHandle = nil
  tsState.language = nil
  tsState.langName = ""
  tsState.active = false
  clearTsHighlight()

proc loadGrammar*(lang: string): bool =
  ## Load a grammar .so and its highlights.scm query
  let soPath = grammarSoPath(lang)
  if not fileExists(soPath):
    return false

  # Find function name from registry
  var funcName = ""
  for g in tsMgr.grammars:
    if g.name == lang:
      funcName = g.funcName
      break
  if funcName.len == 0:
    return false

  # Load shared library
  let lib = loadLib(soPath)
  if lib == nil:
    return false

  # Get language function
  let langFn = cast[TSLanguageFunc](lib.symAddr(funcName.cstring))
  if langFn == nil:
    unloadLib(lib)
    return false

  let language = langFn()
  if language == nil:
    unloadLib(lib)
    return false

  # Load highlights.scm query
  let queryPath = grammarQueryPath(lang)
  if not fileExists(queryPath):
    unloadLib(lib)
    return false

  let querySource = readFile(queryPath)
  var errorOffset: uint32
  var errorType: TSQueryError
  let query = ts_query_new(language, querySource.cstring,
                            uint32(querySource.len),
                            addr errorOffset, addr errorType)
  if query == nil:
    unloadLib(lib)
    return false

  # Clean up previous state
  tsCleanup()

  # Set up new state
  tsState.parser = ts_parser_new()
  discard ts_parser_set_language(tsState.parser, language)
  tsState.language = language
  tsState.query = query
  tsState.langName = lang
  tsState.libHandle = lib
  tsState.active = true
  return true

proc tsParseAndHighlight*(text: string, lineCount: int) =
  ## Parse text with tree-sitter and populate tsLines
  if not tsState.active or tsState.parser == nil:
    return

  # Parse
  if tsState.tree != nil:
    ts_tree_delete(tsState.tree)
  tsState.tree = ts_parser_parse_string(
    tsState.parser, nil,
    text.cstring, uint32(text.len))
  if tsState.tree == nil:
    return

  # Build per-line token lists
  var result = newSeq[seq[TsToken]](lineCount)
  let rootNode = ts_tree_root_node(tsState.tree)

  # Execute highlight query
  let cursor = ts_query_cursor_new()
  ts_query_cursor_exec(cursor, tsState.query, rootNode)

  var match: TSQueryMatch
  var captureIndex: uint32

  while ts_query_cursor_next_capture(cursor, addr match, addr captureIndex):
    let capture = match.captures[captureIndex]
    let startPt = ts_node_start_point(capture.node)
    let endPt = ts_node_end_point(capture.node)

    # Get capture name
    var nameLen: uint32
    let namePtr = ts_query_capture_name_for_id(
      tsState.query, capture.index, addr nameLen)
    if namePtr == nil:
      continue
    let captureName = $namePtr

    let color = captureColor(captureName)
    if color == 0:
      continue

    let startLine = int(startPt.row)
    let endLine = int(endPt.row)

    if startLine == endLine:
      # Single-line token
      if startLine < lineCount:
        let length = int(endPt.column) - int(startPt.column)
        if length > 0:
          result[startLine].add(TsToken(
            col: int(startPt.column),
            length: length,
            color: color,
          ))
    else:
      # Multi-line token (e.g. multi-line string, block comment)
      # First line: from startCol to a large length (end of line)
      if startLine < lineCount:
        result[startLine].add(TsToken(
          col: int(startPt.column),
          length: 10000,  # effectively to end of line
          color: color,
        ))
      # Middle lines: entire line
      for midLine in (startLine + 1)..<endLine:
        if midLine < lineCount:
          result[midLine].add(TsToken(col: 0, length: 10000, color: color))
      # Last line: from 0 to endCol
      if endLine < lineCount and int(endPt.column) > 0:
        result[endLine].add(TsToken(
          col: 0,
          length: int(endPt.column),
          color: color,
        ))

  ts_query_cursor_delete(cursor)

  # Store results
  tsLines = result

proc tryTsHighlight*(filePath: string, text: string, lineCount: int) =
  ## Try to highlight a file using tree-sitter (if grammar is available)
  let lang = findLanguageForFile(filePath)
  if lang.len == 0:
    clearTsHighlight()
    return
  # Load grammar if needed
  if tsState.langName != lang or not tsState.active:
    if not loadGrammar(lang):
      clearTsHighlight()
      return
  tsParseAndHighlight(text, lineCount)
