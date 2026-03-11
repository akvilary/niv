# niv - Project Manifest

## Core Principles
- Performance is the top priority
- Render the screen only when state changes (user input, file modification, etc.)
- Never render in an infinite loop — if nothing changed, do nothing
- The main loop must block on input, not spin/poll

## Commit Rules
- Never add "Co-Authored-By" lines to commit messages

---

## LSP Server Architecture — Optimized Algorithm

Reference implementation: `niv_python_lsp.nim`. Apply the same patterns to all niv LSP servers (nim, javascript, etc.).

### Communication Layer

- JSON-RPC 2.0 over stdin/stdout with `Content-Length` framing
- Parse `Content-Length:` header with direct integer extraction — no `split()/strip()` allocations
- For responses, build JSON strings directly when possible (e.g. `sendTokensResponse` builds `{"data":[...]}` without creating JsonNode objects)

### Data Model

```
DocumentState
  uri: string
  text: string
  version: int
  lines: seq[string]       # pre-split, updated on every didChange
  known: KnownSymbols      # collected on every didChange

KnownSymbols
  types: HashSet[string]         # class names (including imported)
  functions: HashSet[string]     # top-level function names
  enums: HashSet[string]         # enum class names
  localClasses: Table[name → ClassInfo]  # classes defined in current file
  symbolModules: Table[name → modulePath]  # imported symbol → resolved file path
  imports: seq[ImportInfo]       # all import statements

ClassInfo
  name, bases, bodyStartLine, bodyIndent

ImportInfo
  module, name, alias
```

### Caching Strategy (critical for performance)

All caches are keyed by **absolute file path** and persist across requests. Invalidate only the current file's caches on `didChange`.

| Cache | Key | Value | Purpose |
|-------|-----|-------|---------|
| `moduleLinesCache` | path → seq[string] | File lines | Avoid re-reading files |
| `moduleClassCache` | path → Table[name → ClassInfo] | All classes in module | Avoid re-parsing classes |
| `moduleImportCache` | path → seq[ImportInfo] | Module imports | Avoid re-parsing imports |
| `moduleFuncCache` | path → HashSet[string] | Top-level function names | O(1) function existence check |
| `modulePathCache` | moduleName → path | Resolved file path | Avoid repeated file system lookups |
| `symbolCheckCache` | path → Table[name → SymbolKind] | Symbol classification | Avoid re-classifying imports |

On `didChange`: delete current file from all caches, re-split lines, re-collect `KnownSymbols`.

### Tokenizer Optimization

1. **Precomputed HashSets** for keyword/builtin classification — O(1) lookup instead of linear scan
2. **First-char filter** before `startsWith()` — skip lines that can't match (`if firstChar notin {'c','d','f','i'}: continue`)
3. **Direct `inc pos` in hot loops** — identifiers, comments, numbers never contain `\n`, so skip the full `advance()` template that checks for newlines and updates 7 state variables
4. **Preallocated token seq** — `newSeqOfCap[PythonToken](text.len div 6)` avoids repeated growth
5. **Emit gating for range requests** — don't add tokens before `startLine` to the seq; pass `rangeStart/rangeEnd` to string token emitter
6. **`openArray` in `encodeSemanticTokens`** — allows passing slices without copying
7. **Lightweight `scanStringDiagnostics`** for `didChange` instead of full tokenizer — only detects unterminated strings, no scope tracking or token emission
8. **Zero-allocation char comparisons** — e.g. string prefixes `rf`, `fr`, `rb` compared as char pairs, not via string concatenation
9. **Enum with string values for keywords** — `type Keyword = enum kwNone="", kwDef="def"` with `template ==` for zero-alloc comparisons

### Symbol Collection (`collectKnownSymbols`)

Single pass over lines with early-exit filters:
1. Skip blank lines
2. Check first non-whitespace char: only process `c`(class), `d`(def), `f`(from), `i`(import)
3. For `class`: extract name, bases, body indent → add to `localClasses` + `types`; check enum bases
4. For `def` at indent 0: add to `functions`
5. For `from/import`: parse module, resolve path, classify imported symbols
6. **Skip builtin lookups** — if imported name is in `builtinTypeSet`/`builtinFuncSet`/`builtinConstSet`, classify directly without module resolution

### Import Resolution

```
resolveModulePath(moduleName) → filePath
  1. Check modulePathCache → return if cached
  2. If already ends with .py and exists → return as-is
  3. For each pythonSearchPath:
     - Try searchPath/module.py
     - Try searchPath/module/__init__.py
  4. Cache result (including empty string for "not found")
```

Relative imports: resolve dots to parent directories, check both `name.py` and `name/__init__.py`.

### Go-to-Definition Algorithm

