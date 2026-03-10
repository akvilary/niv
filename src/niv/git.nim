## Git integration: status, staging, diff, commit, log

import std/[strutils, osproc, unicode]
import types

proc gitGetStatus*(): seq[GitFileStatus] =
  try:
    let (output, code) = execCmdEx("git status --porcelain", options = {poUsePath})
    if code != 0:
      return @[]
    for line in output.splitLines():
      if line.len < 3:
        continue
      let indexSt = Rune(ord(line[0]))
      let workSt = Rune(ord(line[1]))
      let path = line[3..^1]
      result.add(GitFileStatus(
        path: path,
        indexStatus: indexSt,
        workTreeStatus: workSt,
      ))
  except OSError:
    return @[]

proc gitDiff*(path: string, staged: bool): string =
  try:
    let cmd = if staged:
      "git diff --cached -- " & quoteShell(path)
    else:
      "git diff -- " & quoteShell(path)
    let (output, code) = execCmdEx(cmd, options = {poUsePath})
    if code == 0:
      return output
    return ""
  except OSError:
    return ""

proc gitDiffUntracked*(path: string): string =
  try:
    let (output, code) = execCmdEx("cat " & quoteShell(path), options = {poUsePath})
    if code == 0:
      var lines: seq[string]
      lines.add("new file: " & path)
      lines.add("")
      for line in output.splitLines():
        lines.add("+" & line)
      return lines.join("\n")
    return ""
  except OSError:
    return ""

proc gitStage*(path: string): bool =
  try:
    let (_, code) = execCmdEx("git add -- " & quoteShell(path), options = {poUsePath})
    return code == 0
  except OSError:
    return false

proc gitUnstage*(path: string): bool =
  try:
    let (_, code) = execCmdEx("git reset HEAD -- " & quoteShell(path), options = {poUsePath})
    return code == 0
  except OSError:
    return false

proc gitDiscard*(path: string, untracked: bool): bool =
  try:
    if untracked:
      let (_, code) = execCmdEx("rm -f " & quoteShell(path), options = {poUsePath})
      return code == 0
    else:
      let (_, code) = execCmdEx("git checkout -- " & quoteShell(path), options = {poUsePath})
      return code == 0
  except OSError:
    return false

proc gitCommit*(message: string): (bool, string) =
  try:
    let (output, code) = execCmdEx("git commit -m " & quoteShell(message), options = {poUsePath})
    return (code == 0, output.strip())
  except OSError:
    return (false, "Failed to run git commit")

proc openGitPanel*(panel: var GitPanelState) =
  panel.visible = true
  panel.view = gvFiles
  panel.cursorIndex = 0
  panel.scrollOffset = 0
  panel.diffLines = @[]
  panel.diffScrollOffset = 0
  panel.logEntries = @[]
  panel.logCursorIndex = 0
  panel.logScrollOffset = 0
  panel.logHasMore = false
  panel.logLoadedCount = 0
  panel.inCommitInput = false
  panel.confirmDiscard = false
  panel.files = gitGetStatus()

proc gitLog*(count: int = 40, skip: int = 0): seq[GitLogEntry] =
  try:
    var cmd = "git log --oneline -" & $count
    if skip > 0:
      cmd.add(" --skip=" & $skip)
    let (output, code) = execCmdEx(cmd, options = {poUsePath})
    if code != 0:
      return @[]
    for line in output.splitLines():
      if line.len == 0:
        continue
      let spaceIdx = line.find(' ')
      if spaceIdx > 0:
        result.add(GitLogEntry(
          hash: line[0..<spaceIdx],
          message: line[spaceIdx + 1..^1],
        ))
  except OSError:
    return @[]

proc gitShowCommit*(hash: string): string =
  try:
    let (output, code) = execCmdEx("git show " & quoteShell(hash), options = {poUsePath})
    if code == 0:
      return output
    return ""
  except OSError:
    return ""

proc gitMerge*(branch: string): (bool, string) =
  ## Run git merge --no-commit. Returns (ok, output).
  try:
    let (output, code) = execCmdEx("git merge --no-commit " & quoteShell(branch), options = {poUsePath})
    return (code == 0, output.strip())
  except OSError:
    return (false, "Failed to run git merge")

proc gitMergeAbort*(): bool =
  try:
    let (_, code) = execCmdEx("git merge --abort", options = {poUsePath})
    return code == 0
  except OSError:
    return false

proc gitMergeCommit*(message: string): (bool, string) =
  ## Commit a merge (works for both clean merge and resolved conflicts).
  try:
    let (output, code) = execCmdEx("git commit -m " & quoteShell(message), options = {poUsePath})
    return (code == 0, output.strip())
  except OSError:
    return (false, "Failed to run git commit")

