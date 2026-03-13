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
    mFind

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
    branchSearch*: SearchInput
    branchCursorIndex*: int
    branchDirectOpen*: bool        # opened via Ctrl+b from normal mode
    branchScrollOffset*: int
    logHasMore*: bool
    logLoadedCount*: int
    branchHasMore*: bool
    branchLoadedCount*: int
    savedBuffer*: Buffer
    savedCursor*: Position
    savedTopLine*: int
    confirmDiscard*: bool

  SearchInput* = object
    query*: seq[Rune]
    cursor*: int               ## cursor position in runes

  SearchMatch* = object
    line*: int
    col*: int

  FindMatch* = object
    filePath*: string
    line*: int        ## 0-indexed line number
    col*: int         ## 0-indexed column
    lineText*: string ## the matching line content

  FindDisplayKind* = enum
    fdkDir, fdkFile, fdkMatch

  FindDisplayItem* = object
    kind*: FindDisplayKind
    filePath*: string   ## dir path for fdkDir, file path for fdkFile/fdkMatch
    name*: string       ## display name (dir name, file name)
    matchIdx*: int      ## index into results (for fdkMatch)
    expanded*: bool     ## for fdkDir/fdkFile: whether children are shown
    matchCount*: int    ## for fdkDir: total matches, fdkFile: file matches
    depth*: int         ## indent level: 0=dir, 1=file, 2=match

  FindState* = object
    search*: SearchInput
    results*: seq[FindMatch]
    displayItems*: seq[FindDisplayItem]
    cursorIndex*: int
    scrollOffset*: int
    previewLines*: seq[string]
    previewStartLine*: int  ## file line number where preview starts
    searched*: bool         ## true after first search
    searchDir*: string      ## directory to search in ("" = cwd)
    caseSensitive*: bool    ## case-sensitive search

  EditorState* = object
    buffer*: Buffer
    cursor*: Position
    desiredCol*: int         ## sticky column for vertical movement (j/k)
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
    findState*: FindState

proc addChar*(si: var SearchInput, ch: Rune) =
  si.query.insert(ch, si.cursor)
  inc si.cursor

proc backspace*(si: var SearchInput) =
  if si.cursor > 0:
    si.query.delete(si.cursor - 1)
    dec si.cursor

proc deleteChar*(si: var SearchInput) =
  if si.cursor < si.query.len:
    si.query.delete(si.cursor)

proc moveLeft*(si: var SearchInput) =
  if si.cursor > 0: dec si.cursor

proc moveRight*(si: var SearchInput) =
  if si.cursor < si.query.len: inc si.cursor

proc moveHome*(si: var SearchInput) =
  si.cursor = 0

proc moveEnd*(si: var SearchInput) =
  si.cursor = si.query.len

proc clear*(si: var SearchInput) =
  si.query = @[]
  si.cursor = 0

proc text*(si: SearchInput): string =
  $si.query

proc noKey*(): InputKey =
  InputKey(kind: kkNone)

proc charKey*(r: Rune): InputKey =
  InputKey(kind: kkChar, ch: r)

proc ctrlKey*(r: Rune): InputKey =
  InputKey(kind: kkCtrlKey, ctrl: r)

proc specialKey*(kind: KeyKind): InputKey =
  InputKey(kind: kind)
