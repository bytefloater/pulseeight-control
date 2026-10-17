# Shared by build.ps1 and test.ps1 (dot-sourced).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'out'
$platform = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
$native = Join-Path $out "native\$platform"

# Run a native tool and judge it by its exit code. Under $ErrorActionPreference = Stop, Windows
# PowerShell 5.1 turns any stderr output (Swift prints harmless warnings on a fresh build) into a
# terminating error.
function Invoke-Native {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $args[0] $args[1..($args.Count - 1)] } finally { $ErrorActionPreference = $previous }
}
