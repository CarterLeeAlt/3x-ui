@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions DisableDelayedExpansion
for %%I in ("%~dp0.") do set "APP_DIR=%%~fI"
set "MANAGER_BAT=%~f0"
set "MANAGER_ACTION=%~1"
if /i "%~1"=="reset" if "%~2"=="confirmed" set "XUI_CONFIRM=RESET"
where pwsh.exe >nul 2>&1
if errorlevel 1 (
    if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
        echo [错误] 未找到 PowerShell。
        exit /b 1
    )
    set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
) else (
    set "POWERSHELL_EXE=pwsh.exe"
)
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $text=[IO.File]::ReadAllText($env:MANAGER_BAT, [Text.Encoding]::UTF8); $marker='POWERSHELL_PAYLOAD_BEGIN'; $index=$text.LastIndexOf($marker, [StringComparison]::Ordinal); if($index -lt 0){throw '脚本内容不完整。'}; $code=$text.Substring($index+$marker.Length); & ([scriptblock]::Create($code)) -Action $env:MANAGER_ACTION -Root $env:APP_DIR; exit $LASTEXITCODE } catch { [Console]::Error.WriteLine('[错误] ' + $_.Exception.Message); exit 1 }"
set "MANAGER_EXIT=%ERRORLEVEL%"
if "%~1"=="" if not "%MANAGER_EXIT%"=="0" (
    echo 按任意键退出...
    pause >nul
)
exit /b %MANAGER_EXIT%
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
$defaultSubPort = 2196
$serviceName = '3x-ui'
$serviceExe = Join-Path $root 'x-ui-service.exe'
$displayVersions = @{}

function Get-PackageVersion([string]$Directory) {
    $executable = Join-Path $Directory 'x-ui.exe'
    $output = & $executable -v
    if ($LASTEXITCODE -ne 0) { throw "读取程序版本失败（退出码 $LASTEXITCODE）: $executable" }
    $version = ($output -join "`n").Trim()
    if ($version -notmatch '^v?\d+\.\d+\.\d+$') { throw "程序返回的版本号无效: $version" }
    'v' + $version.TrimStart('v')
}

function Set-RuntimeEnvironment {
    if ($env:XUI_DB_TYPE -and $env:XUI_DB_TYPE -ne 'sqlite') { throw '便携管理器仅管理本地 SQLite 数据库。' }
    $env:XUI_DB_FOLDER = $dbFolder
    $env:XUI_LOG_FOLDER = $logFolder
    $env:XUI_BIN_FOLDER = $binFolder
    $env:XUI_DEBUG = 'false'
    $env:XUI_LOG_LEVEL = 'info'
}
Set-RuntimeEnvironment

function Get-InstanceProcesses {
    $paths = @($panel, $xray) | ForEach-Object { [IO.Path]::GetFullPath($_) }
    $items = @(Get-CimInstance Win32_Process -Filter "Name='x-ui.exe' OR Name='xray-windows-amd64.exe'")
    $service = Get-OwnedService
    $panelPids = @($items | Where-Object {
        $_.Name -eq 'x-ui.exe' -and (($_.ExecutablePath -and $paths -contains [IO.Path]::GetFullPath($_.ExecutablePath)) -or ($service -and $service.ProcessId -gt 0 -and $_.ParentProcessId -eq $service.ProcessId))
    } | ForEach-Object ProcessId)
    foreach ($p in $items) {
        $knownPath = $p.ExecutablePath -and $paths -contains [IO.Path]::GetFullPath($p.ExecutablePath)
        if ($knownPath -or $panelPids -contains $p.ProcessId -or ($p.Name -eq 'xray-windows-amd64.exe' -and $panelPids -contains $p.ParentProcessId)) { $p }
    }
}

