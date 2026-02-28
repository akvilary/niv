## File I/O operations

import std/[os, strutils, posix, atomics, cpuinfo]

const
  ChunkSize* = 65536  ## 64KB per chunk
  MaxParseThreads = 4
  BatchSize = 50000   ## lines per batch when sending to main thread
  ParallelThreshold = 1_048_576  ## 1MB - use parallel parsing above this

type
  FileChunkKind* = enum
    fckLines      ## Batch of parsed lines
    fckDone       ## File fully loaded

  FileChunk* = object
    case kind*: FileChunkKind
    of fckLines:
      lines*: ptr seq[string]
      bytesRead*: int64
    of fckDone:
      discard

  ParserArgs = object
    bufPtr: ptr UncheckedArray[byte]
    startPos: int
    endPos: int   ## exclusive
    chanIdx: int

proc newFileChunkLines*(lines: sink seq[string], bytesRead: int64): FileChunk =
  ## Allocate lines on the shared heap and wrap in FileChunk.
  let p = createShared(seq[string])
  p[] = move lines
  FileChunk(kind: fckLines, lines: p, bytesRead: bytesRead)

proc freeFileChunkLines*(chunk: FileChunk) =
  ## Free lines allocated by newFileChunkLines.
  if chunk.kind == fckLines and chunk.lines != nil:
    reset(chunk.lines[])
    deallocShared(chunk.lines)

var fileLoaderChannel*: Channel[FileChunk]
var fileLoaderThread: Thread[tuple[path: string, startOffset: int64, initialCarry: string, remainingSize: int64]]
var fileLoaderPaused*: Atomic[bool]
var fileLoaderCancel*: Atomic[bool]
var fileLoaderActive*: bool = false

var parseResultChannels: array[MaxParseThreads, Channel[seq[string]]]
var parseThreads: array[MaxParseThreads, Thread[ParserArgs]]

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

# ---------------------------------------------------------------------------
# Parallel parsing helpers
# ---------------------------------------------------------------------------

proc findSectionBoundaries(buf: ptr UncheckedArray[byte], bufLen: int,
                            threadCount: int): seq[int] =
  ## Divide buffer into threadCount sections at newline boundaries.
  ## Returns [0, boundary1, ..., bufLen] where each boundary is the position
  ## after a \n (start of next line).
  result = @[0]
  let sectionSize = bufLen div threadCount
  for i in 1..<threadCount:
    var pos = i * sectionSize
    # Find nearest \n forward
    while pos < bufLen and buf[pos] != byte('\n'):
      inc pos
    if pos < bufLen:
      inc pos  # skip the \n itself
    result.add(pos)
  result.add(bufLen)

proc parserWorker(args: ParserArgs) {.thread.} =
  ## Parse a section of the buffer [startPos, endPos) into seq[string].
  ## Works with ptr UncheckedArray[byte] — no GC dependencies on shared data.
  var lines: seq[string] = @[]
  var pos = args.startPos
  while pos < args.endPos:
    # Find next \n
    var nlPos = pos
    while nlPos < args.endPos and args.bufPtr[nlPos] != byte('\n'):
      inc nlPos
    # Calculate line length, handle \r\n
    var lineLen = nlPos - pos
    if lineLen > 0 and args.bufPtr[pos + lineLen - 1] == byte('\r'):
      dec lineLen
    # Create string from bytes
    var line = newString(lineLen)
    if lineLen > 0:
      copyMem(addr line[0], addr args.bufPtr[pos], lineLen)
    lines.add(line)
    pos = nlPos + 1
  parseResultChannels[args.chanIdx].send(lines)

# ---------------------------------------------------------------------------
# File loader worker thread
# ---------------------------------------------------------------------------

