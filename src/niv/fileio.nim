## File I/O operations

import std/[os, strutils, posix, atomics]

const
  ChunkSize* = 65536  ## 64KB per chunk

type
  FileChunkKind* = enum
    fckLines      ## Batch of parsed lines
    fckDone       ## File fully loaded

  FileChunk* = object
    case kind*: FileChunkKind
    of fckLines:
      lines*: seq[string]
      bytesRead*: int64
    of fckDone:
      discard

var fileLoaderChannel*: Channel[FileChunk]
var fileLoaderThread: Thread[tuple[path: string, startOffset: int64, initialCarry: string]]
var fileLoaderPaused*: Atomic[bool]
var fileLoaderActive*: bool = false

proc parseChunkLines(buf: string, carry: var string): seq[string] =
  ## Parse a raw chunk into lines, handling partial lines via carry.
  ## The last incomplete line (no trailing newline) stays in carry.
  result = @[]
  var startPos = 0

  # Prepend carry from previous chunk
  if carry.len > 0:
    let nlPos = buf.find('\n')
    if nlPos == -1:
      # Entire chunk is part of the carried line
      carry.add(buf)
      return
    # Complete the carried line
    var line = carry & buf[0..<nlPos]
    if line.len > 0 and line[^1] == '\r':
      line.setLen(line.len - 1)
    result.add(line)
    carry = ""
    startPos = nlPos + 1

  # Parse remaining lines in chunk
  var pos = startPos
  while pos < buf.len:
    let nlPos = buf.find('\n', pos)
    if nlPos == -1:
      # No more newlines — remainder is carry for next chunk
      carry = buf[pos..^1]
      return
    var line = buf[pos..<nlPos]
    if line.len > 0 and line[^1] == '\r':
      line.setLen(line.len - 1)
    result.add(line)
    pos = nlPos + 1

proc fileLoaderWorker(args: tuple[path: string, startOffset: int64, initialCarry: string]) {.thread.} =
  let fd = posix.open(cstring(args.path), O_RDONLY)
  if fd < 0:
    fileLoaderChannel.send(FileChunk(kind: fckDone))
    return

  # Seek to start offset
  if args.startOffset > 0:
    discard posix.lseek(fd, Off(args.startOffset), SEEK_SET)

  var buf = newString(ChunkSize)
  var carry = args.initialCarry

  while true:
    # Check pause flag
    while fileLoaderPaused.load():
      os.sleep(10)

    let n = posix.read(fd, addr buf[0], ChunkSize)
    if n <= 0:
      # EOF or error — flush carry
      if carry.len > 0:
        fileLoaderChannel.send(FileChunk(kind: fckLines, lines: @[carry], bytesRead: 0))
      fileLoaderChannel.send(FileChunk(kind: fckDone))
      break

    buf.setLen(n)
    let lines = parseChunkLines(buf, carry)
    buf.setLen(ChunkSize)

    if lines.len > 0:
      fileLoaderChannel.send(FileChunk(kind: fckLines, lines: lines, bytesRead: int64(n)))
    else:
      # Only carry accumulated, still count bytes
      fileLoaderChannel.send(FileChunk(kind: fckLines, lines: @[], bytesRead: int64(n)))

  discard posix.close(fd)

proc loadFileFirstChunk*(filePath: string): tuple[lines: seq[string], bytesRead: int64, totalSize: int64, done: bool, carry: string] =
  ## Load the first chunk of a file synchronously. Returns the lines,
  ## bytes read, total file size, whether the whole file was loaded, and
  ## any carry (partial line at end) for the background loader.
  if filePath.len == 0 or not fileExists(filePath):
    return (lines: @[""], bytesRead: 0'i64, totalSize: 0'i64, done: true, carry: "")

  let totalSize = getFileSize(filePath)
  if totalSize == 0:
    return (lines: @[""], bytesRead: 0'i64, totalSize: 0'i64, done: true, carry: "")

  let fd = posix.open(cstring(filePath), O_RDONLY)
  if fd < 0:
    return (lines: @[""], bytesRead: 0'i64, totalSize: totalSize, done: true, carry: "")

  var buf = newString(ChunkSize)
  let n = posix.read(fd, addr buf[0], ChunkSize)
  discard posix.close(fd)

  if n <= 0:
    return (lines: @[""], bytesRead: 0'i64, totalSize: totalSize, done: true, carry: "")

  buf.setLen(n)

  var lines: seq[string] = @[]
  var carry = ""
  lines = parseChunkLines(buf, carry)

  let done = int64(n) >= totalSize

  if done:
    # File fully loaded — include carry as last line
    if carry.len > 0:
      lines.add(carry)
      carry = ""
    # Remove trailing empty line if file ends with newline
    if lines.len > 1 and lines[^1].len == 0:
      lines.setLen(lines.len - 1)

  if lines.len == 0:
    lines = @[""]

  return (lines: lines, bytesRead: int64(n), totalSize: totalSize, done: done, carry: carry)

proc startFileLoader*(filePath: string, startOffset: int64, carry: string) =
  ## Start the background file loader thread from given offset with initial carry
  fileLoaderChannel.open()
  fileLoaderPaused.store(false)
  fileLoaderActive = true
  createThread(fileLoaderThread, fileLoaderWorker, (path: filePath, startOffset: startOffset, initialCarry: carry))

proc pollFileLoader*(): (bool, FileChunk) =
  ## Non-blocking poll for file loader chunks
  if not fileLoaderActive:
    return (false, FileChunk(kind: fckDone))
  let (hasData, chunk) = fileLoaderChannel.tryRecv()
  if hasData and chunk.kind == fckDone:
    fileLoaderActive = false
  return (hasData, chunk)

proc pauseFileLoader*() =
  fileLoaderPaused.store(true)

proc resumeFileLoader*() =
  fileLoaderPaused.store(false)

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