function Assert-Install {
    foreach ($file in @($panel, $xray)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "缺少文件: $file" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\winsqlite3.dll'))) { throw '未找到 Windows SQLite 库。' }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ManagerSqlite {
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int sqlite3_open16([MarshalAs(UnmanagedType.LPWStr)] string filename, out IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
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
    public static extern int sqlite3_exec(IntPtr db, [MarshalAs(UnmanagedType.LPStr)] string sql, IntPtr callback, IntPtr arg, out IntPtr errmsg);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void sqlite3_free(IntPtr p);
}
'@

function ConvertFrom-Utf8Pointer([IntPtr]$Pointer) {
    if ($Pointer -eq [IntPtr]::Zero) { return $null }
    $length = 0
    while ([Runtime.InteropServices.Marshal]::ReadByte($Pointer, $length) -ne 0) { $length++ }
    $bytes = New-Object byte[] $length
    if ($length) { [Runtime.InteropServices.Marshal]::Copy($Pointer, $bytes, 0, $length) }
    [Text.Encoding]::UTF8.GetString($bytes)
}

function Open-Database {
    $handle = [IntPtr]::Zero
    $rc = [ManagerSqlite]::sqlite3_open16($dbPath, [ref]$handle)
    if ($rc -ne 0) {
        if ($handle -ne [IntPtr]::Zero) { [void][ManagerSqlite]::sqlite3_close($handle) }
        throw "无法打开数据库，SQLite 错误码: $rc"
    }
    $handle
}

function Get-Setting([IntPtr]$Handle, [string]$Key) {
    $statement = [IntPtr]::Zero
    $safeKey = $Key.Replace("'", "''")
    $rc = [ManagerSqlite]::sqlite3_prepare_v2($Handle, "SELECT value FROM settings WHERE key='$safeKey' ORDER BY id DESC LIMIT 1;", -1, [ref]$statement, [IntPtr]::Zero)
    if ($rc -ne 0) { throw "读取设置 $Key 失败，SQLite 错误码: $rc" }
    try {
        $rc = [ManagerSqlite]::sqlite3_step($statement)
        if ($rc -eq 100) { return ConvertFrom-Utf8Pointer ([ManagerSqlite]::sqlite3_column_text($statement, 0)) }
        if ($rc -ne 101) { throw "读取设置 $Key 失败，SQLite 错误码: $rc" }
    } finally { [void][ManagerSqlite]::sqlite3_finalize($statement) }
}

function Invoke-Sql([IntPtr]$Handle, [string]$Sql) {
    $errorPointer = [IntPtr]::Zero
    $rc = [ManagerSqlite]::sqlite3_exec($Handle, $Sql, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$errorPointer)
    try {
        if ($rc -ne 0) { throw "数据库操作失败: $(ConvertFrom-Utf8Pointer $errorPointer)" }
    } finally {
        if ($errorPointer -ne [IntPtr]::Zero) { [ManagerSqlite]::sqlite3_free($errorPointer) }
    }
}

function Prepare-Runtime {
    [IO.Directory]::CreateDirectory($dbFolder) | Out-Null
    [IO.Directory]::CreateDirectory($logFolder) | Out-Null
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) {
        Write-Host '  正在创建数据库...'
        Push-Location $root
        try {
            $output = & $panel setting -show 2>&1
            if ($LASTEXITCODE -ne 0) { throw "创建数据库失败: $($output -join ' ')" }
        } finally { Pop-Location }
        if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { throw "数据库未生成: $dbPath" }
    }
    $handle = Open-Database
    try {
        if (-not (Get-Setting $handle 'subPort')) {
            Invoke-Sql $handle "INSERT INTO settings (key, value) VALUES ('subPort', '$defaultSubPort');"
        }
    } finally { [void][ManagerSqlite]::sqlite3_close($handle) }
}

function Get-PanelSettings {
    if (-not (Test-Path -LiteralPath $dbPath -PathType Leaf)) { return $null }
    $handle = Open-Database
    try {
        $port = Get-Setting $handle 'webPort'
        if (-not $port) { $port = '2053' }
        $base = Get-Setting $handle 'webBasePath'
        if (-not $base) { $base = '/' }
        if (-not $base.StartsWith('/')) { $base = '/' + $base }
        if (-not $base.EndsWith('/')) { $base += '/' }
        $scheme = if ((Get-Setting $handle 'webCertFile') -and (Get-Setting $handle 'webKeyFile')) { 'https' } else { 'http' }
        $subEnable = (Get-Setting $handle 'subEnable') -ne 'false'
        $subPort = Get-Setting $handle 'subPort'
        if (-not $subPort) { $subPort = [string]$defaultSubPort }
        $subListen = Get-Setting $handle 'subListen'
        if (-not $subListen) { $subListen = '所有地址' }
        $subPath = Get-Setting $handle 'subPath'
        if (-not $subPath) { $subPath = '/sub/' }
        [pscustomobject]@{ WebAddress="${scheme}://127.0.0.1:$port$base"; SubEnable=$subEnable; SubPort=$subPort; SubListen=$subListen; SubPath=$subPath }
    } finally { [void][ManagerSqlite]::sqlite3_close($handle) }
}

function Write-Title([string]$text) {
    Write-Host ''
    Write-Separator
    Write-Host "  $text"
    Write-Separator
}

function Write-Separator {
    Write-Host ('-' * (Get-DisplayWidth))
}

function Get-DisplayWidth {
    if ([Console]::IsOutputRedirected) { return 72 }
    [Math]::Max(20, [Math]::Min(72, [Console]::WindowWidth - 1))
}

function Clear-Menu {
    if (-not [Console]::IsOutputRedirected) { Clear-Host }
}

function Get-ServiceText([string]$state) {
    if (-not $state) { return '未安装' }
    switch ($state) {
        'Running' { '运行中' }
        'Stopped' { '已停止' }
        'Start Pending' { '启动中' }
        'Stop Pending' { '停止中' }
        'Paused' { '已暂停' }
        'Auto' { '自动' }
        'Manual' { '手动' }
        'Disabled' { '禁用' }
        default { "$state" }
    }
}

function Get-DisplayVersion([string]$Path, [switch]$Core) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '未找到程序' }
    try {
        $file = Get-Item -LiteralPath $Path
        $stamp = "$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
        $cached = $displayVersions[$Path]
        if ($cached -and $cached.Stamp -eq $stamp) { return $cached.Version }
        if ($Core) {
            $output = & $Path version
            if ($LASTEXITCODE -ne 0) { throw "退出码 $LASTEXITCODE" }
            if (($output | Select-Object -First 1) -notmatch '^Xray (\S+)') { throw '无法识别内核版本' }
            $version = $Matches[1]
        } else { $version = Get-PackageVersion ([IO.Path]::GetDirectoryName($Path)) }
        $displayVersions[$Path] = @{ Stamp=$stamp; Version=$version }
        $version
    } catch { "读取失败：$($_.Exception.Message)" }
}

