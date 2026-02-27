# niv - Project Manifest

## Core Principles
- Performance is the top priority
- Render the screen only when state changes (user input, file modification, etc.)
- Never render in an infinite loop — if nothing changed, do nothing
- The main loop must block on input, not spin/poll

## Commit Rules
- Never add "Co-Authored-By" lines to commit messages
