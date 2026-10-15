# Rules for every worker task

- `docs/ARCHITECTURE.md` (attached) is the contract. Follow it exactly: paths,
  labels, variable names, file formats, menu keys, flags. Do not invent new ones.
- Output ONLY the raw contents of the single file you are asked to write. No
  markdown fences around the whole file, no explanations before or after.
- Write complete, working code. No placeholders, no "TODO", no "implement here",
  no pseudo-code, no elided sections.
- ASCII only in scripts (no Unicode box-drawing or emoji): the Linux text console
  and Windows PowerShell 5.1 (which reads BOM-less files as ANSI) must render
  them correctly. Markdown docs may use plain Unicode punctuation sparingly.
- Bash: target bash 5, `#!/usr/bin/env bash`, `set -uo pipefail` (use `-e` only
  in non-interactive build scripts), quote every expansion, use `[[ ]]`,
  `local` in functions, `readonly` for constants, functions named `snake_case`.
  Must pass `shellcheck -S warning`.
- PowerShell: must run on **Windows PowerShell 5.1** (the version built into
  Windows 10/11). Forbidden: `??`, `?.`, ternary `a ? b : c`, `&&`/`||` pipeline
  chains, `ConvertFrom-SecureString -AsPlainText`, `$IsWindows`, `-Parallel`,
  `Join-Path` with more than two positional paths, class-based enums. Use
  `Set-StrictMode -Version 2.0` and `$ErrorActionPreference = 'Stop'`, wrapping
  native-exe calls so a non-zero exit code is checked via `$LASTEXITCODE`.
- Secrets (passphrases, API keys, OAuth tokens, BitLocker recovery keys) must
  never be: echoed, logged, put on a command line, written outside the
  session/vault paths defined in the architecture, or left in shell variables
  longer than needed.
- Messages to the user are short, friendly, plain English, and say what to do next.