proc fileLoaderWorker(args: tuple[path: string, startOffset: int64, initialCarry: string, remainingSize: int64]) {.thread.} =
  let fd = posix.open(cstring(args.path), O_RDONLY)
  if fd < 0:
    fileLoaderChannel.send(FileChunk(kind: fckDone))
    return

  # Seek to start offset
  if args.startOffset > 0:
    discard posix.lseek(fd, Off(args.startOffset), SEEK_SET)

  # Decide: parallel or sequential based on remaining size
  if args.remainingSize >= ParallelThreshold:
    # --- Parallel path: read entire remaining file, then parse in parallel ---
    let totalRemaining = int(args.remainingSize)
    let carryLen = args.initialCarry.len
    let bufLen = carryLen + totalRemaining
    let buf = cast[ptr UncheckedArray[byte]](alloc(bufLen))

    # Copy carry into buffer start
    if carryLen > 0:
      copyMem(addr buf[0], unsafeAddr args.initialCarry[0], carryLen)

    # Read entire remaining file
    var offset = carryLen
    var totalBytesRead: int64 = 0
    while offset < bufLen:
      if fileLoaderCancel.load():
        dealloc(buf)
        discard posix.close(fd)
        fileLoaderChannel.send(FileChunk(kind: fckDone))
        return
      let toRead = min(bufLen - offset, 4 * 1024 * 1024)  # read in 4MB chunks
      let n = posix.read(fd, addr buf[offset], toRead)
      if n <= 0:
        break
      offset += int(n)
      totalBytesRead += int64(n)
    discard posix.close(fd)

    let actualBufLen = offset  # actual bytes in buffer

    if fileLoaderCancel.load():
      dealloc(buf)
      fileLoaderChannel.send(FileChunk(kind: fckDone))
      return

    # Determine thread count
    let threadCount = min(countProcessors(), MaxParseThreads)

    if threadCount <= 1 or actualBufLen < ParallelThreshold:
      # Single-thread parse, sending lines in batches
      var batch: seq[string] = @[]
      var pos = 0
      var bytesSent = false
      while pos < actualBufLen:
        var nlPos = pos
        while nlPos < actualBufLen and buf[nlPos] != byte('\n'):
          inc nlPos
        var lineLen = nlPos - pos
        if lineLen > 0 and buf[pos + lineLen - 1] == byte('\r'):
          dec lineLen
        var line = newString(lineLen)
        if lineLen > 0:
          copyMem(addr line[0], addr buf[pos], lineLen)
        batch.add(line)
        pos = nlPos + 1
        if batch.len >= BatchSize:
          if fileLoaderCancel.load():
            dealloc(buf)
            fileLoaderChannel.send(FileChunk(kind: fckDone))
            return
          let bytes = if not bytesSent: totalBytesRead else: 0'i64
          bytesSent = true
          fileLoaderChannel.send(newFileChunkLines(move batch, bytes))
          batch = @[]
      dealloc(buf)
      if batch.len > 0:
        fileLoaderChannel.send(newFileChunkLines(move batch,
          if not bytesSent: totalBytesRead else: 0'i64))
      fileLoaderChannel.send(FileChunk(kind: fckDone))
      return

    # --- Multi-threaded parse ---
    let boundaries = findSectionBoundaries(buf, actualBufLen, threadCount)

    # Open channels and spawn parser threads
    for t in 0..<threadCount:
      parseResultChannels[t].open()
      createThread(parseThreads[t], parserWorker, ParserArgs(
        bufPtr: buf,
        startPos: boundaries[t],
        endPos: boundaries[t + 1],
        chanIdx: t
      ))

    # Wait for all threads to finish
    for t in 0..<threadCount:
      joinThread(parseThreads[t])

    # Collect results from all threads and send in batches
    dealloc(buf)
    var bytesSent = false
    for t in 0..<threadCount:
      var recvResult = parseResultChannels[t].tryRecv()
      if recvResult[0] and recvResult[1].len > 0:
        var sent = 0
        while sent < recvResult[1].len:
          if fileLoaderCancel.load():
            for t2 in (t+1)..<threadCount:
              discard parseResultChannels[t2].tryRecv()
              parseResultChannels[t2].close()
            fileLoaderChannel.send(FileChunk(kind: fckDone))
            return
          let batchEnd = min(sent + BatchSize, recvResult[1].len)
          var batch = newSeq[string](batchEnd - sent)
          for i in 0..<batch.len:
            batch[i] = move recvResult[1][sent + i]
          let bytes = if not bytesSent: totalBytesRead else: 0'i64
          bytesSent = true
          fileLoaderChannel.send(newFileChunkLines(move batch, bytes))
          sent = batchEnd
      parseResultChannels[t].close()
    fileLoaderChannel.send(FileChunk(kind: fckDone))

  else:
    # --- Sequential path for small files (< 1MB remaining) ---
    var buf = newString(ChunkSize)
    var carry = args.initialCarry

    while true:
      if fileLoaderCancel.load():
        fileLoaderChannel.send(FileChunk(kind: fckDone))
        discard posix.close(fd)
        return
      while fileLoaderPaused.load():
        if fileLoaderCancel.load():
          fileLoaderChannel.send(FileChunk(kind: fckDone))
          discard posix.close(fd)
          return
        os.sleep(10)

      let n = posix.read(fd, addr buf[0], ChunkSize)
      if n <= 0:
        if carry.len > 0:
          fileLoaderChannel.send(newFileChunkLines(@[carry], 0))
        fileLoaderChannel.send(FileChunk(kind: fckDone))
        break

      buf.setLen(n)
      let lines = parseChunkLines(buf, carry)
      buf.setLen(ChunkSize)

      if lines.len > 0:
        fileLoaderChannel.send(newFileChunkLines(lines, int64(n)))
      else:
        fileLoaderChannel.send(newFileChunkLines(@[], int64(n)))

    discard posix.close(fd)

proc detectEncoding*(data: openArray[char]): string =
  ## Detect file encoding from raw bytes. Checks BOM first, then validates UTF-8.
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

proc loadFileFirstChunk*(filePath: string): tuple[lines: seq[string], bytesRead: int64, totalSize: int64, done: bool, carry: string, encoding: string] =
  ## Load the first chunk of a file synchronously. Returns the lines,
  ## bytes read, total file size, whether the whole file was loaded,
  ## carry (partial line at end) for the background loader, and detected encoding.
  if filePath.len == 0 or not fileExists(filePath):
    return (lines: @[""], bytesRead: 0'i64, totalSize: 0'i64, done: true, carry: "", encoding: "UTF-8")

  let totalSize = getFileSize(filePath)
  if totalSize == 0:
    return (lines: @[""], bytesRead: 0'i64, totalSize: 0'i64, done: true, carry: "", encoding: "UTF-8")

  let fd = posix.open(cstring(filePath), O_RDONLY)
  if fd < 0:
    return (lines: @[""], bytesRead: 0'i64, totalSize: totalSize, done: true, carry: "", encoding: "UTF-8")

  var buf = newString(ChunkSize)
  let n = posix.read(fd, addr buf[0], ChunkSize)
  discard posix.close(fd)

  if n <= 0:
    return (lines: @[""], bytesRead: 0'i64, totalSize: totalSize, done: true, carry: "", encoding: "UTF-8")

  buf.setLen(n)

  let encoding = detectEncoding(buf)

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

  return (lines: lines, bytesRead: int64(n), totalSize: totalSize, done: done, carry: carry, encoding: encoding)

proc stopFileLoader*() =
  ## Signal the background file loader to stop and drain the channel.
  if not fileLoaderActive:
    return
  fileLoaderCancel.store(true)
  while true:
    let (hasData, chunk) = fileLoaderChannel.tryRecv()
    if hasData:
      freeFileChunkLines(chunk)
      if chunk.kind == fckDone:
        break
    else:
      os.sleep(1)
  fileLoaderActive = false
  fileLoaderCancel.store(false)

proc startFileLoader*(filePath: string, startOffset: int64, carry: string) =
  ## Start the background file loader thread from given offset with initial carry
  fileLoaderChannel.open()
  fileLoaderPaused.store(false)
  fileLoaderCancel.store(false)
  fileLoaderActive = true
  let totalSize = getFileSize(filePath)
  let remainingSize = totalSize - startOffset
  createThread(fileLoaderThread, fileLoaderWorker,
    (path: filePath, startOffset: startOffset, initialCarry: carry, remainingSize: remainingSize))

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

proc saveFile*(filePath: string, lines: seq[string]) =
  var content = ""
  for i, line in lines:
    content.add(line)
    if i < lines.len - 1:
      content.add('\n')
  content.add('\n')  # trailing newline
  writeFile(filePath, content)
