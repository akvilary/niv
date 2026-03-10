## Unicode display width utilities

import std/unicode

proc runeDisplayWidth*(r: Rune): int =
  ## Returns display width of a single rune (1 or 2 columns)
  let cp = r.int
  if (cp >= 0x1100 and cp <= 0x115F) or   # Hangul Jamo
     (cp >= 0x2E80 and cp <= 0x9FFF) or    # CJK Unified + Radicals
     (cp >= 0xAC00 and cp <= 0xD7AF) or    # Hangul Syllables
     (cp >= 0xF900 and cp <= 0xFAFF) or    # CJK Compatibility Ideographs
     (cp >= 0xFE10 and cp <= 0xFE6F) or    # CJK Forms + Small Forms
     (cp >= 0xFF01 and cp <= 0xFF60) or    # Fullwidth Forms
     (cp >= 0xFFE0 and cp <= 0xFFE6) or    # Fullwidth Signs
     (cp >= 0x1F000 and cp <= 0x1FFFF) or  # Emoji, Mahjong, Playing Cards
     (cp >= 0x20000 and cp <= 0x2FA1F):    # CJK Extension B+
    return 2
  return 1

proc displayWidth*(s: string, startByte, endByte: int): int =
  ## Count display columns for s[startByte..<endByte]
  var i = startByte
  let e = min(endByte, s.len)
  while i < e:
    let rl = runeLenAt(s, i)
    result += runeDisplayWidth(runeAt(s, i))
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
