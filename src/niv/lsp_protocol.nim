## JSON-RPC 2.0 framing and LSP message builders

import std/json

proc encodeMessage*(content: JsonNode): string =
  ## Wrap a JSON-RPC message with Content-Length header
  let body = $content
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc buildInitialize*(id: int, processId: int, rootUri: string): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "id": id,
    "method": "initialize",
    "params": {
      "processId": processId,
      "rootUri": rootUri,
      "capabilities": {
        "textDocument": {
          "completion": {
            "completionItem": {
              "snippetSupport": false
            }
          },
          "publishDiagnostics": {
            "relatedInformation": false
          },
          "definition": {},
          "semanticTokens": {
            "requests": {"full": true, "range": true},
            "tokenTypes": [
              "namespace", "type", "class", "enum", "interface",
              "struct", "typeParameter", "parameter", "variable",
              "property", "enumMember", "event", "function", "method",
              "macro", "keyword", "modifier", "comment", "string",
              "number", "regexp", "operator", "decorator"
            ],
            "tokenModifiers": [
              "declaration", "definition", "readonly", "static",
              "deprecated", "abstract", "async", "modification",
              "documentation", "defaultLibrary"
            ],
            "formats": ["relative"]
          }
        }
      }
    }
  }

proc buildSemanticTokensFull*(id: int, uri: string): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "id": id,
    "method": "textDocument/semanticTokens/full",
    "params": {
      "textDocument": {"uri": uri}
    }
  }

proc buildSemanticTokensRange*(id: int, uri: string,
                                startLine, startCol, endLine, endCol: int): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "id": id,
    "method": "textDocument/semanticTokens/range",
    "params": {
      "textDocument": {"uri": uri},
      "range": {
        "start": {"line": startLine, "character": startCol},
        "end": {"line": endLine, "character": endCol}
      }
    }
  }

proc buildInitialized*(): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "method": "initialized",
    "params": {}
  }

proc buildDidOpen*(uri, languageId: string, version: int, text: string): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "method": "textDocument/didOpen",
    "params": {
      "textDocument": {
        "uri": uri,
        "languageId": languageId,
        "version": version,
        "text": text
      }
    }
  }

proc buildDidChange*(uri: string, version: int, text: string): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "method": "textDocument/didChange",
    "params": {
      "textDocument": {
        "uri": uri,
        "version": version
      },
      "contentChanges": [
        {"text": text}
      ]
    }
  }

proc buildDidClose*(uri: string): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "method": "textDocument/didClose",
    "params": {
      "textDocument": {
        "uri": uri
      }
    }
  }

proc buildCompletion*(id: int, uri: string, line, col: int): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "id": id,
    "method": "textDocument/completion",
    "params": {
      "textDocument": {"uri": uri},
      "position": {"line": line, "character": col}
    }
  }

proc buildDefinition*(id: int, uri: string, line, col: int): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "id": id,
    "method": "textDocument/definition",
    "params": {
      "textDocument": {"uri": uri},
      "position": {"line": line, "character": col}
    }
  }

proc buildShutdown*(id: int): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "id": id,
    "method": "shutdown"
  }

proc buildExit*(): JsonNode =
  %*{
    "jsonrpc": "2.0",
    "method": "exit"
  }
