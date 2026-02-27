## LSP server manager (Mason-like registry, install/uninstall)
## Servers are installed into ~/.config/niv/lsp/ (managed directory)

import std/[osproc, os, strutils, posix]

const
  nivConfigDir* = ".config" / "niv"
  nivLspDir* = nivConfigDir / "lsp"
  nivLspBinDir* = nivLspDir / "bin"
  nivLspDisabledDir* = nivLspDir / "disabled"
  nivLspEnabledDir* = nivLspDir / "enabled"

type
  LspServerCategory* = enum
    scLsp
    scDap
    scLinter
    scFormatter

  LspServerInfo* = object
    name*: string
    command*: string       ## Executable name
    args*: seq[string]     ## Extra arguments (e.g. @["--stdio"])
    installCmd*: string    ## Shell command to install
    uninstallCmd*: string  ## Shell command to uninstall
    languages*: seq[string]
    extensions*: seq[string]  ## File extensions (e.g. @[".json"])
    languageId*: string       ## LSP language identifier
    category*: LspServerCategory
    installed*: bool
    bundled*: bool         ## Bundled with niv (no install/uninstall subprocess)
    enabledByDefault*: bool  ## If false, requires manual enable via LSP manager

  LspManagerState* = object
    visible*: bool
    servers*: seq[LspServerInfo]
    cursorIndex*: int
    scrollOffset*: int
    statusMessage*: string
    installing*: bool      ## True while install/uninstall runs in background

var lspMgr*: LspManagerState
var installProc: Process
var installIdx: int = -1
var installIsUninstall: bool = false
var installOutputBuf: string = ""
var installOutputFd: cint = -1

proc lspBaseDir*(): string =
  ## Returns the full path to ~/.config/niv/lsp
  getHomeDir() / nivLspDir

proc lspBinDir*(): string =
  ## Returns the full path to ~/.config/niv/lsp/bin
  getHomeDir() / nivLspBinDir

proc serverBinPath*(command: string): string =
  ## Returns the full path to a server binary in the managed directory
  lspBinDir() / command

proc lspDisabledDir*(): string =
  ## Returns the full path to ~/.config/niv/lsp/disabled
  getHomeDir() / nivLspDisabledDir

proc lspEnabledDir*(): string =
  getHomeDir() / nivLspEnabledDir

proc ensureLspDirs*() =
  createDir(lspBinDir())
  createDir(lspDisabledDir())
  createDir(lspEnabledDir())

proc isServerDisabled*(name: string): bool =
  fileExists(lspDisabledDir() / name)

proc disableServer*(name: string) =
  ensureLspDirs()
  writeFile(lspDisabledDir() / name, "")

proc enableServer*(name: string) =
  let path = lspDisabledDir() / name
  if fileExists(path):
    removeFile(path)

proc findBundledServer*(command: string): string =
  ## Find a bundled server: check next to niv binary first, then PATH
  let appDir = getAppDir()
  let beside = appDir / command
  if fileExists(beside):
    return beside
  let inPath = findExe(command)
  if inPath.len > 0:
    return inPath
  return ""

proc isServerExplicitlyEnabled*(name: string): bool =
  fileExists(lspEnabledDir() / name)

proc checkInstalled(server: var LspServerInfo) =
  if server.bundled:
    let binaryFound = findBundledServer(server.command).len > 0
    if server.enabledByDefault:
      server.installed = binaryFound and not isServerDisabled(server.name)
    else:
      server.installed = binaryFound and isServerExplicitlyEnabled(server.name)
  else:
    server.installed = fileExists(serverBinPath(server.command)) or
                       findExe(server.command).len > 0