function Get-StatusLines {
    "  程序版本  $(Get-DisplayVersion $panel)    Xray $(Get-DisplayVersion $xray -Core)"
    try {
        $processes = @(Get-InstanceProcesses)
        foreach ($entry in @(@('面板进程', 'x-ui.exe'), @('内核进程', 'xray-windows-amd64.exe'))) {
            $found = @($processes | Where-Object Name -eq $entry[1])
            $state = if ($found.Count) { "运行中 · PID $(($found.ProcessId) -join ', ')" } else { '已停止' }
            "  $($entry[0])  $state"
        }
        $service = Get-OwnedService
        if ($service) {
            "  服务状态  $(Get-ServiceText $service.State) · $serviceName · $(Get-ServiceText $service.StartMode)启动"
            "  服务账户  $($service.StartName)"
        } else { '  服务状态  未安装 · 使用普通后台模式' }
    } catch { "  运行状态  读取失败：$($_.Exception.Message)" }
    try {
        $settings = Get-PanelSettings
        if ($settings) {
            "  面板地址  $($settings.WebAddress)"
            $subState = if ($settings.SubEnable) { '已启用' } else { '已关闭' }
            "  订阅配置  $subState · 端口 $($settings.SubPort) · 监听 $($settings.SubListen)"
            "  订阅路径  $($settings.SubPath)（需拼接用户订阅 ID）"
        } else {
            '  面板地址  http://127.0.0.1:2053/（首次启动默认值）'
            "  订阅配置  首次启动使用端口 $defaultSubPort"
        }
    } catch { "  面板配置  读取失败：$($_.Exception.Message)" }
    $dbState = if (Test-Path -LiteralPath $dbPath -PathType Leaf) { '已创建' } else { '首次启动时创建' }
    "  数据文件  runtime\db\x-ui.db（$dbState）"
    '  运行日志  runtime\log\'
    '  启动排错  runtime\log\manager-start-error.log'
    '  服务日志  runtime\log\service.log'
    "  工作目录  $root"
    '  网络信息为已保存配置，生效状态以实际监听为准。'
}

