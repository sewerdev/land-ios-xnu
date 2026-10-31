# Start qemu, wait for it, and make sure it is really gone at the deadline.
#
# This exists because the suite cannot use `timeout`: it kills the bash job and leaves
# qemu-system-aarch64.exe running, and a guest that reached its targets and then sat
# there hung the suite forever.  Arguments come from a file, one per line, because
# quoting them through bash into a PowerShell -Command string is how the earlier
# version of this lost the child exit code.
#
# It uses [Diagnostics.Process] rather than Start-Process for the same reason: the
# object Start-Process -PassThru hands back has an ExitCode that is simply empty, so
# every failed boot would be reported as a success.  The child inherits this console,
# so the caller's own redirection is what captures the guest's output.
#
# usage: runqemu.ps1 -Exe <path> -ArgsFile <path> -Ms <milliseconds>

param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$ArgsFile,
    [Parameter(Mandatory = $true)][int]$Ms
)

$ErrorActionPreference = 'Stop'

$lines = Get-Content -LiteralPath $ArgsFile
$list = @($lines | Where-Object { "$_".Length -gt 0 } | ForEach-Object { [string]$_ })

# An argument with a space in it is one argument, and the command line this API takes
# is a plain string, so the quoting has to be done by hand.  No argument here contains a
# quote character; qemu's own syntax (file=...,if=virtio) never needs one.
$quoted = $list | ForEach-Object {
    if ($_ -match '[ \t]') { '"' + $_ + '"' } else { $_ }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
$psi.Arguments = ($quoted -join ' ')
$psi.UseShellExecute = $false

$p = [System.Diagnostics.Process]::Start($psi)
if (-not $p.WaitForExit($Ms)) {
    $p.Kill()
}
$p.WaitForExit()
exit $p.ExitCode
