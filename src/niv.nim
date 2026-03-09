## niv — A Vim-like terminal text editor

import std/os
import niv/editor
import niv/types

const NimblePkgVersion {.strdefine.} = "dev"

proc main() =
  let args = commandLineParams()
  let arg = if args.len > 0: args[0] else: ""
  if arg == "--version" or arg == "-v":
    echo "niv " & NimblePkgVersion
    return
  var state: EditorState
  if arg.len > 0 and dirExists(arg):
    setCurrentDir(arg)
    state = newEditorState("")
    state.sidebar.visible = true
    state.sidebar.focused = true
    state.mode = mExplore
  else:
    state = newEditorState(arg)
  state.run()

when isMainModule:
  main()
