# Package
version       = "0.1.0"
author        = "akvilary"
description   = "A Vim-like terminal text editor"
license       = "MIT"
srcDir        = "src"
bin           = @["niv", "niv_json_lsp", "niv_python_lsp", "niv_nim_lsp", "niv_toml_lsp", "niv_yaml_lsp", "niv_md_lsp", "niv_bash_lsp", "niv_css_lsp", "niv_html_lsp"]

# Dependencies
requires "nim >= 2.2.0"
