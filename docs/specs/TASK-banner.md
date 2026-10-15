# Task: write `payload/aiusb/launcher/banner.txt` (the stick's ASCII-art logo)

One plain-text file, shown at the top of every launcher screen: by `launcher.sh` (Linux host and
rescue mode), `launcher.ps1` (Windows PowerShell 5.1 console) and `rescue-session.sh` (Linux text
console and the foot terminal). The scripts print the file as-is (and may colour it), so the file
itself is the whole deliverable.

## Content
1. The word **AISTiUSB** in large block letters, exactly that spelling and case: capital A, I, S,
   T, then a **lowercase i**, then capital U, S, B. The lowercase i must look clearly smaller /
   lowercase (dot on top, shorter stem) next to the capitals.
   Style: like figlet's "standard" or "big" font: letters drawn with `_ | / \ ( ) . ' ` and similar
   ASCII characters. Every letter must be clearly readable; the two S letters must be identical.
2. One empty line.
3. A tagline line, centred under the logo: `portable AI repair kit`

## Hard rules
- ASCII only: bytes 0x20-0x7E plus newline. No tabs, no Unicode, no box-drawing characters.
- At most 72 columns per line (the rescue text console is 80 columns wide). Logo 5 to 7 lines tall.
- No trailing spaces on any line. LF line endings. File ends with a single newline.
- No leading empty line.
- Output ONLY the raw file contents. No fences, no explanation.