proc initLspManager*() =
  ensureLspDirs()
  let base = lspBaseDir()
  lspMgr.servers = @[
    LspServerInfo(
      name: "niv_json_lsp",
      command: "niv_json_lsp",
      languages: @["json"],
      extensions: @[".json"],
      languageId: "json",
      category: scLsp,
      bundled: true,
      enabledByDefault: true,
    ),
    LspServerInfo(
      name: "niv_python_lsp",
      command: "niv_python_lsp",
      languages: @["python"],
      extensions: @[".py"],
      languageId: "python",
      category: scLsp,
      bundled: true,
      enabledByDefault: true,
    ),
    LspServerInfo(
      name: "niv_nim_lsp",
      command: "niv_nim_lsp",
      languages: @["nim"],
      extensions: @[".nim", ".nims", ".nimble"],
      languageId: "nim",
      category: scLsp,
      bundled: true,
      enabledByDefault: true,
    ),
    LspServerInfo(
      name: "niv_toml_lsp",
      command: "niv_toml_lsp",
      languages: @["toml"],
      extensions: @[".toml"],
      languageId: "toml",
      category: scLsp,
      bundled: true,
      enabledByDefault: true,
    ),
    LspServerInfo(
      name: "niv_yaml_lsp",
      command: "niv_yaml_lsp",
      languages: @["yaml"],
      extensions: @[".yaml", ".yml"],
      languageId: "yaml",
      category: scLsp,
      bundled: true,
      enabledByDefault: true,
    ),
    LspServerInfo(
      name: "niv_md_lsp",
      command: "niv_md_lsp",
      languages: @["markdown"],
      extensions: @[".md", ".markdown"],
      languageId: "markdown",
      category: scLsp,
      bundled: true,
      enabledByDefault: true,
    ),
    LspServerInfo(
      name: "niv_bash_lsp",
      command: "niv_bash_lsp",
      languages: @["bash"],
      extensions: @[".sh", ".bash", ".zsh"],
      languageId: "shellscript",
      category: scLsp,
      bundled: true,
      enabledByDefault: true,
    ),
    LspServerInfo(
      name: "niv_css_lsp",
      command: "niv_css_lsp",
      languages: @["css"],
      extensions: @[".css"],
      languageId: "css",
      category: scLsp,
      bundled: true,
      enabledByDefault: true,
    ),
  ]
  for i in 0..<lspMgr.servers.len:
    checkInstalled(lspMgr.servers[i])

proc findServerForFile*(filePath: string): ptr LspServerInfo =
  ## Find an installed server that handles the given file extension
  let ext = if '.' in filePath: "." & filePath.rsplit('.', maxsplit = 1)[^1]
            else: ""
  if ext.len == 0:
    return nil
  for i in 0..<lspMgr.servers.len:
    if lspMgr.servers[i].installed:
      for e in lspMgr.servers[i].extensions:
        if e == ext:
          return addr lspMgr.servers[i]
  return nil

proc openLspManager*() =
  for i in 0..<lspMgr.servers.len:
    checkInstalled(lspMgr.servers[i])
  lspMgr.visible = true
  lspMgr.cursorIndex = 0
  lspMgr.scrollOffset = 0
  if not lspMgr.installing:
    lspMgr.statusMessage = ""

proc closeLspManager*() =
  lspMgr.visible = false
  if not lspMgr.installing:
    lspMgr.statusMessage = ""

proc managerMoveUp*() =
  if lspMgr.cursorIndex > 0:
    dec lspMgr.cursorIndex

proc managerMoveDown*() =
  if lspMgr.cursorIndex < lspMgr.servers.len - 1:
    inc lspMgr.cursorIndex

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL)
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc lastMeaningfulLine(buf: string): string =
  ## Extract the last non-empty line from accumulated output
  let lines = buf.strip().splitLines()
  for i in countdown(lines.len - 1, 0):
    let line = lines[i].strip()
    if line.len > 0:
      return line
  return ""

proc drainOutput() =
  ## Non-blocking read of whatever is available from the install process stdout
  if installOutputFd < 0:
    return
  var chunk: array[4096, char]
  while true:
    let n = posix.read(installOutputFd, addr chunk[0], chunk.len)
    if n <= 0:
      break
    for i in 0..<n:
      installOutputBuf.add(chunk[i])

