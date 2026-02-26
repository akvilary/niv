## TreeSitter grammar manager (install/uninstall grammars)
## Grammars installed to ~/.config/niv/treesitter/<lang>/

import std/[osproc, os, strutils, posix]

const
  nivTsDir* = ".config" / "niv" / "treesitter"

type
  GrammarInfo* = object
    name*: string
    repo*: string          ## GitHub repo (e.g. "alaviss/tree-sitter-nim")
    branch*: string
    funcName*: string      ## C symbol name (e.g. "tree_sitter_nim")
    extensions*: seq[string]
    sourceFiles*: seq[string]  ## C files to compile (e.g. @["parser.c", "scanner.c"])
    installed*: bool

  TsManagerState* = object
    visible*: bool
    grammars*: seq[GrammarInfo]
    cursorIndex*: int
    scrollOffset*: int
    statusMessage*: string
    installing*: bool

var tsMgr*: TsManagerState
var tsInstallProc: Process
var tsInstallIdx: int = -1
var tsInstallIsUninstall: bool = false
var tsInstallOutputBuf: string = ""
var tsInstallOutputFd: cint = -1

proc tsBaseDir*(): string =
  getHomeDir() / nivTsDir

proc grammarDir*(lang: string): string =
  tsBaseDir() / lang

proc grammarSoPath*(lang: string): string =
  grammarDir(lang) / "parser.so"

proc grammarQueryPath*(lang: string): string =
  grammarDir(lang) / "highlights.scm"

proc ensureTsDirs*() =
  createDir(tsBaseDir())

proc checkGrammarInstalled(grammar: var GrammarInfo) =
  grammar.installed = fileExists(grammarSoPath(grammar.name))

proc initTsManager*() =
  ensureTsDirs()
  tsMgr.grammars = @[
    GrammarInfo(
      name: "nim",
      repo: "alaviss/tree-sitter-nim",
      branch: "main",
      funcName: "tree_sitter_nim",
      extensions: @[".nim", ".nims"],
      sourceFiles: @["parser.c", "scanner.c"],
    ),
    GrammarInfo(
      name: "python",
      repo: "tree-sitter/tree-sitter-python",
      branch: "master",
      funcName: "tree_sitter_python",
      extensions: @[".py"],
      sourceFiles: @["parser.c", "scanner.c"],
    ),
    GrammarInfo(
      name: "c",
      repo: "tree-sitter/tree-sitter-c",
      branch: "master",
      funcName: "tree_sitter_c",
      extensions: @[".c", ".h"],
      sourceFiles: @["parser.c"],
    ),
  ]
  for i in 0..<tsMgr.grammars.len:
    checkGrammarInstalled(tsMgr.grammars[i])

proc openTsManager*() =
  for i in 0..<tsMgr.grammars.len:
    checkGrammarInstalled(tsMgr.grammars[i])
  tsMgr.visible = true
  tsMgr.cursorIndex = 0
  tsMgr.scrollOffset = 0
  if not tsMgr.installing:
    tsMgr.statusMessage = ""

proc closeTsManager*() =
  tsMgr.visible = false
  if not tsMgr.installing:
    tsMgr.statusMessage = ""

proc tsManagerMoveUp*() =
  if tsMgr.cursorIndex > 0:
    dec tsMgr.cursorIndex

proc tsManagerMoveDown*() =
  if tsMgr.cursorIndex < tsMgr.grammars.len - 1:
    inc tsMgr.cursorIndex

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc lastMeaningfulLine(buf: string): string =
  let lines = buf.strip().splitLines()
  for i in countdown(lines.len - 1, 0):
    let line = lines[i].strip()
    if line.len > 0:
      return line
  return ""

proc drainTsOutput() =
  if tsInstallOutputFd < 0:
    return
  var chunk: array[4096, char]
  while true:
    let n = posix.read(tsInstallOutputFd, addr chunk[0], chunk.len)
    if n <= 0:
      break
    for i in 0..<n:
      tsInstallOutputBuf.add(chunk[i])

proc buildInstallCmd(g: GrammarInfo): string =
  let destDir = grammarDir(g.name)
  let tmpDir = "/tmp/niv-ts-" & g.name
  let tarUrl = "https://github.com/" & g.repo &
               "/archive/refs/heads/" & g.branch & ".tar.gz"
  let repoName = g.repo.split('/')[1]
  let extractDir = tmpDir / repoName & "-" & g.branch

  var srcFiles = ""
  for f in g.sourceFiles:
    srcFiles.add(extractDir / "src" / f & " ")

  result = "set -e && " &
    "rm -rf " & tmpDir & " && " &
    "mkdir -p " & tmpDir & " && " &
    "echo 'Downloading " & g.name & " grammar...' && " &
    "curl -sL " & tarUrl & " | tar xz -C " & tmpDir & " && " &
    "echo 'Compiling parser...' && " &
    "mkdir -p " & destDir & " && " &
    "cc -shared -fPIC -o " & destDir / "parser.so" & " " &
    srcFiles &
    "-I " & extractDir / "src" & " && " &
    "cp " & extractDir / "queries/highlights.scm" & " " &
    destDir / "highlights.scm" & " 2>/dev/null || true && " &
    "echo 'Cleaning up...' && " &
    "rm -rf " & tmpDir & " && " &
    "echo 'Done!'"

