## niv — A Vim-like terminal text editor

import std/os
import niv/editor

proc main() =
  let args = commandLineParams()
  let filePath = if args.len > 0: args[0] else: ""
  var state = newEditorState(filePath)
  state.run()

when isMainModule:
  main()
