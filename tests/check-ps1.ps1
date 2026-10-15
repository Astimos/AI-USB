# Parse a .ps1 with pwsh and reject syntax/APIs that Windows PowerShell 5.1 lacks.
# Usage: pwsh -NoProfile -File tests/check-ps1.ps1 payload/aiusb/launcher/launcher.ps1
param([string]$Path)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { "PARSE: line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
# PS 5.1 forbidden syntax / APIs
$bad = @()
foreach ($t in $tokens) {
  if ($t.Kind -in 'QuestionQuestion','QuestionQuestionEquals','QuestionDot','QuestionLBracket','AndAnd','OrOr') { $bad += "line $($t.Extent.StartLineNumber): forbidden token $($t.Kind)" }
}
$ast.FindAll({ $args[0] -is [System.Management.Automation.Language.TernaryExpressionAst] -or $args[0] -is [System.Management.Automation.Language.PipelineChainAst] -or $args[0] -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true) | ForEach-Object { $bad += "line $($_.Extent.StartLineNumber): forbidden construct $($_.GetType().Name)" }
$ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and $args[0].VariablePath.UserPath -in 'IsWindows','IsLinux','IsMacOS','IsCoreCLR' }, $true) | ForEach-Object { $bad += "line $($_.Extent.StartLineNumber): PS7-only variable" }
$ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object {
  $n = $_.GetCommandName()
  $txt = $_.Extent.Text
  if ($n -eq 'ConvertFrom-SecureString' -and $txt -match '-AsPlainText') { $bad += "line $($_.Extent.StartLineNumber): ConvertFrom-SecureString -AsPlainText" }
  if ($n -eq 'ForEach-Object' -and $txt -match '-Parallel') { $bad += "line $($_.Extent.StartLineNumber): -Parallel" }
  if ($n -eq 'Join-Path') {
    $pos = @($_.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
    if ($pos.Count -gt 2) { $bad += "line $($_.Extent.StartLineNumber): Join-Path with $($pos.Count) paths" }
  }
}
$nonAscii = [System.IO.File]::ReadAllBytes($Path) | Where-Object { $_ -gt 127 } | Measure-Object | Select-Object -ExpandProperty Count
if ($nonAscii) { $bad += "non-ASCII bytes: $nonAscii" }
if ($bad.Count) { $bad; exit 1 } else { "OK: $Path parses and passes PS 5.1 checks" }
