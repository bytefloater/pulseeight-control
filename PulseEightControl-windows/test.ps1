<#
.SYNOPSIS
  Runs the Windows app's tests: builds the core and the fake matrix, then runs Core.Tests
  (end to end, through the real library against p8fake).

.EXAMPLE
  .\PulseEightControl-windows\test.ps1
#>
. (Join-Path $PSScriptRoot 'common.ps1')

# The tests load the staged core, so make sure it is current.
& (Join-Path $PSScriptRoot 'build.ps1')

Write-Host '== Building the fake matrix (p8fake)'
Invoke-Native swift build --package-path (Join-Path $root 'PulseEightFakeServer') --scratch-path (Join-Path $out 'fake') --product p8fake
if ($LASTEXITCODE -ne 0) { throw 'swift build (p8fake) failed' }

Write-Host '== Running Core.Tests'
$env:P8_CORE_LIBRARY = Join-Path $native 'pulseeight_core.dll'
Invoke-Native dotnet test (Join-Path $PSScriptRoot 'Core.Tests') "-p:Platform=$platform"
if ($LASTEXITCODE -ne 0) { throw 'tests failed' }
