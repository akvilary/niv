## Unicode display width utilities

import std/unicode

proc displayWidth*(s: string, startByte, endByte: int): int =
  ## Count display columns for s[startByte..<endByte]
  ## Each rune = 1 column (correct for Latin, Cyrillic, etc.)
  var i = startByte
  let e = min(endByte, s.len)
  while i < e:
    let rl = runeLenAt(s, i)
    result += 1
    i += rl

proc displayWidth*(s: string): int =
  ## Count display columns for the entire string
  displayWidth(s, 0, s.len)

proc byteOffsetForWidth*(s: string, startByte: int, maxCols: int): int =
  ## Starting at startByte, advance up to maxCols display columns.
  ## Returns the byte offset right after the last complete rune that fits.
  var cols = 0
  var i = startByte
  while i < s.len and cols < maxCols:
    let rl = runeLenAt(s, i)
    cols += 1
    i += rl
  result = i

proc displayColAt*(s: string, startByte, targetByte: int): int =
  ## Count display columns from startByte up to (not including) targetByte
  var i = startByte
  let target = min(targetByte, s.len)
  while i < target:
    let rl = runeLenAt(s, i)
    result += 1
    i += rl

proc byteOffsetBackward*(s: string, fromByte: int, cols: int): int =
  ## Walk backward from fromByte by cols display columns.
  ## Returns the byte offset of the rune that is cols columns before fromByte.
  var remaining = cols
  var i = min(fromByte, s.len)
  while remaining > 0 and i > 0:
    dec i
    # Skip UTF-8 continuation bytes (10xxxxxx)
    while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
      dec i
    dec remaining
  result = i
