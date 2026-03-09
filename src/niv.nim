## niv — A Vim-like terminal text editor

import std/os
import niv/editor
import niv/types

proc main() =
  let args = commandLineParams()
  let arg = if args.len > 0: args[0] else: ""
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
