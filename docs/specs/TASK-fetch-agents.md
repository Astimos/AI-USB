# Task: write `scripts/fetch-agents.sh`

Builds the complete data-partition tree in `build/payload/` (= `$USB` of ARCHITECTURE §3) on the
developer machine (Arch/CachyOS, normal user, NO root). Bash, `set -euo pipefail`.

## Usage
`scripts/fetch-agents.sh [--claude-channel stable|latest] [--clean]`
Repo root = parent of the script dir. `CACHE=build/cache/downloads`, `OUT=build/payload`.
`--clean` removes `$OUT` first (guard: path must end with `/build/payload`).

## Steps (each prints a one-line progress message; downloads are cached by file name in $CACHE;
use `curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url" && mv "$tmp" "$final"`)
1. Copy the repo's `payload/` tree into `$OUT` with `cp -r payload/. "$OUT"/` (create dirs
   `$OUT/aiusb/{bin/linux-x64,bin/win-x64,gemini,vault,workspace,logs,backups}`).
2. Claude Code: base `https://downloads.claude.ai/claude-code-releases`; version =
   `curl -fsSL $base/<channel>` (default channel `stable`); manifest `$base/$ver/manifest.json`.
   If `gpg` exists: download `manifest.json.sig` and verify against the key
   `https://downloads.claude.ai/keys/claude-code.asc` imported into a temporary GNUPGHOME
   (mktemp -d, removed on exit); require fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`
   (check with `gpg --with-colons --fingerprint`), then `gpg --verify`. Fail hard on a bad signature.
   Download `$base/$ver/linux-x64/claude` and `$base/$ver/win32-x64/claude.exe`; verify each
   SHA-256 against `.platforms["linux-x64"].checksum` / `.platforms["win32-x64"].checksum`
   (use `python3 -c` to read JSON; jq may be missing). Install to `bin/linux-x64/claude` (chmod 755)
   and `bin/win-x64/claude.exe`.
3. Codex: `https://api.github.com/repos/openai/codex/releases/latest` (python3 for JSON).
   Assets `codex-x86_64-unknown-linux-musl.tar.gz` and `codex-x86_64-pc-windows-msvc.exe.zip`.
   If the asset JSON has a `digest` field like `sha256:<hex>`, verify it. Extract (tar / `unzip -o`
   or `bsdtar`) into a temp dir; the single binary inside is renamed to `codex` (chmod 755) /
   `codex.exe`.
4. age: `https://api.github.com/repos/FiloSottile/age/releases/latest`; assets
   `age-<tag>-linux-amd64.tar.gz` and `age-<tag>-windows-amd64.zip`; verify `digest` if present;
   they contain `age/age`, `age/age-keygen` and `age/age.exe`, `age/age-keygen.exe`.
5. Node.js: newest LTS from `https://nodejs.org/dist/index.json` (first entry whose `lts` is not
   false). Download `node-<v>-linux-x64.tar.xz`, `node-<v>-win-x64.zip` and `SHASUMS256.txt` from
   `https://nodejs.org/dist/<v>/`; verify both. Extract to `bin/linux-x64/node/` (strip the top dir:
   contents `bin/ lib/ include/ share/`) and `bin/win-x64/node/` (contents `node.exe`, `npm.cmd`, ...).
   Remove `include/`, `share/doc`, `share/man` from the Linux copy to save space.
6. Gemini CLI: with the downloaded Linux node (prepend `bin/linux-x64/node/bin` to PATH; set
   `npm_config_cache="$CACHE/npm"`), run
   `npm install --prefix "$OUT/aiusb/gemini" --no-audit --no-fund --omit=dev @google/gemini-cli@latest`.
   Read the installed `@lydell/node-pty` version from
   `$OUT/aiusb/gemini/node_modules/@lydell/node-pty/package.json` (if present) and add the Windows
   prebuild: `npm install --prefix "$OUT/aiusb/gemini" --no-save --no-audit --no-fund --force --os=win32 --cpu=x64 "@lydell/node-pty-win32-x64@<that version>"`.
   Then make sure `node_modules/@lydell/node-pty-linux-x64` still exists (re-install it the same way
   with `--os=linux` if npm pruned it). Delete `node_modules/@github/keytar` and `node_modules/keytar`
   if present (forces file storage, no OS keychain). Verify
   `node_modules/@google/gemini-cli/bundle/gemini.js` exists and `node gemini.js --version` prints a version.
7. Write `$OUT/aiusb/VERSION`: build date (UTC ISO), and one line per component with its version.
8. Print a summary table (component, version, size) and the total size (`du -sh "$OUT"`).

Exit non-zero with a clear message on any failure. No root. Must pass `shellcheck -S warning`.