proc startGrammarInstall*() =
  if tsMgr.installing:
    tsMgr.statusMessage = "Already installing..."
    return
  if tsMgr.cursorIndex >= tsMgr.grammars.len:
    tsMgr.statusMessage = "No grammar selected"
    return
  let grammar = tsMgr.grammars[tsMgr.cursorIndex]
  if grammar.installed:
    tsMgr.statusMessage = grammar.name & " is already installed"
    return

  let cmd = buildInstallCmd(grammar)
  try:
    tsInstallProc = startProcess("/bin/sh", args = ["-c", cmd],
                                  options = {poStdErrToStdOut})
    tsInstallIdx = tsMgr.cursorIndex
    tsInstallIsUninstall = false
    tsInstallOutputBuf = ""
    tsInstallOutputFd = cint(tsInstallProc.outputHandle)
    setNonBlocking(tsInstallOutputFd)
    tsMgr.installing = true
    tsMgr.statusMessage = "Installing " & grammar.name & "..."
  except OSError:
    tsMgr.statusMessage = "Failed to start installation"

proc startGrammarUninstall*() =
  if tsMgr.installing:
    tsMgr.statusMessage = "Already in progress..."
    return
  if tsMgr.cursorIndex >= tsMgr.grammars.len:
    tsMgr.statusMessage = "No grammar selected"
    return
  let grammar = tsMgr.grammars[tsMgr.cursorIndex]
  if not grammar.installed:
    tsMgr.statusMessage = grammar.name & " is not installed"
    return

  let dir = grammarDir(grammar.name)
  try:
    tsInstallProc = startProcess("/bin/sh",
      args = ["-c", "rm -rf " & dir & " && echo 'Removed " & grammar.name & "'"],
      options = {poStdErrToStdOut})
    tsInstallIdx = tsMgr.cursorIndex
    tsInstallIsUninstall = true
    tsInstallOutputBuf = ""
    tsInstallOutputFd = cint(tsInstallProc.outputHandle)
    setNonBlocking(tsInstallOutputFd)
    tsMgr.installing = true
    tsMgr.statusMessage = "Uninstalling " & grammar.name & "..."
  except OSError:
    tsMgr.statusMessage = "Failed to start uninstallation"

proc pollTsInstallProgress*(): bool =
  ## Returns true if there was activity.
  if not tsMgr.installing or tsInstallProc == nil:
    return false

  drainTsOutput()

  let lastLine = lastMeaningfulLine(tsInstallOutputBuf)
  if lastLine.len > 0:
    tsMgr.statusMessage = lastLine

  if tsInstallProc.running:
    return true

  # Process done
  drainTsOutput()
  let exitCode = tsInstallProc.peekExitCode()
  tsInstallProc.close()
  tsInstallProc = nil
  tsInstallOutputFd = -1
  tsMgr.installing = false

  let grammarName = if tsInstallIdx >= 0 and tsInstallIdx < tsMgr.grammars.len:
    tsMgr.grammars[tsInstallIdx].name
  else:
    "grammar"

  if exitCode == 0:
    if tsInstallIdx >= 0 and tsInstallIdx < tsMgr.grammars.len:
      checkGrammarInstalled(tsMgr.grammars[tsInstallIdx])
    if tsInstallIsUninstall:
      tsMgr.statusMessage = grammarName & " uninstalled"
    else:
      tsMgr.statusMessage = grammarName & " installed successfully"
  else:
    let errLine = lastMeaningfulLine(tsInstallOutputBuf)
    let detail = if errLine.len > 0: ": " & errLine else: ""
    if tsInstallIsUninstall:
      tsMgr.statusMessage = "Failed to uninstall" & detail
    else:
      tsMgr.statusMessage = "Failed to install" & detail

  tsInstallIdx = -1
  tsInstallOutputBuf = ""
  return true

proc findLanguageForFile*(filePath: string): string =
  ## Returns language name if a grammar is installed for this file extension
  let ext = "." & filePath.rsplit('.', maxsplit = 1)[^1]
  for g in tsMgr.grammars:
    if g.installed:
      for e in g.extensions:
        if e == ext:
          return g.name
  return ""
