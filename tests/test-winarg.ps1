# Round-trip test of ConvertTo-WinArg against a CommandLineToArgvW-style parser.
# Usage (from the repo root): pwsh -NoProfile -File tests/test-winarg.ps1
$src = Get-Content -Raw payload/aiusb/launcher/launcher.ps1
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'ConvertTo-WinArg' }, $true)[0]
Invoke-Expression $fn.Extent.Text
# reference: CommandLineToArgvW-style parse (MSVCRT rules) to round-trip
function Split-WinArgs([string]$cmd) {
  $out = @(); $i = 0; $n = $cmd.Length
  while ($i -lt $n) {
    while ($i -lt $n -and ($cmd[$i] -eq ' ' -or $cmd[$i] -eq "`t")) { $i++ }
    if ($i -ge $n) { break }
    $sb = New-Object System.Text.StringBuilder; $inq = $false
    while ($i -lt $n) {
      $c = $cmd[$i]
      if (($c -eq ' ' -or $c -eq "`t") -and -not $inq) { break }
      if ($c -eq '\') {
        $bs = 0; while ($i -lt $n -and $cmd[$i] -eq '\') { $bs++; $i++ }
        if ($i -lt $n -and $cmd[$i] -eq '"') {
          [void]$sb.Append('\' * [math]::Floor($bs/2))
          if ($bs % 2 -eq 1) { [void]$sb.Append('"'); $i++ }
        } else { [void]$sb.Append('\' * $bs) }
        continue
      }
      if ($c -eq '"') { $inq = -not $inq; $i++; continue }
      [void]$sb.Append($c); $i++
    }
    $out += $sb.ToString()
  }
  ,$out
}
$cases = @('C:\', 'C:\My Dir\', '', 'plain', 'a b', 'say "hi"', 'x\"y', 'C:\a b\\', 'tab	here', '\\server\share\', 'E:\,C:\')
$fail = 0
foreach ($c in $cases) {
  $q = ConvertTo-WinArg $c
  $back = Split-WinArgs ("exe " + $q)
  if ($back.Count -ne 2 -or $back[1] -cne $c) { "FAIL [$c] -> [$q] -> [$($back -join '|')]"; $fail++ } else { "ok   [$c] -> [$q]" }
}
if ((ConvertTo-WinArg 'C:\My Dir\') -cne '"C:\My Dir\\"') { 'FAIL spec example'; $fail++ }
exit $fail
