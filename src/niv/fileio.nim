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
      lines*: seq[string]
      bytesRead*: int64
    of fckDone:
      discard

  ParserArgs = object
    bufPtr: ptr UncheckedArray[byte]
    startPos: int
    endPos: int   ## exclusive
    chanIdx: int

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
      # Single-thread parse of the full buffer
      var lines: seq[string] = @[]
      var pos = 0
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
        lines.add(line)
        pos = nlPos + 1
      # Handle case where buffer doesn't end with \n (last line without newline)
      if actualBufLen > 0 and buf[actualBufLen - 1] != byte('\n'):
        discard  # already handled by the loop above
      dealloc(buf)

      # Send lines in batches
      var i = 0
      while i < lines.len:
        if fileLoaderCancel.load():
          fileLoaderChannel.send(FileChunk(kind: fckDone))
          return
        let batchEnd = min(i + BatchSize, lines.len)
        let bytesForBatch = if i == 0: totalBytesRead else: 0'i64
        fileLoaderChannel.send(FileChunk(kind: fckLines,
          lines: lines[i..<batchEnd], bytesRead: bytesForBatch))
        i = batchEnd
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

    # Collect results in order and send to main thread
    for t in 0..<threadCount:
      let (hasData, sectionLines) = parseResultChannels[t].tryRecv()
      if hasData and sectionLines.len > 0:
        # Send in batches
        var i = 0
        while i < sectionLines.len:
          if fileLoaderCancel.load():
            # Drain remaining channels
            for t2 in t+1..<threadCount:
              discard parseResultChannels[t2].tryRecv()
            for tt in 0..<threadCount:
              parseResultChannels[tt].close()
            dealloc(buf)
            fileLoaderChannel.send(FileChunk(kind: fckDone))
            return
          let batchEnd = min(i + BatchSize, sectionLines.len)
          let bytesForBatch = if t == 0 and i == 0: totalBytesRead else: 0'i64
          fileLoaderChannel.send(FileChunk(kind: fckLines,
            lines: sectionLines[i..<batchEnd], bytesRead: bytesForBatch))
          i = batchEnd
      parseResultChannels[t].close()

    dealloc(buf)
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
          fileLoaderChannel.send(FileChunk(kind: fckLines, lines: @[carry], bytesRead: 0))
        fileLoaderChannel.send(FileChunk(kind: fckDone))
        break

      buf.setLen(n)
      let lines = parseChunkLines(buf, carry)
      buf.setLen(ChunkSize)

      if lines.len > 0:
        fileLoaderChannel.send(FileChunk(kind: fckLines, lines: lines, bytesRead: int64(n)))
      else:
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

proc stopFileLoader*() =
  ## Signal the background file loader to stop and drain the channel.
  if not fileLoaderActive:
    return
  fileLoaderCancel.store(true)
  while true:
    let (hasData, chunk) = fileLoaderChannel.tryRecv()
    if hasData and chunk.kind == fckDone:
      break
    elif not hasData:
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
