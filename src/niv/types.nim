## All shared types for nimvim

import std/unicode

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
    ch*: Rune       # for kkChar (Unicode code point)
    ctrl*: Rune     # for kkCtrlKey (e.g. 'c' for Ctrl-C)

  Mode* = enum
    mNormal
    mInsert
    mCommand
    mExplore
    mLspManager
    mGit

  Position* = object
    line*: int      # 0-indexed
    col*: int       # 0-indexed byte offset

  SemanticToken* = object
    col*: int        ## Start column (0-indexed)
    length*: int     ## Token length in characters
    tokenType*: int  ## Index into tokenLegend

  TokenDiff* = object
    startLine*: int
    linesBefore*: seq[seq[SemanticToken]]
    linesAfter*: seq[seq[SemanticToken]]

  UndoOp* = enum
    uoInsert
    uoDelete

  UndoEntry* = object
    op*: UndoOp
    offset*: int       ## byte offset in data
    text*: string      ## inserted/deleted bytes

  UndoGroup* = object
    entries*: seq[UndoEntry]
    tokenDiff*: TokenDiff

  UndoHistory* = object
    undoStack*: seq[UndoGroup]
    redoStack*: seq[UndoGroup]
    current*: UndoGroup
    captureActive*: bool
    captureMinLine*: int
    captureMaxLine*: int        ## exclusive, original "before" range
    captureAfterEndLine*: int   ## exclusive, current "after" range

  Buffer* = object
    data*: string            ## Raw file bytes (newlines preserved)
    lineIndex*: seq[int]     ## Byte offset of each line start
    filePath*: string
    modified*: bool
    undo*: UndoHistory
    fullyLoaded*: bool       ## Whole file loaded?
    totalSize*: int64        ## File size in bytes
    loadedBytes*: int64      ## Bytes loaded so far
    encoding*: string        ## Detected file encoding
    estimatedTotalLines*: int ## Estimated from first chunk

  Viewport* = object
    topLine*: int   ## First visible line number
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
    horizontalScroll*: int

  GitFileStatus* = object
    path*: string
    indexStatus*: Rune
    workTreeStatus*: Rune

  GitLogEntry* = object
    hash*: string
    message*: string

  ConflictChoice* = enum
    ccOurs, ccTheirs

  ConflictFile* = object
    path*: string
    cursorIndex*: int   # which conflict section is selected
    conflictCount*: int # total <<<<<<< markers

  GitPanelView* = enum
    gvFiles
    gvDiff
    gvLog
    gvMergeConflicts
    gvBranches

  GitPanelState* = object
    visible*: bool
    height*: int
    view*: GitPanelView
    files*: seq[GitFileStatus]
    cursorIndex*: int
    scrollOffset*: int
    diffLines*: seq[string]
    diffScrollOffset*: int
    diffReturnView*: GitPanelView
    logEntries*: seq[GitLogEntry]
    logCursorIndex*: int
    logScrollOffset*: int
    inCommitInput*: bool
    inMergeInput*: bool        # typing branch name for merge
    mergeInputBranch*: string  # branch name being typed
    isMergeCommit*: bool       # commit editor is for merge (not regular commit)
    conflictFiles*: seq[ConflictFile]
    conflictCursorIndex*: int
    conflictScrollOffset*: int
    branches*: seq[string]         # all branches sorted by recency
    filteredBranches*: seq[string] # filtered by search query
    branchQuery*: string           # search input
    branchCursorIndex*: int
    branchDirectOpen*: bool        # opened via Ctrl+b from normal mode
    branchScrollOffset*: int
    logHasMore*: bool
    logLoadedCount*: int
    savedBuffer*: Buffer
    savedCursor*: Position
    savedTopLine*: int
    confirmDiscard*: bool

  SearchMatch* = object
    line*: int
    col*: int

  EditorState* = object
    buffer*: Buffer
    cursor*: Position
    viewport*: Viewport
    mode*: Mode
    commandLine*: string
    statusMessage*: string
    running*: bool
    yankRegister*: string
    yankIsLinewise*: bool
    pendingKeys*: string
    sidebar*: SidebarState
    gitBranch*: string
    gitDiffStat*: string
    gitPanel*: GitPanelState
    searchQuery*: string
    searchMatches*: seq[SearchMatch]
    searchIndex*: int
    searchInput*: bool

proc noKey*(): InputKey =
  InputKey(kind: kkNone)

proc charKey*(r: Rune): InputKey =
  InputKey(kind: kkChar, ch: r)

proc ctrlKey*(r: Rune): InputKey =
  InputKey(kind: kkCtrlKey, ctrl: r)

proc specialKey*(kind: KeyKind): InputKey =
  InputKey(kind: kind)