proc gitCurrentBranch*(): string =
  try:
    let (output, code) = execCmdEx("git branch --show-current", options = {poUsePath})
    if code == 0: return output.strip()
    return ""
  except OSError:
    return ""

proc getConflictFiles*(): seq[ConflictFile] =
  ## Get list of files with merge conflicts (UU status).
  try:
    let (output, code) = execCmdEx("git status --porcelain", options = {poUsePath})
    if code != 0: return @[]
    for line in output.splitLines():
      if line.len < 3: continue
      # Both modified = UU, Added by both = AA, etc.
      if line[0..1] in ["UU", "AA", "DU", "UD"]:
        let path = line[3..^1]
        # Count conflict markers
        var count = 0
        try:
          let content = readFile(path)
          for l in content.splitLines():
            if l.startsWith("<<<<<<<"):
              inc count
        except IOError:
          discard
        result.add(ConflictFile(path: path, cursorIndex: 0, conflictCount: count))
  except OSError:
    return @[]

proc resolveConflict*(path: string, choice: ConflictChoice, conflictIdx: int): bool =
  ## Resolve a specific conflict in a file by choosing ours or theirs.
  try:
    var content = readFile(path)
    var lines = content.splitLines()
    var idx = 0
    var startLine = -1
    var midLine = -1
    var endLine = -1
    # Find the Nth conflict
    for i in 0..<lines.len:
      if lines[i].startsWith("<<<<<<<"):
        if idx == conflictIdx:
          startLine = i
        inc idx
      elif startLine >= 0 and midLine < 0 and lines[i].startsWith("======="):
        midLine = i
      elif startLine >= 0 and midLine >= 0 and lines[i].startsWith(">>>>>>>"):
        endLine = i
        break
    if startLine < 0 or midLine < 0 or endLine < 0:
      return false
    var newLines: seq[string]
    # Lines before conflict
    for i in 0..<startLine:
      newLines.add(lines[i])
    # Chosen side
    case choice
    of ccOurs:
      for i in (startLine + 1)..<midLine:
        newLines.add(lines[i])
    of ccTheirs:
      for i in (midLine + 1)..<endLine:
        newLines.add(lines[i])
    # Lines after conflict
    for i in (endLine + 1)..<lines.len:
      newLines.add(lines[i])
    writeFile(path, newLines.join("\n"))
    return true
  except IOError:
    return false

proc gitBranches*(): seq[string] =
  ## Get all branches sorted by most recent committerdate (descending).
  try:
    let (output, code) = execCmdEx(
      "git branch -a --sort=-committerdate --format='%(refname:short)'",
      options = {poUsePath})
    if code != 0: return @[]
    for line in output.splitLines():
      let name = line.strip()
      if name.len > 0:
        result.add(name)
  except OSError:
    return @[]

proc gitFetch*(): (bool, string) =
  try:
    let (output, code) = execCmdEx("git fetch --prune", options = {poUsePath})
    return (code == 0, output.strip())
  except OSError:
    return (false, "Failed to run git fetch")

proc gitPull*(): (bool, string) =
  try:
    let (output, code) = execCmdEx("git pull", options = {poUsePath})
    return (code == 0, output.strip())
  except OSError:
    return (false, "Failed to run git pull")

proc gitPush*(): (bool, string) =
  try:
    let (output, code) = execCmdEx("git push", options = {poUsePath})
    return (code == 0, output.strip())
  except OSError:
    return (false, "Failed to run git push")

proc gitCheckout*(branch: string): (bool, string) =
  try:
    let (output, code) = execCmdEx("git checkout " & quoteShell(branch), options = {poUsePath})
    return (code == 0, output.strip())
  except OSError:
    return (false, "Failed to run git checkout")

proc closeGitPanel*(panel: var GitPanelState) =
  panel.visible = false
  panel.inCommitInput = false
  panel.confirmDiscard = false

proc refreshGitFiles*(panel: var GitPanelState) =
  panel.files = gitGetStatus()
  if panel.cursorIndex >= panel.files.len:
    panel.cursorIndex = max(0, panel.files.len - 1)

proc isStaged*(f: GitFileStatus): bool =
  f.indexStatus != Rune(ord(' ')) and f.indexStatus != Rune(ord('?'))

proc isUntracked*(f: GitFileStatus): bool =
  f.indexStatus == Rune(ord('?')) and f.workTreeStatus == Rune(ord('?'))

proc statusChar*(f: GitFileStatus): Rune =
  if f.isStaged:
    return f.indexStatus
  if f.isUntracked:
    return Rune(ord('?'))
  return f.workTreeStatus
