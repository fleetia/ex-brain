[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VaultPath,

    [Parameter(Mandatory = $false)]
    [string]$StateDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-HasControlCharacter {
    param([AllowEmptyString()][string]$Value)

    return $Value -match '[\x00-\x1F\x7F]'
}

try {
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $StateDirectory = $env:AI_SESSION_KIT_STATE_DIR
    }
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $userHome = $env:AI_SESSION_KIT_USER_HOME
        if ([string]::IsNullOrWhiteSpace($userHome)) {
            $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        }
        $StateDirectory = Join-Path $userHome '.ai-session-kit'
    }
    if (-not [System.IO.Path]::IsPathRooted($StateDirectory) -or
        (Test-HasControlCharacter -Value $StateDirectory)) {
        exit 0
    }
    $StateDirectory = [System.IO.Path]::GetFullPath($StateDirectory)

    if ([string]::IsNullOrWhiteSpace($VaultPath)) {
        $statePath = Join-Path $StateDirectory 'install-state'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            exit 0
        }
        $stateItem = Get-Item -LiteralPath $statePath -Force
        if (($stateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            exit 0
        }
        $stateLines = [System.IO.File]::ReadAllLines($stateItem.FullName)
        if ($stateLines.Length -lt 2 -or
            ($stateLines[0] -ne 'ai-session-kit-state-v2' -and $stateLines[0] -ne 'ai-session-kit-state-v1')) {
            exit 0
        }
        $VaultPath = $stateLines[1]
    }
    if ([string]::IsNullOrWhiteSpace($VaultPath) -or
        -not [System.IO.Path]::IsPathRooted($VaultPath) -or
        (Test-HasControlCharacter -Value $VaultPath)) {
        exit 0
    }
    $VaultPath = [System.IO.Path]::GetFullPath($VaultPath)

    $pythonScript = Join-Path $PSScriptRoot 'kb_lint.py'
    if (-not (Test-Path -LiteralPath $pythonScript -PathType Leaf)) {
        exit 0
    }
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -eq $launcher -and $null -eq $python) {
        exit 0
    }

    $previousStateDirectory = $env:AI_SESSION_KIT_STATE_DIR
    $env:AI_SESSION_KIT_STATE_DIR = $StateDirectory
    try {
        if ($null -ne $launcher) {
            & $launcher.Source -3 $pythonScript $VaultPath '--check'
        }
        else {
            & $python.Source $pythonScript $VaultPath '--check'
        }
        $status = $LASTEXITCODE
    }
    finally {
        $env:AI_SESSION_KIT_STATE_DIR = $previousStateDirectory
    }
    exit $status
}
catch {
    Write-Warning 'lint 검증을 실행하지 못했습니다. Python 3 설치와 install-state를 확인하세요.'
    exit 0
}
