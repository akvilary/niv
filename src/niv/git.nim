## Git integration: status, staging, diff, commit, log

import std/[strutils, osproc]
import types

proc gitGetStatus*(): seq[GitFileStatus] =
  try:
    let (output, code) = execCmdEx("git status --porcelain", options = {poUsePath})
    if code != 0:
      return @[]
    for line in output.splitLines():
      if line.len < 3:
        continue
      let indexSt = line[0]
      let workSt = line[1]
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

proc gitDiscard*(path: string): bool =
  try:
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

proc gitLog*(count: int = 30): seq[GitLogEntry] =
  try:
    let (output, code) = execCmdEx("git log --oneline -" & $count, options = {poUsePath})
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
  panel.commitMessage = ""
  panel.inCommitInput = false
  panel.confirmDiscard = false
  panel.files = gitGetStatus()

proc closeGitPanel*(panel: var GitPanelState) =
  panel.visible = false
  panel.inCommitInput = false
  panel.confirmDiscard = false

proc refreshGitFiles*(panel: var GitPanelState) =
  panel.files = gitGetStatus()
  if panel.cursorIndex >= panel.files.len:
    panel.cursorIndex = max(0, panel.files.len - 1)

proc isStaged*(f: GitFileStatus): bool =
  f.indexStatus != ' ' and f.indexStatus != '?'

proc isUntracked*(f: GitFileStatus): bool =
  f.indexStatus == '?' and f.workTreeStatus == '?'

proc statusChar*(f: GitFileStatus): char =
  if f.isStaged:
    return f.indexStatus
  if f.isUntracked:
    return '?'
  return f.workTreeStatus
