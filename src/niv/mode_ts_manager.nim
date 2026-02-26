## TreeSitter Manager mode key handler

import types
import ts_manager

proc handleTsManagerMode*(state: var EditorState, key: InputKey) =
  case key.kind
  of kkEscape:
    closeTsManager()
    state.mode = mNormal

  of kkChar:
    case key.ch
    of 'q':
      closeTsManager()
      state.mode = mNormal
    of 'j':
      tsManagerMoveDown()
    of 'k':
      tsManagerMoveUp()
    of 'i':
      startGrammarInstall()
    of 'X':
      startGrammarUninstall()
    else:
      discard

  of kkArrowDown:
    tsManagerMoveDown()
  of kkArrowUp:
    tsManagerMoveUp()

  of kkEnter:
    startGrammarInstall()

  else:
    discard