function Status {
    Write-Title '运行状态'
    Write-Host ((Get-StatusLines) -join "`n")
    Write-Separator
}

function Read-MenuSelection([string]$LastResult) {
    $previous = ''
    $nextRefresh = [DateTime]::MinValue
    do {
        $size = "$([Console]::WindowWidth):$([Console]::WindowHeight)"
        if ([DateTime]::UtcNow -ge $nextRefresh -or $size -ne $previousSize) {
            $separator = '-' * (Get-DisplayWidth)
            $lines = @(
                $separator
                '  3X-UI · Windows 管理器'
                $separator
                Get-StatusLines
                $separator
                '  1 启动面板     2 停止面板'
                '  3 安装服务     4 卸载服务     5 清空数据并重装'
                '  R 立即刷新     0 退出管理器'
                $separator
                "  上次操作  $LastResult"
                '  状态每 3 秒自动更新；直接按对应按键，无需回车。'
            )
            $screen = $lines -join "`n"
            if ($screen -ne $previous -or $size -ne $previousSize) {
                Clear-Menu
                Write-Host $screen
                $previous = $screen
                $previousSize = $size
            }
            $nextRefresh = [DateTime]::UtcNow.AddSeconds(3)
        }
        if ([Console]::IsInputRedirected) {
            $selection = [Console]::ReadLine()
            if ($null -eq $selection) { return '0' }
            return $selection
        }
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::R) { $nextRefresh = [DateTime]::MinValue; continue }
            if ($key.KeyChar -in @('0', '1', '2', '3', '4', '5')) { return [string]$key.KeyChar }
        }
        Start-Sleep -Milliseconds 100
    } while ($true)
}

function Start-Panel {
    Assert-Install
    $service = Get-OwnedService
    if ($service) {
        if ($service.State -ne 'Running') {
            if (-not (Test-Admin)) { Invoke-Administrator 'start'; return }
            if (@(Get-InstanceProcesses).Count) { throw '普通实例仍在运行，请先停止后再启动服务。' }
            Prepare-Runtime
            Grant-ServicePermissions
            Start-Service -Name $serviceName
            Wait-ServiceState 'Running'
        }
        Write-Host "  服务 $serviceName 已运行，面板通过 Windows 服务管理。"
        return
    }
    if (@(Get-InstanceProcesses).Count) { throw '本目录的实例已在运行。' }
    Prepare-Runtime
    Write-Host '  正在启动...'
    $out = Join-Path $logFolder 'manager-start.log'
    $err = Join-Path $logFolder 'manager-start-error.log'
    Start-Process -FilePath $panel -ArgumentList 'run' -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err | Out-Null
    Start-Sleep -Seconds 4
    if (-not @(Get-InstanceProcesses | Where-Object Name -eq 'x-ui.exe').Count) { throw "启动失败，请查看 $out 和 $err。" }
    Write-Host '  面板已启动，关闭管理器后继续后台运行。'
    Write-Host "  启动日志: $out"
    Write-Host "  错误日志: $err"
}

