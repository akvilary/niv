## PATH management: save/load project paths, apply to env

import std/[os, json, strutils, sequtils]

const
  nivProjectDir = ".niv"
  nivPathsFile = "paths.json"

var savedPaths*: seq[string] = @[]

proc pathsFilePath(): string =
  getCurrentDir() / nivProjectDir / nivPathsFile

proc loadPaths*() =
  savedPaths = @[]
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
  ## Prepend savedPaths to PATH and PYTHONPATH (used at startup)
  if savedPaths.len == 0:
    return
  let joined = savedPaths.join(":")
  putEnv("PATH", joined & ":" & getEnv("PATH"))
  putEnv("PYTHONPATH", joined & ":" & getEnv("PYTHONPATH"))

proc isPathSaved*(path: string): bool =
  path in savedPaths

proc togglePath*(path: string): bool =
  ## Toggle a path in the saved list. Returns true if added, false if removed.
  let idx = savedPaths.find(path)
  if idx >= 0:
    savedPaths.delete(idx)
    savePaths()
    putEnv("PATH", getEnv("PATH").split(':').filterIt(it != path).join(":"))
    putEnv("PYTHONPATH", getEnv("PYTHONPATH").split(':').filterIt(it != path).join(":"))
    return false
  else:
    savedPaths.add(path)
    savePaths()
    putEnv("PATH", path & ":" & getEnv("PATH"))
    putEnv("PYTHONPATH", path & ":" & getEnv("PYTHONPATH"))
    return true
