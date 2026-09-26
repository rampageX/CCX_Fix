#requires -version 5.1
param([string]$InstallStage)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ScriptDir = $PSScriptRoot
$TargetRoot = Join-Path ${env:ProgramFiles} 'Common Files\Adobe\UXP\Plugins\External'
$MaxEntries = 20000
$MaxBytes = 2GB
$MaxFileBytes = 512MB
function Full([string]$p) { return [IO.Path]::GetFullPath($p).TrimEnd('\') }
function Assert-Child([string]$parent,[string]$child) {
    $a = Full $parent; $b = Full $child
    if (-not $b.StartsWith($a + '\',[StringComparison]::OrdinalIgnoreCase)) { throw "Path outside expected root: $b" }
}
function Assert-NoLinks([string]$path) {
    $p = Full $path
    while ($p -and [IO.Directory]::Exists($p)) {
        if (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point in path: $p" }
        $next = [IO.Path]::GetDirectoryName($p)
        if (-not $next -or $next -eq $p) { break }; $p = $next
    }
}
function Read-Manifest([string]$root) {
    $p = Join-Path $root 'manifest.json'
    if (-not [IO.File]::Exists($p)) { throw 'manifest.json must be at the CCX root' }
    $raw = [IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)
    $m = ConvertFrom-Json -InputObject $raw
    if ($null -eq $m -or $m -is [array]) { throw 'Invalid manifest object' }
    $id = [string]$m.id; $version = [string]$m.version
    if ($id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or $id -match '\.\.' -or $id.EndsWith('.')) { throw 'Invalid plugin ID' }
    if ($version -cnotmatch '^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9]+)*$' -or $version.Length -gt 64) { throw 'Invalid version' }
    $hosts = @()
    if ($null -ne $m.host) { $hosts += @($m.host) }
    if ($null -ne $m.hosts) { $hosts += @($m.hosts) }
    if ($hosts.Count -eq 0 -or @($hosts | Where-Object { $_ -isnot [pscustomobject] -or [string]$_.app -cne 'PS' }).Count -ne 0) { throw 'Only Photoshop UXP Host=PS is supported' }
    return [pscustomobject]@{ Id=$id; Version=$version; Name=[string]$m.name; Directory=$root }
}
function Assert-Tree([string]$root) {
    Assert-NoLinks $root
    foreach ($entry in (Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        Assert-Child $root $entry.FullName
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Link in staging tree: $($entry.FullName)" }
    }
}
function Extract-Safe([string]$archive,[string]$dest) {
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        if ($zip.Entries.Count -gt $MaxEntries) { throw 'Too many ZIP entries' }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $files = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $dirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$total = 0
        foreach ($e in $zip.Entries) {
            $n = $e.FullName.Replace('/','\')
            if (-not $n -or $n.StartsWith('\') -or $n -match '^[A-Za-z]:' -or $n.Contains(':')) { throw "Unsafe ZIP path: $n" }
            $isDir = $n.EndsWith('\'); $segments = @($n.TrimEnd('\').Split('\'))
            if ($segments.Count -eq 0 -or @($segments | Where-Object { -not $_ -or $_ -eq '.' -or $_ -eq '..' -or $_.EndsWith('.') -or $_.EndsWith(' ') -or $_ -match '[<>|?*\x00-\x1f]' -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' }).Count) { throw "Unsafe ZIP path: $n" }
            $key = $n.TrimEnd('\')
            if (-not $seen.Add($key)) { throw "Duplicate ZIP path: $n" }
            $mode = ($e.ExternalAttributes -shr 16) -band 0xF000
            if ($mode -ne 0 -and $mode -ne 0x8000 -and $mode -ne 0x4000) { throw "ZIP link or special file: $n" }
            if (($e.ExternalAttributes -band 0x400) -ne 0) { throw "ZIP reparse point: $n" }
            if ($isDir -and ($e.Length -ne 0 -or $mode -eq 0x8000)) { throw "Invalid directory entry: $n" }
            if (-not $isDir -and $mode -eq 0x4000) { throw "Invalid ZIP entry: $n" }
            $target = [IO.Path]::GetFullPath((Join-Path $dest $key)); Assert-Child $dest $target
            if ($isDir) { [void]$dirs.Add($key) } else {
                [void]$files.Add($key)
                if ($e.Length -gt $MaxFileBytes) { throw "File too large: $n" }
                $total += $e.Length; if ($total -gt $MaxBytes) { throw 'ZIP exceeds size limit' }
            }
        }
        foreach ($key in $seen) {
            $parts = $key.Split('\'); $prefix = ''
            for ($j=0; $j -lt $parts.Length-1; $j++) {
                $prefix = if ($prefix) { $prefix + '\' + $parts[$j] } else { $parts[$j] }
                if ($files.Contains($prefix)) { throw "File is also a parent directory: $prefix" }
            }
            if ($dirs.Contains($key) -and $files.Contains($key)) { throw "File and directory conflict: $key" }
        }
        [IO.Directory]::CreateDirectory($dest) | Out-Null
        foreach ($e in $zip.Entries) {
            $key = $e.FullName.Replace('/','\').TrimEnd('\'); $target = [IO.Path]::GetFullPath((Join-Path $dest $key))
            if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { [IO.Directory]::CreateDirectory($target) | Out-Null; continue }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            $inputStream = $e.Open(); $outputStream = [IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
            try {
                $buffer = New-Object byte[] 65536; [long]$written = 0
                while (($count = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $written += $count; if ($written -gt $MaxFileBytes -or $written -gt $e.Length) { throw 'ZIP length mismatch' }
                    $outputStream.Write($buffer,0,$count)
                }
                if ($written -ne $e.Length) { throw 'ZIP length mismatch' }
            } finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
    } finally { $zip.Dispose() }
    Assert-Tree $dest
    return Read-Manifest $dest
}
function Get-Destination($info) {
    $name = $info.Id + '_' + $info.Version
    $p = [IO.Path]::GetFullPath((Join-Path $TargetRoot $name))
    Assert-Child $TargetRoot $p
    return $p
}
function Install-Stage([string]$stage) {
    $stage = Full $stage
    Assert-NoLinks $stage
    $root = Full $TargetRoot
    Assert-NoLinks $root
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Assert-NoLinks $root
    $success = 0; $fail = 0
    foreach ($pkg in (Get-ChildItem -LiteralPath $stage -Directory)) {
        $temp = $null
        try {
            Assert-Tree $pkg.FullName
            $info = Read-Manifest $pkg.FullName
            $target = Get-Destination $info
            if ([IO.Directory]::Exists($target) -or [IO.File]::Exists($target)) { throw "Target already exists: $target" }
            $temp = Join-Path $root ('.ccx-install-' + [guid]::NewGuid().ToString('N'))
            Assert-Child $root $temp
            [IO.Directory]::CreateDirectory($temp) | Out-Null
            foreach ($entry in (Get-ChildItem -LiteralPath $pkg.FullName -Force)) { Copy-Item -LiteralPath $entry.FullName -Destination $temp -Recurse -ErrorAction Stop }
            Assert-Tree $temp
            $again = Read-Manifest $temp
            if ($again.Id -cne $info.Id -or $again.Version -cne $info.Version -or (Get-Destination $again) -ine $target) { throw 'Manifest changed during copy' }
            Assert-NoLinks $root
            if ([IO.Directory]::Exists($target) -or [IO.File]::Exists($target)) { throw "Target already exists: $target" }
            [IO.Directory]::Move($temp,$target); $temp = $null
            Write-Host "[OK] $target"; $success++
        } catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; $fail++ }
        finally { if ($temp -and [IO.Directory]::Exists($temp)) { Remove-Item -LiteralPath $temp -Recurse -Force } }
    }
    Write-Host "Installed: $success; failed: $fail"
    if ($fail) { return 30 }; return 0
}
if ($InstallStage) {
    try { exit (Install-Stage $InstallStage) }
    catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; exit 30 }
}
$work = Join-Path $env:TEMP ('CCX_UXP_' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $stage = Join-Path $work 'stage'; [IO.Directory]::CreateDirectory($stage) | Out-Null
    $ccx = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in (Get-ChildItem -LiteralPath $ScriptDir -Filter '*.ccx' -File)) { $ccx[$f.FullName] = $f.FullName }
    $es = Get-Command es.exe -ErrorAction SilentlyContinue
    if ($es) {
        try { foreach ($line in (& $es.Source -timeout 5000 -a-d 'ext:ccx' 2>$null)) {
            if ($line -and [IO.File]::Exists($line) -and [IO.Path]::GetExtension($line) -ieq '.ccx') { $ccx[[IO.Path]::GetFullPath($line)] = $line }
        } } catch { Write-Host 'Everything ES search failed.' }
    }
    if ($env:CCX_ENABLE_SYSTEM_SEARCH -eq '1') {
        foreach ($folder in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:LOCALAPPDATA,$env:APPDATA)) {
            if ($folder -and [IO.Directory]::Exists($folder)) {
                foreach ($f in (Get-ChildItem -LiteralPath $folder -Filter '*.ccx' -File -Recurse -ErrorAction SilentlyContinue)) { $ccx[$f.FullName] = $f.FullName }
            }
        }
    }
    if (-not $ccx.Count) { Write-Host 'No CCX found. Place CCX files beside Install_CCX.bat and retry.'; exit 0 }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $index = 0
    foreach ($file in ($ccx.Values | Sort-Object)) {
        $index++; $pkg = Join-Path $stage ('pkg_' + $index)
        try {
            Write-Host "Inspecting: $file"
            $info = Extract-Safe $file $pkg
            $key = $info.Id + '|' + $info.Version
            $target = Get-Destination $info
            if (-not $seen.Add($key)) { Write-Host 'Duplicate ID and version; skipped.'; Remove-Item -LiteralPath $pkg -Recurse -Force; continue }
            if ([IO.Directory]::Exists($target) -or [IO.File]::Exists($target)) { Write-Host "Already exists: $target"; Remove-Item -LiteralPath $pkg -Recurse -Force; continue }
            Write-Host "Ready: $($info.Id) $($info.Version) Host=PS => $target"
        } catch { Write-Host "Rejected: $($_.Exception.Message)" -ForegroundColor Yellow; if ([IO.Directory]::Exists($pkg)) { Remove-Item -LiteralPath $pkg -Recurse -Force } }
    }
    $ready = @(Get-ChildItem -LiteralPath $stage -Directory)
    if (-not $ready.Count) { Write-Host 'Nothing to install.'; exit 0 }
    $answer = Read-Host "Install $($ready.Count) package(s)? Type Y to confirm"
    if ($answer -cne 'Y') { Write-Host 'Cancelled.'; exit 0 }
    $exe = Join-Path $PSHOME 'powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath.Replace('"','') + '" -InstallStage "' + $stage.Replace('"','') + '"'
    try {
        $process = Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        exit $process.ExitCode
    } catch { Write-Host "UAC cancelled or installation failed: $($_.Exception.Message)" -ForegroundColor Red; exit 30 }
} catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; exit 30 }
finally { if ([IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } }
