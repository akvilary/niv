## PATH management: save/load project paths, apply to env

import std/[os, json, strutils]

const
  nivProjectDir = ".niv"
  nivPathsFile = "paths.json"

var savedPaths*: seq[string] = @[]
var originalPath: string = ""

proc pathsFilePath(): string =
  getCurrentDir() / nivProjectDir / nivPathsFile

proc loadPaths*() =
  savedPaths = @[]
  originalPath = getEnv("PATH")
  let fp = pathsFilePath()
  if not fileExists(fp):
    return
  try:
    let content = readFile(fp)
    let node = parseJson(content)
    if node.hasKey("paths") and node["paths"].kind == JArray:
      for p in node["paths"]:
        let s = p.getStr()
        if s.len > 0:
          savedPaths.add(s)
  except JsonParsingError, IOError, OSError:
    discard

proc savePaths() =
  let dir = getCurrentDir() / nivProjectDir
  createDir(dir)
  var arr = newJArray()
  for p in savedPaths:
    arr.add(newJString(p))
  let node = %* {"paths": arr}
  writeFile(pathsFilePath(), pretty(node) & "\n")

proc applyPathsToEnv*() =
  if savedPaths.len == 0:
    putEnv("PATH", originalPath)
    return
  var parts: seq[string] = @[]
  for p in savedPaths:
    if p notin parts:
      parts.add(p)
  for existing in originalPath.split(':'):
    if existing.len > 0 and existing notin parts:
      parts.add(existing)
  putEnv("PATH", parts.join(":"))

proc isPathSaved*(path: string): bool =
  path in savedPaths

proc togglePath*(path: string): bool =
  ## Toggle a path in the saved list. Returns true if added, false if removed.
  let idx = savedPaths.find(path)
  if idx >= 0:
    savedPaths.delete(idx)
    savePaths()
    applyPathsToEnv()
    return false
  else:
    savedPaths.add(path)
    savePaths()
    applyPathsToEnv()
    return true