proc startInstall*() =
  if lspMgr.installing:
    lspMgr.statusMessage = "Already installing..."
    return
  if lspMgr.cursorIndex >= lspMgr.servers.len:
    lspMgr.statusMessage = "No server selected"
    return
  let server = lspMgr.servers[lspMgr.cursorIndex]
  if server.installed:
    lspMgr.statusMessage = server.name & " is already installed"
    return

  # Bundled servers: enable via marker files
  if server.bundled:
    enableServer(server.name)
    if not server.enabledByDefault:
      ensureLspDirs()
      writeFile(lspEnabledDir() / server.name, "")
    checkInstalled(lspMgr.servers[lspMgr.cursorIndex])
    if lspMgr.servers[lspMgr.cursorIndex].installed:
      lspMgr.statusMessage = server.name & " enabled"
    else:
      lspMgr.statusMessage = server.name & " binary not found"
    return

  ensureLspDirs()

  try:
    installProc = startProcess("/bin/sh", args = ["-c", server.installCmd],
                               options = {poStdErrToStdOut})
    installIdx = lspMgr.cursorIndex
    installIsUninstall = false
    installOutputBuf = ""
    installOutputFd = cint(installProc.outputHandle)
    setNonBlocking(installOutputFd)
    lspMgr.installing = true
    lspMgr.statusMessage = "Installing " & server.name & "..."
  except OSError:
    lspMgr.statusMessage = "Failed to start installation"

proc startUninstall*() =
  if lspMgr.installing:
    lspMgr.statusMessage = "Already in progress..."
    return
  if lspMgr.cursorIndex >= lspMgr.servers.len:
    lspMgr.statusMessage = "No server selected"
    return
  let server = lspMgr.servers[lspMgr.cursorIndex]
  if not server.installed:
    lspMgr.statusMessage = server.name & " is not installed"
    return

  # Bundled servers: disable via marker files
  if server.bundled:
    disableServer(server.name)
    if not server.enabledByDefault:
      let enPath = lspEnabledDir() / server.name
      if fileExists(enPath): removeFile(enPath)
    checkInstalled(lspMgr.servers[lspMgr.cursorIndex])
    lspMgr.statusMessage = server.name & " disabled"
    return

  try:
    installProc = startProcess("/bin/sh", args = ["-c", server.uninstallCmd],
                               options = {poStdErrToStdOut})
    installIdx = lspMgr.cursorIndex
    installIsUninstall = true
    installOutputBuf = ""
    installOutputFd = cint(installProc.outputHandle)
    setNonBlocking(installOutputFd)
    lspMgr.installing = true
    lspMgr.statusMessage = "Uninstalling " & server.name & "..."
  except OSError:
    lspMgr.statusMessage = "Failed to start uninstallation"

proc pollInstallProgress*(): bool =
  ## Non-blocking poll: drain output, update status, detect completion.
  ## Returns true if there was activity.
  if not lspMgr.installing or installProc == nil:
    return false

  # Read whatever is available from the pipe
  drainOutput()

  # Update status message with latest output line
  let lastLine = lastMeaningfulLine(installOutputBuf)
  if lastLine.len > 0:
    lspMgr.statusMessage = lastLine

  # Check if process has finished
  if installProc.running:
    return true

  # Process done — final drain
  drainOutput()
  let exitCode = installProc.peekExitCode()
  installProc.close()
  installProc = nil
  installOutputFd = -1
  lspMgr.installing = false

  let serverName = if installIdx >= 0 and installIdx < lspMgr.servers.len:
    lspMgr.servers[installIdx].name
  else:
    "server"

  if exitCode == 0:
    if installIdx >= 0 and installIdx < lspMgr.servers.len:
      checkInstalled(lspMgr.servers[installIdx])
    if installIsUninstall:
      lspMgr.statusMessage = serverName & " uninstalled"
    else:
      lspMgr.statusMessage = serverName & " installed successfully"
  else:
    let errLine = lastMeaningfulLine(installOutputBuf)
    let detail = if errLine.len > 0: ": " & errLine else: ""
    if installIsUninstall:
      lspMgr.statusMessage = "Failed to uninstall" & detail
    else:
      lspMgr.statusMessage = "Failed to install" & detail

  installIdx = -1
  installOutputBuf = ""
  return true
