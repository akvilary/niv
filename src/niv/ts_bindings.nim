## Tree-sitter C library FFI bindings
## tree-sitter v0.26.6 compiled from source via {.compile.} pragma

import std/os

const projectRoot = currentSourcePath().parentDir().parentDir().parentDir()
const tsDir = projectRoot / "deps" / "tree-sitter-0.26.6"

{.passC: "-I" & tsDir / "lib" / "include" & " -I" & tsDir / "lib" / "src".}
{.compile(tsDir / "lib" / "src" / "lib.c", "-UTREE_SITTER_FEATURE_WASM").}

type
  TSLanguage* {.importc: "TSLanguage", header: "tree_sitter/api.h", incompleteStruct.} = object
  TSParser* {.importc: "TSParser", header: "tree_sitter/api.h", incompleteStruct.} = object
  TSTree* {.importc: "TSTree", header: "tree_sitter/api.h", incompleteStruct.} = object
  TSQuery* {.importc: "TSQuery", header: "tree_sitter/api.h", incompleteStruct.} = object
  TSQueryCursor* {.importc: "TSQueryCursor", header: "tree_sitter/api.h", incompleteStruct.} = object

  TSPoint* {.importc: "TSPoint", header: "tree_sitter/api.h", bycopy.} = object
    row* {.importc: "row".}: uint32
    column* {.importc: "column".}: uint32

  TSNode* {.importc: "TSNode", header: "tree_sitter/api.h", bycopy.} = object
    context* {.importc: "context".}: array[4, uint32]
    id* {.importc: "id".}: pointer
    tree* {.importc: "tree".}: ptr TSTree

  TSQueryCapture* {.importc: "TSQueryCapture", header: "tree_sitter/api.h", bycopy.} = object
    node* {.importc: "node".}: TSNode
    index* {.importc: "index".}: uint32

  TSQueryMatch* {.importc: "TSQueryMatch", header: "tree_sitter/api.h", bycopy.} = object
    id* {.importc: "id".}: uint32
    patternIndex* {.importc: "pattern_index".}: uint16
    captureCount* {.importc: "capture_count".}: uint16
    captures* {.importc: "captures".}: ptr UncheckedArray[TSQueryCapture]

  TSQueryError* {.importc: "TSQueryError", header: "tree_sitter/api.h", size: sizeof(cint).} = enum
    tsqeNone = 0
    tsqeSyntax = 1
    tsqeNodeType = 2
    tsqeField = 3
    tsqeCapture = 4
    tsqeStructure = 5
    tsqeLanguage = 6

  TSLanguageFunc* = proc(): ptr TSLanguage {.cdecl.}

# Parser
proc ts_parser_new*(): ptr TSParser {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_parser_delete*(self: ptr TSParser) {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_parser_set_language*(self: ptr TSParser, language: ptr TSLanguage): bool {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_parser_parse_string*(self: ptr TSParser, oldTree: ptr TSTree,
                              str: cstring, length: uint32): ptr TSTree {.importc, header: "tree_sitter/api.h", cdecl.}

# Tree
proc ts_tree_root_node*(self: ptr TSTree): TSNode {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_tree_delete*(self: ptr TSTree) {.importc, header: "tree_sitter/api.h", cdecl.}

# Node
proc ts_node_start_point*(self: TSNode): TSPoint {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_node_end_point*(self: TSNode): TSPoint {.importc, header: "tree_sitter/api.h", cdecl.}

# Query
proc ts_query_new*(language: ptr TSLanguage, source: cstring,
                   sourceLen: uint32, errorOffset: ptr uint32,
                   errorType: ptr TSQueryError): ptr TSQuery {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_query_delete*(self: ptr TSQuery) {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_query_capture_name_for_id*(self: ptr TSQuery, index: uint32,
                                    length: ptr uint32): cstring {.importc, header: "tree_sitter/api.h", cdecl.}

# Query predicates
type
  TSQueryPredicateStepType* = enum
    tsqpstDone = 0
    tsqpstCapture = 1
    tsqpstString = 2

  TSQueryPredicateStep* {.importc: "TSQueryPredicateStep", header: "tree_sitter/api.h", bycopy.} = object
    theType* {.importc: "type".}: TSQueryPredicateStepType
    valueId* {.importc: "value_id".}: uint32

proc ts_query_predicates_for_pattern*(self: ptr TSQuery, patternIndex: uint32,
                                       stepCount: ptr uint32): ptr UncheckedArray[TSQueryPredicateStep] {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_query_string_value_for_id*(self: ptr TSQuery, id: uint32,
                                    length: ptr uint32): cstring {.importc, header: "tree_sitter/api.h", cdecl.}

# Node byte positions (for extracting text)
proc ts_node_start_byte*(self: TSNode): uint32 {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_node_end_byte*(self: TSNode): uint32 {.importc, header: "tree_sitter/api.h", cdecl.}

# Query Cursor
proc ts_query_cursor_new*(): ptr TSQueryCursor {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_query_cursor_delete*(self: ptr TSQueryCursor) {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_query_cursor_exec*(self: ptr TSQueryCursor, query: ptr TSQuery,
                            node: TSNode) {.importc, header: "tree_sitter/api.h", cdecl.}
proc ts_query_cursor_next_capture*(self: ptr TSQueryCursor, match: ptr TSQueryMatch,
                                    captureIndex: ptr uint32): bool {.importc, header: "tree_sitter/api.h", cdecl.}
