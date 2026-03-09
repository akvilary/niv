## File I/O operations — raw byte streaming

import std/[os, strutils, posix, atomics]

const
  ChunkSize* = 65536  ## 64KB per read
  LoadChunkSize = 4 * 1024 * 1024  ## 4MB per send batch

type
  FileChunkKind* = enum
    fckData       ## Raw bytes
    fckDone       ## File fully loaded

  FileChunk* = object
    case kind*: FileChunkKind
    of fckData:
      dataPtr*: ptr string
      bytesRead*: int64
    of fckDone:
      discard

proc newFileChunkData*(data: sink string, bytesRead: int64): FileChunk =
  let p = createShared(string)
  p[] = move data
  FileChunk(kind: fckData, dataPtr: p, bytesRead: bytesRead)

proc freeFileChunkData*(chunk: FileChunk) =
  if chunk.kind == fckData and chunk.dataPtr != nil:
    reset(chunk.dataPtr[])
    deallocShared(chunk.dataPtr)

var fileLoaderChannel*: Channel[FileChunk]
var fileLoaderThread: Thread[tuple[path: string, startOffset: int64, remainingSize: int64]]
var fileLoaderPaused*: Atomic[bool]
var fileLoaderCancel*: Atomic[bool]
var fileLoaderActive*: bool = false

# ---------------------------------------------------------------------------
# File loader worker thread — reads raw bytes, no parsing
# ---------------------------------------------------------------------------

proc fileLoaderWorker(args: tuple[path: string, startOffset: int64, remainingSize: int64]) {.thread.} =
  let fd = posix.open(cstring(args.path), O_RDONLY)
  if fd < 0:
    fileLoaderChannel.send(FileChunk(kind: fckDone))
    return

  if args.startOffset > 0:
    discard posix.lseek(fd, Off(args.startOffset), SEEK_SET)

  var buf = newString(LoadChunkSize)
  var totalRead: int64 = 0

  while totalRead < args.remainingSize:
    if fileLoaderCancel.load():
      discard posix.close(fd)
      fileLoaderChannel.send(FileChunk(kind: fckDone))
      return

    while fileLoaderPaused.load():
      if fileLoaderCancel.load():
        discard posix.close(fd)
        fileLoaderChannel.send(FileChunk(kind: fckDone))
        return
      os.sleep(10)

    let toRead = min(LoadChunkSize, int(args.remainingSize - totalRead))
    var offset = 0
    while offset < toRead:
      let n = posix.read(fd, addr buf[offset], toRead - offset)
      if n <= 0:
        break
      offset += int(n)

    if offset == 0:
      break

    buf.setLen(offset)
    totalRead += int64(offset)
    fileLoaderChannel.send(newFileChunkData(buf[0..<offset], int64(offset)))
    buf.setLen(LoadChunkSize)

  discard posix.close(fd)
  fileLoaderChannel.send(FileChunk(kind: fckDone))

# ---------------------------------------------------------------------------
# Encoding detection
# ---------------------------------------------------------------------------

proc detectEncoding*(data: openArray[char]): string =
  let n = data.len
  if n == 0: return "UTF-8"
  # BOM detection
  if n >= 3 and data[0] == '\xEF' and data[1] == '\xBB' and data[2] == '\xBF':
    return "UTF-8 BOM"
  if n >= 2:
    if data[0] == '\xFF' and data[1] == '\xFE':
      if n >= 4 and data[2] == '\x00' and data[3] == '\x00': return "UTF-32 LE"
      return "UTF-16 LE"
    if data[0] == '\xFE' and data[1] == '\xFF':
      return "UTF-16 BE"
    if n >= 4 and data[0] == '\x00' and data[1] == '\x00' and data[2] == '\xFE' and data[3] == '\xFF':
      return "UTF-32 BE"
  # UTF-8 validation
  var hasMultibyte = false
  var i = 0
  while i < n:
    let b = byte(data[i])
    if b < 0x80:
      inc i
    elif (b and 0xE0) == 0xC0:
      if i + 1 >= n or (byte(data[i+1]) and 0xC0) != 0x80: return "Latin-1"
      hasMultibyte = true; i += 2
    elif (b and 0xF0) == 0xE0:
      if i + 2 >= n or (byte(data[i+1]) and 0xC0) != 0x80 or (byte(data[i+2]) and 0xC0) != 0x80: return "Latin-1"
      hasMultibyte = true; i += 3
    elif (b and 0xF8) == 0xF0:
      if i + 3 >= n or (byte(data[i+1]) and 0xC0) != 0x80 or (byte(data[i+2]) and 0xC0) != 0x80 or (byte(data[i+3]) and 0xC0) != 0x80: return "Latin-1"
      hasMultibyte = true; i += 4
    else:
      return "Latin-1"
  if hasMultibyte: return "UTF-8"
  return "ASCII"

# ---------------------------------------------------------------------------
# First chunk loading (synchronous)
# ---------------------------------------------------------------------------

proc loadFileFirstChunk*(filePath: string): tuple[data: string, bytesRead: int64, totalSize: int64, done: bool, encoding: string] =
  if filePath.len == 0 or not fileExists(filePath):
    return (data: "", bytesRead: 0'i64, totalSize: 0'i64, done: true, encoding: "UTF-8")

  let totalSize = getFileSize(filePath)
  if totalSize == 0:
    return (data: "", bytesRead: 0'i64, totalSize: 0'i64, done: true, encoding: "UTF-8")

  let fd = posix.open(cstring(filePath), O_RDONLY)
  if fd < 0:
    return (data: "", bytesRead: 0'i64, totalSize: totalSize, done: true, encoding: "UTF-8")

  var buf = newString(ChunkSize)
  let n = posix.read(fd, addr buf[0], ChunkSize)
  discard posix.close(fd)

  if n <= 0:
    return (data: "", bytesRead: 0'i64, totalSize: totalSize, done: true, encoding: "UTF-8")

  buf.setLen(n)

  # Normalize \r\n to \n
  var data = buf.replace("\r\n", "\n")
  let encoding = detectEncoding(data)
  let done = int64(n) >= totalSize

  return (data: data, bytesRead: int64(n), totalSize: totalSize, done: done, encoding: encoding)

# ---------------------------------------------------------------------------
# File loader control
# ---------------------------------------------------------------------------

proc stopFileLoader*() =
  if not fileLoaderActive:
    return
  fileLoaderCancel.store(true)
  while true:
    let (hasData, chunk) = fileLoaderChannel.tryRecv()
    if hasData:
      freeFileChunkData(chunk)
      if chunk.kind == fckDone:
        break
    else:
      os.sleep(1)
  fileLoaderActive = false
  fileLoaderCancel.store(false)

proc startFileLoader*(filePath: string, startOffset: int64, remainingSize: int64) =
  fileLoaderChannel.open()
  fileLoaderPaused.store(false)
  fileLoaderCancel.store(false)
  fileLoaderActive = true
  createThread(fileLoaderThread, fileLoaderWorker,
    (path: filePath, startOffset: startOffset, remainingSize: remainingSize))

proc pollFileLoader*(): (bool, FileChunk) =
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

proc saveFile*(filePath: string, data: string) =
  var content = data
  # Ensure trailing newline
  if content.len == 0 or content[^1] != '\n':
    content.add('\n')
  writeFile(filePath, content)
