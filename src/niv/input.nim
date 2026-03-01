## Multi-key sequence parsing for Normal mode

import std/strutils
import types

type
  ActionKind* = enum
    akNone
    akMoveLeft, akMoveRight, akMoveUp, akMoveDown
    akMoveWordForward, akMoveWordBackward, akMoveWordEnd
    akMoveLineStart, akMoveLineEnd
    akMoveToTop, akMoveToBottom
    akInsertBefore, akInsertAfter
    akInsertLineBelow, akInsertLineAbove
    akDeleteChar, akDeleteLine
    akYankLine, akPaste, akPasteBefore
    akUndo, akRedo
    akEnterCommand
    akPageUp, akPageDown
    akGotoDefinition
    akGoBack
    akGotoLine

  InputResult* = object
    complete*: bool
    action*: ActionKind
    count*: int

const validPrefixes = ["g", "d", "y"]

proc allDigits(s: string): bool =
  for c in s:
    if c notin {'0'..'9'}: return false
  return s.len > 0

proc isValidPrefix(s: string): bool =
  # Pure letter prefixes
  for p in validPrefixes:
    if p.startsWith(s) or s == p:
      return true
  # Numeric prefix: "123", "123g" (waiting for gg or G)
  if s.len >= 1:
    var i = 0
    while i < s.len and s[i] in {'0'..'9'}: inc i
    if i > 0 and i == s.len:
      return true  # just digits, waiting for action
    if i > 0 and i == s.len - 1 and s[i] == 'g':
      return true  # digits + "g", waiting for second g
  return false

proc processNormalKey*(pending: var string, key: InputKey): InputResult =
  result = InputResult(complete: false, action: akNone)

  case key.kind
  of kkArrowLeft:
    pending = ""
    return InputResult(complete: true, action: akMoveLeft)
  of kkArrowRight:
    pending = ""
    return InputResult(complete: true, action: akMoveRight)
  of kkArrowUp:
    pending = ""
    return InputResult(complete: true, action: akMoveUp)
  of kkArrowDown:
    pending = ""
    return InputResult(complete: true, action: akMoveDown)
  of kkPageUp:
    pending = ""
    return InputResult(complete: true, action: akPageUp)
  of kkPageDown:
    pending = ""
    return InputResult(complete: true, action: akPageDown)
  of kkHome:
    pending = ""
    return InputResult(complete: true, action: akMoveLineStart)
  of kkEnd:
    pending = ""
    return InputResult(complete: true, action: akMoveLineEnd)
  of kkCtrlKey:
    pending = ""
    case key.ctrl
    of 'r':
      return InputResult(complete: true, action: akRedo)
    else:
      return InputResult(complete: false, action: akNone)
  of kkChar:
    pending.add(key.ch)
  of kkDelete:
    pending = ""
    return InputResult(complete: true, action: akDeleteChar)
  else:
    pending = ""
    return

  # Match accumulated keys
  case pending
  of "h": pending = ""; return InputResult(complete: true, action: akMoveLeft)
  of "j": pending = ""; return InputResult(complete: true, action: akMoveDown)
  of "k": pending = ""; return InputResult(complete: true, action: akMoveUp)
  of "l": pending = ""; return InputResult(complete: true, action: akMoveRight)
  of "w": pending = ""; return InputResult(complete: true, action: akMoveWordForward)
  of "b": pending = ""; return InputResult(complete: true, action: akMoveWordBackward)
  of "e": pending = ""; return InputResult(complete: true, action: akMoveWordEnd)
  of "0": pending = ""; return InputResult(complete: true, action: akMoveLineStart)
  of "$": pending = ""; return InputResult(complete: true, action: akMoveLineEnd)
  of "gb": pending = ""; return InputResult(complete: true, action: akGoBack)
  of "gd": pending = ""; return InputResult(complete: true, action: akGotoDefinition)
  of "gg": pending = ""; return InputResult(complete: true, action: akMoveToTop)
  of "G": pending = ""; return InputResult(complete: true, action: akMoveToBottom)
  of "i": pending = ""; return InputResult(complete: true, action: akInsertBefore)
  of "a": pending = ""; return InputResult(complete: true, action: akInsertAfter)
  of "o": pending = ""; return InputResult(complete: true, action: akInsertLineBelow)
  of "O": pending = ""; return InputResult(complete: true, action: akInsertLineAbove)
  of "x": pending = ""; return InputResult(complete: true, action: akDeleteChar)
  of "dd": pending = ""; return InputResult(complete: true, action: akDeleteLine)
  of "yy": pending = ""; return InputResult(complete: true, action: akYankLine)
  of "p": pending = ""; return InputResult(complete: true, action: akPaste)
  of "P": pending = ""; return InputResult(complete: true, action: akPasteBefore)
  of "u": pending = ""; return InputResult(complete: true, action: akUndo)
  of ":": pending = ""; return InputResult(complete: true, action: akEnterCommand)
  else:
    # Check for <number>gg or <number>G
    if pending.len >= 2 and pending.endsWith("gg"):
      let numStr = pending[0..^3]
      if numStr.allDigits:
        let line = try: parseInt(numStr) except ValueError: 0
        pending = ""
        return InputResult(complete: true, action: akGotoLine, count: line)
    if pending.len >= 2 and pending[^1] == 'G':
      let numStr = pending[0..^2]
      if numStr.allDigits:
        let line = try: parseInt(numStr) except ValueError: 0
        pending = ""
        return InputResult(complete: true, action: akGotoLine, count: line)
    if not isValidPrefix(pending):
      pending = ""
      return InputResult(complete: false, action: akNone)
