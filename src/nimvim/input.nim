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

  InputResult* = object
    complete*: bool
    action*: ActionKind

const validPrefixes = ["g", "d", "y"]

proc isValidPrefix(s: string): bool =
  for p in validPrefixes:
    if p.startsWith(s) or s == p:
      return true
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
    if not isValidPrefix(pending):
      pending = ""
      return InputResult(complete: false, action: akNone)
