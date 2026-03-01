## Command-line mode handler

import std/strutils
import types
import buffer
import commands

proc performSearch(state: var EditorState) =
  let query = state.commandLine
  if query.len == 0:
    state.searchInput = false
    state.mode = mNormal
    state.commandLine = ""
    return

  state.searchQuery = query
  state.searchMatches = @[]

  # Find all matches in the buffer (case-insensitive)
  let queryLower = query.toLowerAscii()
  for lineIdx in 0..<state.buffer.lineCount:
    let line = state.buffer.getLine(lineIdx)
    let lineLower = line.toLowerAscii()
    var pos = 0
    while pos < lineLower.len:
      let found = lineLower.find(queryLower, pos)
      if found < 0:
        break
      state.searchMatches.add(SearchMatch(line: lineIdx, col: found))
      pos = found + 1

  if state.searchMatches.len == 0:
    state.statusMessage = "Pattern not found: " & query
    state.searchIndex = 0
  else:
    # Jump to first match at or after cursor
    state.searchIndex = 0
    for i, m in state.searchMatches:
      if m.line > state.cursor.line or
         (m.line == state.cursor.line and m.col >= state.cursor.col):
        state.searchIndex = i
        break
    let m = state.searchMatches[state.searchIndex]
    state.cursor = Position(line: m.line, col: m.col)
    state.statusMessage = $(state.searchIndex + 1) & "/" & $state.searchMatches.len

  state.searchInput = false
  state.mode = mNormal
  state.commandLine = ""

proc handleCommandMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    if state.searchInput:
      state.searchQuery = ""
      state.searchMatches = @[]
      state.searchIndex = 0
      state.searchInput = false
    state.mode = mNormal
    state.commandLine = ""

  of kkEnter:
    if state.searchInput:
      performSearch(state)
    else:
      let (cmd, arg) = parseCommand(state.commandLine)
      executeCommand(state, cmd, arg)
      if state.mode == mCommand:
        state.mode = mNormal
      state.commandLine = ""

  of kkBackspace:
    if state.commandLine.len > 0:
      state.commandLine.setLen(state.commandLine.len - 1)
    else:
      if state.searchInput:
        state.searchQuery = ""
        state.searchMatches = @[]
        state.searchIndex = 0
        state.searchInput = false
      state.mode = mNormal

  of kkChar:
    state.commandLine.add(key.ch)

  else:
    discard
