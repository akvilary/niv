## All shared types for nimvim

type
  KeyKind* = enum
    kkNone
    kkChar
    kkEscape
    kkEnter
    kkBackspace
    kkDelete
    kkTab
    kkArrowUp
    kkArrowDown
    kkArrowLeft
    kkArrowRight
    kkHome
    kkEnd
    kkPageUp
    kkPageDown
    kkCtrlKey

  InputKey* = object
    kind*: KeyKind
    ch*: char       # for kkChar
    ctrl*: char     # for kkCtrlKey (e.g. 'c' for Ctrl-C)

  Mode* = enum
    mNormal
    mInsert
    mCommand
    mExplore
    mLspManager

  Position* = object
    line*: int      # 0-indexed
    col*: int       # 0-indexed byte offset

  UndoOp* = enum
    uoInsertChar
    uoDeleteChar
    uoInsertLine
    uoDeleteLine
    uoReplaceLine
    uoSplitLine
    uoJoinLines

  UndoEntry* = object
    op*: UndoOp
    pos*: Position
    text*: string
    lines*: seq[string]

  UndoGroup* = object
    entries*: seq[UndoEntry]

  UndoHistory* = object
    undoStack*: seq[UndoGroup]
    redoStack*: seq[UndoGroup]
    current*: UndoGroup

  Buffer* = object
    lines*: seq[string]
    filePath*: string
    modified*: bool
    undo*: UndoHistory

  Viewport* = object
    topLine*: int
    leftCol*: int
    height*: int    # usable rows for text
    width*: int     # total terminal width

  FileNodeKind* = enum
    fnkFile
    fnkDirectory

  FileNode* = ref object
    name*: string
    path*: string
    kind*: FileNodeKind
    children*: seq[FileNode]
    expanded*: bool
    depth*: int

  SidebarState* = object
    visible*: bool
    focused*: bool
    width*: int
    rootPath*: string
    rootNode*: FileNode
    flatList*: seq[FileNode]
    cursorIndex*: int
    scrollOffset*: int

  EditorState* = object
    buffer*: Buffer
    cursor*: Position
    viewport*: Viewport
    mode*: Mode
    commandLine*: string
    statusMessage*: string
    running*: bool
    yankRegister*: seq[string]
    yankIsLinewise*: bool
    pendingKeys*: string
    sidebar*: SidebarState

proc noKey*(): InputKey =
  InputKey(kind: kkNone)

proc charKey*(c: char): InputKey =
  InputKey(kind: kkChar, ch: c)

proc ctrlKey*(c: char): InputKey =
  InputKey(kind: kkCtrlKey, ctrl: c)

proc specialKey*(kind: KeyKind): InputKey =
  InputKey(kind: kind)