function Stop-Panel {
    $service = Get-OwnedService
    $stoppedService = $false
    if ($service -and $service.State -ne 'Stopped') {
        if (-not (Test-Admin)) { Invoke-Administrator 'stop'; return }
        Stop-Service -Name $serviceName
        Wait-ServiceState 'Stopped'
        $stoppedService = $true
    }
    Stop-Standalone -QuietIfStopped:$stoppedService
    if ($stoppedService) { Write-Host '  服务已停止。' }
}

function Stop-Standalone([switch]$QuietIfStopped) {
    $items = @(Get-InstanceProcesses)
    if (-not $items.Count) {
        if (-not $QuietIfStopped) { Write-Host '  面板与 Xray 未在运行。' }
        return
    }
    foreach ($item in @($items | Sort-Object { if ($_.Name -eq 'x-ui.exe') { 0 } else { 1 } })) {
        if (-not (Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue)) { continue }
        Write-Host "  正在停止 $($item.Name) (PID $($item.ProcessId))..."
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
        throw "拒绝删除安装目录外的文件: $full"
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($full, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($full, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    }
}

function Reset-Panel {
    $resetVersion = Get-PackageVersion $root
    $releaseUrl = "https://github.com/CarterLeeAlt/3x-ui/releases/download/$resetVersion/x-ui-windows-amd64.zip"
    $service = Get-OwnedService
    Write-Warning "重装 $resetVersion，清空本目录数据和其他文件（含账户、设置、日志、证书）。"
    if ($env:XUI_CONFIRM -cne 'RESET') {
        if ((Read-Host '  输入 RESET 继续') -cne 'RESET') {
            $script:actionOutcome = '已取消'
            Write-Host '  已取消重装，程序与数据保持原状。'
            return
        }
    }
    if ($service -and -not (Test-Admin)) { Invoke-Administrator 'reset'; return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $stage = Join-Path $root '.x-ui-reset-staging'
    if (Test-Path -LiteralPath $stage) { throw "暂存目录已存在，请先检查: $stage" }
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        $zip = Join-Path $stage 'release.zip'
        Write-Host "  正在下载 $resetVersion..."
        & curl.exe --silent --show-error --fail --location --output $zip $releaseUrl
        if ($LASTEXITCODE -ne 0) { throw '下载失败，本地安装未做任何改动。' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try { foreach ($entry in $archive.Entries) { $n = $entry.FullName.Replace('\', '/'); if ($n.StartsWith('/') -or $n -match '(^|/)\.\.(/|$)' -or $n -match '^[a-zA-Z]:') { throw "发布包路径不安全: $n" } } } finally { $archive.Dispose() }
        Expand-Archive -LiteralPath $zip -DestinationPath $stage
        $source = Join-Path $stage 'x-ui'
        foreach ($name in @('x-ui.exe', 'x-ui-manager.bat', 'x-ui-service.exe', 'readme.txt', 'bin\xray-windows-amd64.exe', 'bin\geoip.dat', 'bin\geosite.dat')) {
            if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { throw "发布包缺少文件: $name" }
        }
        $packageVersion = Get-PackageVersion $source
        if ($packageVersion -ne $resetVersion) { throw '发布包的版本与请求版本不一致，拒绝恢复。' }
        Write-Host "  安装包校验通过，版本: $packageVersion"
        Stop-Panel
        $keep = @('x-ui-manager.bat', 'x-ui-service.exe', '.x-ui-reset-staging')
        $items = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -notin $keep })
        foreach ($item in $items) { Remove-ToRecycleBin $item.FullName }
        Get-ChildItem -LiteralPath $source | Copy-Item -Destination $root -Recurse -Force
        if ($service) {
            [IO.Directory]::CreateDirectory($logFolder) | Out-Null
            Grant-ServicePermissions
        }
        Write-Host "  已重置为 $resetVersion，面板已停止。"
        Write-Host '  原数据已移入回收站；下次启动将生成默认数据库。'
        if ($service) { Write-Host "  服务 $serviceName 的注册已保留，下次选择“启动”即可运行。" }
    } finally {
        if (Test-Path -LiteralPath $stage) {
            try { Remove-ToRecycleBin $stage } catch { Write-Warning "暂存目录清理失败: $stage" }
        }
    }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Administrator([ValidateSet('start','stop','reset','service-install','service-remove')][string]$Name) {
    $outputFile = [IO.Path]::GetTempFileName()
    $arguments = $Name
    if ($Name -eq 'reset') { $arguments += ' confirmed' }
    $command = '/d /s /c ""' + $env:MANAGER_BAT + '" ' + $arguments + ' > "' + $outputFile + '" 2>&1"'
    Write-Host '  正在请求管理员权限...'
    $process = $null
    try {
        try {
            $process = Start-Process -FilePath $env:ComSpec -ArgumentList $command -WorkingDirectory $root -Verb RunAs -WindowStyle Hidden -PassThru
        } catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1223) {
                $script:actionOutcome = '已取消'
                Write-Host '  已取消管理员授权。'
                return
            }
            throw
        }
        $process.WaitForExit()
        $output = [IO.File]::ReadAllText($outputFile).Trim()
        if ($process.ExitCode -ne 0) {
            if ($output) { throw $output }
            throw "管理员操作失败，退出码: $($process.ExitCode)"
        }
        if ($output) { Write-Host $output }
        if ($Name -eq 'start') { $script:actionStatusShown = $true }
    } finally {
        if ($process) { $process.Dispose() }
        [IO.File]::Delete($outputFile)
    }
}

function Get-OwnedService {
    $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'"
    if ($service) {
        $registered = $service.PathName.Trim().Trim('"')
        if (-not [string]::Equals($registered, $serviceExe, [StringComparison]::OrdinalIgnoreCase)) {
            throw "服务 '$serviceName' 属于其他目录，拒绝操作。注册路径: $($service.PathName)"
        }
    }
    $service
}

function Get-ServiceState {
    $service = Get-OwnedService
    if ($service) { $service.State }
}

function Wait-ServiceState([string]$State) {
    $service = Get-Service -Name $serviceName
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::$State, [TimeSpan]::FromSeconds(30))
    if ((Get-ServiceState) -ne $State) { throw "服务未进入 $State 状态，请查看 runtime\log\service.log。" }
}

function Grant-ServicePermissions {
    & icacls.exe $root /grant '*S-1-5-19:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法授予 LocalService 程序读取权限。' }
    & icacls.exe (Join-Path $root 'runtime') /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法授予 LocalService 运行数据写入权限。' }
    & icacls.exe $binFolder /grant '*S-1-5-19:(OI)(CI)M' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法授予 LocalService 内核配置和资源写入权限。' }
}

function Service-Status {
    $service = Get-OwnedService
    Write-Host "  服务 $serviceName`: $(Get-ServiceText $service.State)"
    if ($service) {
        Write-Host "  启动类型: $(Get-ServiceText $service.StartMode)"
        Write-Host "  运行账户: $($service.StartName)"
        Write-Host "  程序路径: $($service.PathName)"
        Write-Host "  服务日志: $(Join-Path $logFolder 'service.log')"
    }
}

function Service-Install {
    if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) { throw "缺少文件: $serviceExe" }
    if (Get-OwnedService) { throw '服务已安装，请选择“启动”。' }
    if (-not (Test-Admin)) { Invoke-Administrator 'service-install'; return }
    Assert-Install
    if (@(Get-InstanceProcesses).Count) {
        Write-Host '  正在切换为服务...'
        Stop-Standalone
    }
    Prepare-Runtime
    $runtime = Join-Path $root 'runtime'
    $rootACL = Get-Acl -LiteralPath $root
    $runtimeACL = Get-Acl -LiteralPath $runtime
    $binACL = Get-Acl -LiteralPath $binFolder
    $created = $false
    try {
        Grant-ServicePermissions
        $credential = [Management.Automation.PSCredential]::new('NT AUTHORITY\LocalService', [Security.SecureString]::new())
        New-Service -Name $serviceName -BinaryPathName ('"' + $serviceExe + '"') -Credential $credential -DisplayName '3x-ui' -Description '3x-ui panel and Xray core' -StartupType Automatic | Out-Null
        $created = $true
        Start-Service -Name $serviceName
        Wait-ServiceState 'Running'
    } catch {
        $failure = $_
        if ($created) {
            $state = Get-ServiceState
            if ($state -ne 'Stopped') { Stop-Service -Name $serviceName; Wait-ServiceState 'Stopped' }
            & sc.exe delete $serviceName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "安装失败且服务注册清理失败，请检查服务 '$serviceName'。原始错误: $failure" }
        }
        Set-Acl -LiteralPath $root -AclObject $rootACL
        Set-Acl -LiteralPath $runtime -AclObject $runtimeACL
        Set-Acl -LiteralPath $binFolder -AclObject $binACL
        throw $failure
    }
    Write-Host '  服务已安装并启动。'
    Write-Host "  服务名: $serviceName · 账户: LocalService · 随系统启动"
    Write-Host "  服务日志: $(Join-Path $logFolder 'service.log')"
}

