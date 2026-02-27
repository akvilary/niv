# Package
version       = "0.1.0"
author        = "akvilary"
description   = "A Vim-like terminal text editor"
license       = "MIT"
srcDir        = "src"
bin           = @["niv", "niv_json_lsp", "niv_python_lsp"]

# Dependencies
requires "nim >= 2.2.0"