```
getDefinitionContext(lines, line, col) → (qualifier, name)
  - Handle multiline expressions in parens via joinParenContent
  - Walk backward through full dot chain collecting parts
  - Handle parens in chain: ClassName().attr, super().attr
  - Return: ("self.inner", "method") for self.inner.method
```

#### Dispatch by qualifier:

**No qualifier** (`name` only):
1. `findDefinitionInText(lines, name)` — search `def name` / `class name` / `name =` in current file
2. `findDefinitionViaKnown(name, known)` — search via `symbolModules` cache
3. Try as bare module name (`import json` → go to json.py)

**Single qualifier** (`qualifier.name`):
1. `super` → search base classes of enclosing class via MRO
2. Module access → `import json` then `json.loads` → search in module file
3. `resolveQualifierType` → determine class from variable type, then `findMemberWithMRO`

**Chained qualifier** (`a.b.c.name` where qualifier = `a.b.c`):
1. Resolve root: `self`/`cls` → enclosing class, `super` → bases, Uppercase → class itself, other → `resolveQualifierType`
2. For each intermediate part: `resolveAttributeType` → scan class body for `self.attr: Type` / `self.attr = Type()` / `@property` return type / class-level annotations
3. **Propagate module context** through chain — each step may switch to a different file's lines/imports/known
4. Final step: `findMemberWithMRO` on resolved class

### Member Resolution with MRO

```
findMemberWithMRO(lines, className, memberName, imports, visited, known, depth)
  1. findClassInfo → search localClasses, symbolModules, imports, then text
  2. findMemberInClassBody → search for def/self.attr/cls.attr/class-level attr
  3. If not found → recurse into base classes (MRO)
  4. Recursion guard: visited set + depth limit (10)
```

### Attribute Type Resolution

```
resolveAttributeType(lines, className, attrName, imports, visited, known, depth)
  Scan class body for:
  - self.attr: Type / self.attr = Type()
  - cls.attr: Type / cls.attr = Type()
  - @property def attr(...) -> Type:
  - Class-level: attr: Type / attr = Type()
  Skip wrapper types: Optional, List, Dict, Set, Tuple, Union, Sequence, Iterable
  If not found → recurse into base classes
```

### Transitive Import Lookup

When `findMemberWithMRO` fails locally, `findMemberTransitive` follows import chains:
```
for each import in current file:
  resolve module path → check if module defines the target class
  if found → findMemberWithMRO in that module
  if not → recurse into that module's imports
  Guard: visitedPaths set (no depth limit)
```

---

## LSP Client Optimization (editor side)

### Worker Thread (reads LSP stdout)

- **Skip `parseJson` for responses** — extract `id` via string scan (`"id":` + parse integer), pass raw body to main thread. Avoids 50K+ JInt allocations for semantic token responses
- **Full parse only for notifications** (diagnostics) which are small
- For errors: `body.find("\"error\":")` → parse only error responses (small)
- Content-Length: direct integer extraction, no `split`/`strip`

### Main Thread (processes events)

- **Semantic tokens**: direct integer parsing from raw JSON string (`find("\"data\":[")` + manual int parse) — no JsonNode overhead
- Other responses (initialize, definition, completion): `parseJson(body)["result"]` — one parse instead of worker parse + re-serialize + main parse
- `applyTokenDiff`: in-place overwrite when old/new line count matches (common undo/redo case) instead of 3-slice concatenation

### Sending Messages

- Write header and body as separate stream writes — avoids copying ~100KB body string into a concatenated header+body string
- For hot path (`didChange`): consider direct string building instead of `%*{}` → `$` pipeline

### Background Highlighting

- Progressive chunked requests: `BgHighlightChunkSize` lines per request
- Skip viewport responses for lines already covered by background
- Track `bgHighlightReceivedUpTo` to avoid redundant work
- Viewport range cache: `lastRangeTopLine`/`lastRangeEndLine` — skip duplicate requests

---

## Applying to New LSP Servers (nim, javascript, etc.)

The architecture is language-agnostic. For each new language, adapt:

1. **Tokenizer**: language keywords, operators, string syntax, comment syntax. Keep the same hot-loop optimizations (direct `inc pos`, first-char filters, preallocated seqs)
2. **Scope tracking**: indent-based (Python), brace-based (JS/Nim), or hybrid
3. **Symbol collection**: same single-pass approach, adapt for language syntax (`fn`/`proc` vs `def`, `struct`/`interface` vs `class`)
4. **Import resolution**: adapt path resolution (`require`/`import`/`use`), keep the same caching layer
5. **Type resolution**: adapt for language features (TypeScript interfaces, Nim generics, JS prototype chain)
6. **MRO**: adapt inheritance model (single/multiple/prototype-based)
7. **Diagnostics**: lightweight scanner for common errors (unterminated strings, unmatched brackets)