function Service-Remove {
    $state = Get-ServiceState
    if (-not $state) { throw "服务 '$serviceName' 未安装。" }
    if (-not (Test-Admin)) { Invoke-Administrator 'service-remove'; return }
    if ($state -ne 'Stopped') {
        Stop-Service -Name $serviceName
        Wait-ServiceState 'Stopped'
    }
    & sc.exe delete $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "删除服务 '$serviceName' 失败。" }
    Write-Host '  服务已卸载，数据保留。'
    Write-Host "  数据库: $dbPath"
    Write-Host '  下次选择“启动”将以普通后台模式运行。'
}

function Prepare-Only {
    Assert-Install
    if (@(Get-InstanceProcesses).Count) { throw '本目录的实例已在运行。' }
    Prepare-Runtime
}

function Run-Action([string]$name) {
    $script:actionOutcome = '已完成'
    $script:actionStatusShown = $false
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
    if ($Action) {
        Run-Action $Action
        if ($Action -eq 'start' -and -not $script:actionStatusShown) { Status }
        exit 0
    }
    $lastResult = '暂无'
    $menuActions = @{
        '1' = @('start', '启动面板')
        '2' = @('stop', '停止面板')
        '3' = @('service-install', '安装服务')
        '4' = @('service-remove', '卸载服务')
        '5' = @('reset', '清空数据并重装')
    }
    do {
        $selection = Read-MenuSelection $lastResult
        if ($selection -eq '0') { break }
        if (-not $menuActions.ContainsKey($selection)) { continue }
        $item = $menuActions[$selection]
        Clear-Menu
        Write-Title $item[1]
        try {
            Run-Action $item[0]
            $lastResult = "$($item[1]) · $script:actionOutcome · $(Get-Date -Format 'HH:mm:ss')"
        } catch {
            $lastResult = "$($item[1])失败：$($_.Exception.Message)"
            Write-Host "  $lastResult" -ForegroundColor Red
        }
        if (-not $script:actionStatusShown) { Status }
        [void](Read-Host '  以上为操作结果和最新状态，按回车返回主界面')
    } while ($selection -ne '0')
    exit 0
} catch {
    [Console]::Error.WriteLine("错误: $($_.Exception.Message)")
    exit 1
}
