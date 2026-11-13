@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "APP_DIR=%%~fI"
set "MANAGER_BAT=%~f0"
set "MANAGER_ACTION=%~1"
where pwsh.exe >nul 2>&1
if errorlevel 1 (
    if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
        echo [ERROR] PowerShell was not found.
        exit /b 1
    )
    set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
) else (
    set "POWERSHELL_EXE=pwsh.exe"
)
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $text=[IO.File]::ReadAllText($env:MANAGER_BAT, [Text.Encoding]::UTF8); $marker='POWERSHELL_PAYLOAD_BEGIN'; $index=$text.LastIndexOf($marker, [StringComparison]::Ordinal); if($index -lt 0){throw 'Embedded PowerShell payload was not found.'}; $code=$text.Substring($index+$marker.Length); & ([scriptblock]::Create($code)) -Action $env:MANAGER_ACTION -Root $env:APP_DIR; exit $LASTEXITCODE } catch { [Console]::Error.WriteLine('[ERROR] ' + $_.Exception.Message); exit 1 }"
if "%~1"=="" pause
exit /b %ERRORLEVEL%
POWERSHELL_PAYLOAD_BEGINparam([string]$Action, [Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = [IO.Path]::GetFullPath($Root)
if ($root.Length -gt 3 -and $root.EndsWith('\')) { $root = $root.TrimEnd('\') }
$dbFolder = Join-Path $root 'runtime\db'
$logFolder = Join-Path $root 'runtime\log'
$binFolder = Join-Path $root 'bin'
$dbPath = Join-Path $dbFolder 'x-ui.db'
$panel = Join-Path $root 'x-ui.exe'
$xray = Join-Path $binFolder 'xray-windows-amd64.exe'
$stateFile = Join-Path $root 'runtime\subport.current'
$logFile = Join-Path $logFolder '3xui.log'
$resetVersion = 'v2.9.5'
$versionFile = Join-Path $root 'version.txt'
if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
    $value = ([IO.File]::ReadAllText($versionFile)).Trim()
    if ($value) {
        if (-not $value.StartsWith('v')) { $value = "v$value" }
        $resetVersion = $value
    }
}
$releaseUrl = "https://github.com/CarterLeeAlt/3x-ui/releases/download/$resetVersion/x-ui-windows-amd64.zip"
$serviceName = '3x-ui'
$serviceExe = Join-Path $root 'x-ui-service.exe'
$defaultSubPort = 2196
$maxLogBytes = 20MB

function Get-InstanceProcesses {
    $paths = @($panel, $xray) | ForEach-Object { [IO.Path]::GetFullPath($_) }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='x-ui.exe' OR Name='xray-windows-amd64.exe'")) {
        if (-not $p.ExecutablePath) { throw "Cannot verify PID $($p.ProcessId); run as administrator." }
        if ($paths -contains [IO.Path]::GetFullPath($p.ExecutablePath)) { $p }
    }
}

function Assert-Install {
    foreach ($file in @($panel, $xray)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "缺少文件: $file" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\winsqlite3.dll'))) {
        throw '未找到 Windows SQLite 库。'
    }
}

function Initialize-Database {
    if (Test-Path -LiteralPath $dbPath -PathType Leaf) { Write-Host '  已找到现有数据库，保持不变。'; return }
    Write-Host '  未找到数据库，正在创建...'
    Push-Location $root
    try {
        $output = & $panel setting -show 2>&1
        if ($LASTEXITCODE -ne 0) { throw "创建数据库失败: $($output -join ' ')" }
    } finally { Pop-Location }
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { throw "数据库未生成: $dbPath" }
    Write-Host '  数据库已创建。'
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ManagerSqlite {
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_open16([MarshalAs(UnmanagedType.LPWStr)] string filename, out IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern int sqlite3_exec(IntPtr db, [MarshalAs(UnmanagedType.LPStr)] string sql, IntPtr callback, IntPtr arg, out IntPtr errmsg);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPStr)] string sql, int nByte, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void sqlite3_free(IntPtr p);
}
'@

function ConvertFrom-Utf8Pointer([IntPtr]$pointer) {
    if ($pointer -eq [IntPtr]::Zero) { return $null }
    $length = 0
    while ([Runtime.InteropServices.Marshal]::ReadByte($pointer, $length) -ne 0) { $length++ }
    $bytes = New-Object byte[] $length
    if ($length -gt 0) { [Runtime.InteropServices.Marshal]::Copy($pointer, $bytes, 0, $length) }
    [Text.Encoding]::UTF8.GetString($bytes)
}

function Open-Database {
    $handle = [IntPtr]::Zero
    $rc = [ManagerSqlite]::sqlite3_open16($dbPath, [ref]$handle)
    if ($rc -ne 0 -or $handle -eq [IntPtr]::Zero) { throw "Unable to open the SQLite database. SQLite code: $rc" }
    $handle
}

function Get-Setting([IntPtr]$handle, [string]$key) {
    $statement = [IntPtr]::Zero
    $safeKey = $key.Replace("'", "''")
    $rc = [ManagerSqlite]::sqlite3_prepare_v2($handle, "SELECT value FROM settings WHERE key='$safeKey' ORDER BY id DESC LIMIT 1;", -1, [ref]$statement, [IntPtr]::Zero)
    if ($rc -ne 0) { throw "Failed to prepare the query for '$key'. SQLite code: $rc" }
    try {
        $rc = [ManagerSqlite]::sqlite3_step($statement)
        if ($rc -eq 100) { return ConvertFrom-Utf8Pointer ([ManagerSqlite]::sqlite3_column_text($statement, 0)) }
        if ($rc -eq 101) { return $null }
        throw "Failed to read '$key'. SQLite code: $rc"
    } finally {
        if ($statement -ne [IntPtr]::Zero) { [void][ManagerSqlite]::sqlite3_finalize($statement) }
    }
}

function Invoke-Sql([IntPtr]$handle, [string]$sql) {
    $errorPointer = [IntPtr]::Zero
    $rc = [ManagerSqlite]::sqlite3_exec($handle, $sql, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$errorPointer)
    try {
        if ($rc -ne 0) {
            $message = ConvertFrom-Utf8Pointer $errorPointer
            if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Unknown SQLite error' }
            throw "SQLite error $rc`: $message"
        }
    } finally {
        if ($errorPointer -ne [IntPtr]::Zero) { [ManagerSqlite]::sqlite3_free($errorPointer) }
    }
}

function Get-Port([string]$value, [string]$name) {
    $port = 0
    if (-not [int]::TryParse($value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw "Invalid $name in database: $value" }
    $port
}

function Prepare-Runtime {
    [IO.Directory]::CreateDirectory($dbFolder) | Out-Null
    [IO.Directory]::CreateDirectory($logFolder) | Out-Null
    Initialize-Database
    $handle = Open-Database
    try {
        $subPort = Get-Setting $handle 'subPort'
        if (-not $subPort) {
            Invoke-Sql $handle "INSERT INTO settings (key, value) VALUES ('subPort', '$defaultSubPort');"
            $subPort = [string]$defaultSubPort
            Write-Host "  订阅端口缺失，已设为 $subPort"
        }
        $subPortNumber = Get-Port $subPort 'subPort'
        $webPortValue = Get-Setting $handle 'webPort'
        $webPort = if (-not $webPortValue) { 2053 } else { Get-Port $webPortValue 'webPort' }
        $webBasePath = Get-Setting $handle 'webBasePath'
        $webListen = Get-Setting $handle 'webListen'
    } finally { [void][ManagerSqlite]::sqlite3_close($handle) }
    [IO.File]::WriteAllText($stateFile, [string]$subPortNumber, [Text.Encoding]::ASCII)
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { @($webPort, $subPortNumber) -contains $_.LocalPort })
    if ($listeners.Count) {
        $details = ($listeners | Sort-Object LocalPort, OwningProcess -Unique | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort) (PID $($_.OwningProcess))" }) -join ', '
        throw "所需端口已被占用: $details"
    }
    if (-not $webBasePath) { $webBasePath = '/' } elseif (-not $webBasePath.StartsWith('/')) { $webBasePath = "/$webBasePath" }
    if (-not $webBasePath.EndsWith('/')) { $webBasePath = "$webBasePath/" }
    if ($webListen -in @('::', '[::]', '0.0.0.0')) {
        Write-Warning '当前监听地址可能把面板暴露到其他网络接口，请检查 Windows 防火墙和面板密码。'
    }
}

function Rotate-Log {
    if (-not (Test-Path -LiteralPath $logFile -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $logFile).Length -lt $maxLogBytes) { return }
    $oldest = "$logFile.3"
    if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force }
    foreach ($pair in @(@("$logFile.2", "$logFile.3"), @("$logFile.1", "$logFile.2"), @($logFile, "$logFile.1"))) {
        if (Test-Path -LiteralPath $pair[0]) { Move-Item -LiteralPath $pair[0] -Destination $pair[1] -Force }
    }
    Write-Host "[OK] 日志超过 20 MB，已轮转: $logFile.1"
}

function Write-Title([string]$text) {
    Write-Host ''
    Write-Host ('=' * 60)
    Write-Host "  $text"
    Write-Host ('=' * 60)
}

function Write-Separator {
    Write-Host ('-' * 60)
}

function Get-WebAddress {
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { return $null }
    $handle = Open-Database
    try {
        $port = Get-Setting $handle 'webPort'
        $base = Get-Setting $handle 'webBasePath'
    } finally { [void][ManagerSqlite]::sqlite3_close($handle) }
    if (-not $port) { $port = '2053' }
    if (-not $base) { $base = '/' } elseif (-not $base.StartsWith('/')) { $base = "/$base" }
    if (-not $base.EndsWith('/')) { $base = "$base/" }
    "http://127.0.0.1:$port$base"
}

function Get-ServiceText {
    $state = Get-ServiceState
    if (-not $state) { return '未安装' }
    switch ($state) {
        'Running' { '已安装，运行中' }
        'Stopped' { '已安装，已停止' }
        default { "已安装，$state" }
    }
}

function Status {
    $processes = @(Get-InstanceProcesses)
    Write-Title '运行状态'
    foreach ($entry in @(@('面板进程', 'x-ui.exe'), @('Xray 进程', 'xray-windows-amd64.exe'))) {
        $found = @($processes | Where-Object Name -eq $entry[1])
        if ($found.Count) { Write-Host "  $($entry[0]): 运行中 (PID $(($found.ProcessId) -join ', '))" }
        else { Write-Host "  $($entry[0]): 已停止" }
    }
    Write-Host "  服务状态: $(Get-ServiceText)"
    Write-Separator
    Write-Host "  数据库: $dbPath"
    $address = Get-WebAddress
    if ($address) { Write-Host "  面板地址: $address" }
    if (Test-Path -LiteralPath $stateFile) { Write-Host "  订阅端口: $([IO.File]::ReadAllText($stateFile))" }
    Write-Host ('=' * 60)
}

function Start-Panel {
    Assert-Install
    if (@(Get-InstanceProcesses).Count) { throw '本目录的实例已在运行。' }
    $env:XUI_DB_FOLDER = $dbFolder
    $env:XUI_LOG_FOLDER = $logFolder
    $env:XUI_BIN_FOLDER = $binFolder
    $env:XUI_DEBUG = 'false'
    $env:XUI_LOG_LEVEL = 'info'
    $env:XUI_DEFAULT_SUB_PORT = [string]$defaultSubPort
    Prepare-Runtime
    Rotate-Log
    Write-Host '  正在启动...'
    $out = Join-Path $logFolder 'manager-start.log'
    $err = Join-Path $logFolder 'manager-start-error.log'
    Start-Process -FilePath $panel -ArgumentList 'run' -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null
    Start-Sleep -Seconds 4
    if (-not @(Get-InstanceProcesses | Where-Object Name -eq 'x-ui.exe').Count) { throw "启动失败，请查看 $out 和 $err。" }
    Status
}

function Stop-Panel {
    $items = @(Get-InstanceProcesses)
    if (-not $items.Count) { Write-Host '  面板与 Xray 未在运行。'; return }
    foreach ($item in @($items | Sort-Object { if ($_.Name -eq 'x-ui.exe') { 0 } else { 1 } })) {
        if (-not (Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue)) { continue }
        & taskkill.exe /PID $item.ProcessId *> $null
        Start-Sleep -Seconds 2
        if (@(Get-InstanceProcesses | Where-Object ProcessId -eq $item.ProcessId).Count) {
            Write-Warning "PID $($item.ProcessId) 无法正常关闭，改为强制终止。"
            Stop-Process -Id $item.ProcessId -Force -ErrorAction Stop
        }
    }
    Start-Sleep -Seconds 2
    if (@(Get-InstanceProcesses).Count) { throw '仍有进程在运行。' }
    Write-Host '  面板与 Xray 已停止。'
}

function Remove-ToRecycleBin([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a path outside the installation: $full"
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($full, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($full, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    }
}

function Reset-Panel {
    Write-Warning "将恢复 $resetVersion 并删除全部本地数据，包括账户、设置、日志、证书和本目录其他文件。"
    if ($env:XUI_CONFIRM -cne 'RESET') {
        if ((Read-Host '  输入 RESET 继续') -cne 'RESET') { Write-Host '  已取消。'; return }
    }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $state = Get-ServiceState
    if ($state -and $state -ne 'Stopped') { Stop-Service -Name $serviceName -Force; Start-Sleep -Seconds 3 }
    $stage = Join-Path $root '.x-ui-reset-staging'
    if (Test-Path -LiteralPath $stage) { throw "Staging directory already exists: $stage" }
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        $zip = Join-Path $stage 'release.zip'
        & curl.exe --fail --location --output $zip $releaseUrl
        if ($LASTEXITCODE -ne 0) { throw '下载失败，本地安装未做任何改动。' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try { foreach ($entry in $archive.Entries) { $n = $entry.FullName.Replace('\', '/'); if ($n.StartsWith('/') -or $n -match '(^|/)\.\.(/|$)' -or $n -match '^[a-zA-Z]:') { throw "Unsafe archive path: $n" } } } finally { $archive.Dispose() }
        Expand-Archive -LiteralPath $zip -DestinationPath $stage
        $source = Join-Path $stage 'x-ui'
        foreach ($name in @('x-ui.exe', 'bin\xray-windows-amd64.exe', 'bin\geoip.dat', 'bin\geosite.dat')) {
            if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { throw "发布包缺少文件: $name" }
        }
        Stop-Panel
        $keep = @('x-ui-manager.bat', 'x-ui-service.exe', '.x-ui-reset-staging')
        $items = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -notin $keep })
        foreach ($item in $items) { Remove-ToRecycleBin $item.FullName }
        Copy-Item -Path (Join-Path $source '*') -Destination $root -Recurse -Force
        Write-Host "  已恢复 $resetVersion，面板保持停止状态。"
    } finally {
        if (Test-Path -LiteralPath $stage) {
            try { Remove-ToRecycleBin $stage } catch { Write-Warning "Staging cleanup failed: $stage" }
        }
    }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ServiceState {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $service = Get-Service -Name $serviceName
    $ErrorActionPreference = $previous
    if (-not $service) { return $null }
    $service.Status
}

function Service-Status {
    $state = Get-ServiceState
    if (-not $state) { Write-Host "  服务 '$serviceName' 未安装。"; return }
    Write-Host "  服务 '$serviceName': $(Get-ServiceText)"
}

function Service-Install {
    if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) { throw "缺少文件: $serviceExe" }
    if (-not (Test-Admin)) { throw '安装服务需要管理员权限。' }
    if (Get-ServiceState) { throw "服务 '$serviceName' 已安装。" }
    New-Service -Name $serviceName -BinaryPathName $serviceExe -DisplayName '3x-ui' -Description '3x-ui panel and Xray core' -StartupType Automatic | Out-Null
    $user = "$env:USERDOMAIN\$env:USERNAME"
    & icacls.exe $root /grant "${user}:(OI)(CI)F" /T /C | Out-Null
    Start-Service -Name $serviceName
    Start-Sleep -Seconds 3
    if ((Get-ServiceState) -ne 'Running') { throw '服务已安装但未能进入运行状态，请查看 runtime\log\service.log。' }
    Write-Host "  服务 '$serviceName' 已安装并启动。"
}

function Service-Remove {
    if (-not (Test-Admin)) { throw '卸载服务需要管理员权限。' }
    $state = Get-ServiceState
    if (-not $state) { throw "服务 '$serviceName' 未安装。" }
    if ($state -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force
        Start-Sleep -Seconds 3
    }
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "删除服务 '$serviceName' 失败。" }
    Write-Host "  服务 '$serviceName' 已卸载。"
}

function Prepare-Only {
    Assert-Install
    if (@(Get-InstanceProcesses).Count) { throw '本目录的实例已在运行。' }
    $env:XUI_DB_FOLDER = $dbFolder
    $env:XUI_LOG_FOLDER = $logFolder
    $env:XUI_BIN_FOLDER = $binFolder
    $env:XUI_DEBUG = 'false'
    $env:XUI_LOG_LEVEL = 'info'
    $env:XUI_DEFAULT_SUB_PORT = [string]$defaultSubPort
    Prepare-Runtime
    Rotate-Log
}

function Run-Action([string]$name) {
    switch ($name.ToLowerInvariant()) {
        'start' { Start-Panel }
        'stop' { Stop-Panel }
        'status' { Status }
        'reset' { Reset-Panel }
        'prepare' { Prepare-Only }
        'service-install' { Service-Install }
        'service-remove' { Service-Remove }
        'service-status' { Service-Status }
        default { throw '用法: x-ui-manager.bat [start|stop|status|reset|service-install|service-remove|service-status]' }
    }
}

try {
    if ($Action) { Run-Action $Action; exit 0 }
    do {
        Write-Title '3x-ui 管理器'
        Write-Host '  1) 启动面板'
        Write-Host '  2) 停止面板'
        Write-Host '  3) 查看状态'
        Write-Host "  4) 恢复默认（重装 $resetVersion）"
        Write-Separator
        Write-Host '  5) 安装 Windows 服务'
        Write-Host '  6) 卸载 Windows 服务'
        Write-Host '  7) 查看服务状态'
        Write-Separator
        Write-Host '  0) 退出'
        $selection = Read-Host '  请选择'
        try {
            switch ($selection) {
                '1' { Run-Action 'start' }
                '2' { Run-Action 'stop' }
                '3' { Run-Action 'status' }
                '4' { Run-Action 'reset' }
                '5' { Run-Action 'service-install' }
                '6' { Run-Action 'service-remove' }
                '7' { Run-Action 'service-status' }
                '0' { }
                default { Write-Host '  无效选项。' }
            }
        } catch { Write-Host "  错误: $($_.Exception.Message)" }
    } while ($selection -ne '0')
    exit 0
} catch { [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)"); exit 1 }
