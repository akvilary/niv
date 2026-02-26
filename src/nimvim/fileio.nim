## File I/O operations

import std/[os, strutils]

proc loadFile*(filePath: string): seq[string] =
  if filePath.len == 0 or not fileExists(filePath):
    return @[""]
  let content = readFile(filePath)
  if content.len == 0:
    return @[""]
  result = content.splitLines()
  # Remove trailing empty line if file ends with newline
  if result.len > 1 and result[^1].len == 0:
    result.setLen(result.len - 1)

proc saveFile*(filePath: string, lines: seq[string]) =
  var content = ""
  for i, line in lines:
    content.add(line)
    if i < lines.len - 1:
      content.add('\n')
  content.add('\n')  # trailing newline
  writeFile(filePath, content)
