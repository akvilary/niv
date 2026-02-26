switch("threads", "on")

# Download tree-sitter source if not present
import std/os
const tsVersion = "0.26.6"
const tsDir = "deps" / ("tree-sitter-" & tsVersion)

if not dirExists(thisDir() / tsDir):
  mkDir(thisDir() / "deps")
  exec "curl -sL https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v" &
       tsVersion & ".tar.gz | tar xz -C " & thisDir() / "deps"
