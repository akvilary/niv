## Jump list for go-back navigation

import types

type
  JumpLocation* = object
    filePath*: string
    cursor*: Position
    topLine*: int

const MaxJumpStack = 50

var jumpStack*: seq[JumpLocation]

proc pushJump*(filePath: string, cursor: Position, topLine: int) =
  if jumpStack.len >= MaxJumpStack:
    jumpStack.delete(0)
  jumpStack.add(JumpLocation(filePath: filePath, cursor: cursor, topLine: topLine))

proc popJump*(): (bool, JumpLocation) =
  if jumpStack.len == 0:
    return (false, JumpLocation())
  result = (true, jumpStack[^1])
  jumpStack.setLen(jumpStack.len - 1)
