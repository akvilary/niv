## LSP type definitions

type
  LspState* = enum
    lsOff        ## LSP server not running
    lsStarting   ## Waiting for initialize response
    lsRunning    ## Ready for requests
    lsStopping   ## Sent shutdown, waiting for exit

  DiagnosticSeverity* = enum
    dsError = 1
    dsWarning = 2
    dsInfo = 3
    dsHint = 4

  LspRange* = object
    startLine*: int
    startCol*: int
    endLine*: int
    endCol*: int

  Diagnostic* = object
    range*: LspRange
    severity*: DiagnosticSeverity
    message*: string
    source*: string

  CompletionItem* = object
    label*: string
    kind*: int       ## LSP CompletionItemKind value
    detail*: string
    insertText*: string

  CompletionState* = object
    active*: bool
    items*: seq[CompletionItem]
    selectedIndex*: int
    triggerCol*: int  ## Column where completion was triggered

  LspLocation* = object
    uri*: string
    line*: int
    col*: int

  LspEventKind* = enum
    lekDiagnostics
    lekResponse
    lekError
    lekServerExited

  ## Flat structure for safe Channel transport between threads.
  ## Each event uses only the fields relevant to its kind.
  LspEvent* = object
    kind*: LspEventKind
    requestId*: int               # lekResponse
    diagnostics*: seq[Diagnostic] # lekDiagnostics
    diagUri*: string              # lekDiagnostics
    responseJson*: string         # lekResponse: raw JSON of "result"
    errorMessage*: string         # lekError
    exitCode*: int                # lekServerExited
