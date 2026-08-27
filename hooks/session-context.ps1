# SessionStart hook: inject only vault counts and health state as context.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VaultPath,

    [Parameter(Mandatory = $false)]
    [string]$StateDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom

function Test-HasControlCharacter {
    param([AllowEmptyString()][string]$Value)

    return $Value -match '[\x00-\x1F\x7F\p{Cf}\p{Zl}\p{Zp}]'
}

function Test-IsReparsePoint {
    param([System.IO.FileSystemInfo]$Item)

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-HasReparsePointBelowRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    try {
        if (-not $Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        $trimCharacters = [char[]]@(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $relativePath = $Path.Substring($Root.Length).TrimStart($trimCharacters)
        $currentPath = $Root
        foreach ($part in @($relativePath -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
            $currentPath = Join-Path $currentPath $part
            $item = Get-Item -LiteralPath $currentPath -Force
            if (Test-IsReparsePoint -Item $item) {
                return $true
            }
        }
        return $false
    }
    catch {
        return $true
    }
}

function Get-NormalizedDirectoryPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    while ($fullPath.Length -gt $root.Length -and
        ($fullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar.ToString(), [System.StringComparison]::Ordinal) -or
         $fullPath.EndsWith([System.IO.Path]::AltDirectorySeparatorChar.ToString(), [System.StringComparison]::Ordinal))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
}

function Get-ConfiguredVaultFromState {
    param([string]$StateRoot)

    if ([string]::IsNullOrWhiteSpace($StateRoot) -or (Test-HasControlCharacter -Value $StateRoot)) {
        throw 'Unsafe state directory.'
    }
    $normalizedStateRoot = Get-NormalizedDirectoryPath -Path $StateRoot
    if (Test-Path -LiteralPath $normalizedStateRoot -PathType Container) {
        $stateRootItem = Get-Item -LiteralPath $normalizedStateRoot -Force
        if (Test-IsReparsePoint -Item $stateRootItem) {
            throw 'Unsafe state directory.'
        }
    }
    $statePath = Join-Path $normalizedStateRoot 'install-state'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return ''
    }
    $stateItem = Get-Item -LiteralPath $statePath -Force
    if ($stateItem.PSIsContainer -or (Test-IsReparsePoint -Item $stateItem)) {
        throw 'Unsafe install state.'
    }
    $stateLines = [System.IO.File]::ReadAllLines($stateItem.FullName)
    if ($stateLines.Length -lt 2 -or
        ($stateLines[0] -cne 'ai-session-kit-state-v1' -and
         $stateLines[0] -cne 'ai-session-kit-state-v2' -and
         $stateLines[0] -cne 'ai-session-kit-state-v3') -or
        [string]::IsNullOrWhiteSpace($stateLines[1]) -or
        (Test-HasControlCharacter -Value $stateLines[1]) -or
        -not [System.IO.Path]::IsPathRooted($stateLines[1])) {
        throw 'Invalid install state.'
    }
    if (($stateLines[0] -ceq 'ai-session-kit-state-v2' -or $stateLines[0] -ceq 'ai-session-kit-state-v3') -and
        ($stateLines.Length -lt 4 -or [string]::IsNullOrEmpty($stateLines[2]) -or [string]::IsNullOrEmpty($stateLines[3]))) {
        throw 'Invalid install state.'
    }
    if ($stateLines[0] -ceq 'ai-session-kit-state-v3') {
        $skillCount = 0
        if ($stateLines.Length -lt 6 -or
            $stateLines[4] -cne 'ai-session-kit-owned-skills-v1' -or
            -not [int]::TryParse($stateLines[5], [ref]$skillCount) -or
            $skillCount -le 0 -or
            $stateLines.Length -ne ($skillCount + 6)) {
            throw 'Invalid install state.'
        }
        $seenSkills = @{}
        for ($skillIndex = 0; $skillIndex -lt $skillCount; $skillIndex += 1) {
            $skillName = $stateLines[$skillIndex + 6]
            if ($skillName -notmatch '^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$' -or $seenSkills.ContainsKey($skillName)) {
                throw 'Invalid install state.'
            }
            $seenSkills[$skillName] = $true
        }
    }
    return $stateLines[1]
}

function Read-BoundedSessionInput {
    $stream = [Console]::OpenStandardInput()
    $buffer = New-Object byte[] 8192
    $total = 0
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $total += $read
        if ($total -gt 1048576) {
            return $false
        }
    }
    return $true
}

function Test-IsExcludedRelativePath {
    param([string]$RelativePath)

    foreach ($segment in ($RelativePath -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment)) {
            continue
        }
        if ($segment -ieq 'assets' -or
            $segment -match '^(?i:_kit(?:[._-].*)?)$' -or
            $segment -match '^(?i:(?:90\.)?private(?:[._-].*)?)$') {
            return $true
        }
    }
    return $false
}

function Test-IsArchivedDocument {
    param([string]$Path)

    $reader = $null
    try {
        $reader = [System.IO.File]::OpenText($Path)
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($line -match '^status:\s*archived(?:\s|$)') {
                return $true
            }
        }
        return $false
    }
    catch {
        # An unreadable document is omitted instead of becoming hook context.
        return $true
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

function Get-TaskCount {
    param([string]$VaultRoot)

    $taskDirectory = Join-Path $VaultRoot '00.memory\tasks\in-progress'
    if (-not (Test-Path -LiteralPath $taskDirectory -PathType Container)) {
        return 0
    }

    try {
        $taskDirectoryItem = Get-Item -LiteralPath $taskDirectory -Force
        if ((Test-IsReparsePoint -Item $taskDirectoryItem) -or
            (Test-HasReparsePointBelowRoot -Path $taskDirectoryItem.FullName -Root $VaultRoot)) {
            return 0
        }
        $taskFiles = @(Get-ChildItem -LiteralPath $taskDirectory -File -Force |
            Where-Object {
                $_.Extension -ieq '.md' -and
                -not (Test-IsReparsePoint -Item $_) -and
                -not (Test-IsArchivedDocument -Path $_.FullName)
            })
    }
    catch {
        return 0
    }
    return $taskFiles.Count
}

function Get-RecentCountFromDirectory {
    param(
        [string]$VaultRoot,
        [string]$Directory,
        [datetime]$CutoffUtc
    )

    $count = 0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Directory)
    while ($stack.Count -gt 0) {
        $currentDirectory = $stack.Pop()
        try {
            $currentItem = Get-Item -LiteralPath $currentDirectory -Force
            if (Test-IsReparsePoint -Item $currentItem) {
                continue
            }
            $children = @(Get-ChildItem -LiteralPath $currentDirectory -Force)
        }
        catch {
            continue
        }

        foreach ($child in $children) {
            $relativePath = $child.FullName.Substring($VaultRoot.Length).TrimStart('\', '/').Replace('\', '/')
            if (Test-IsExcludedRelativePath -RelativePath $relativePath) {
                continue
            }
            if ($child.PSIsContainer) {
                if (-not (Test-IsReparsePoint -Item $child)) {
                    $stack.Push($child.FullName)
                }
                continue
            }
            if ($child.Extension -ine '.md' -or
                (Test-IsReparsePoint -Item $child) -or
                $child.LastWriteTimeUtc -lt $CutoffUtc -or
                (Test-IsArchivedDocument -Path $child.FullName)) {
                continue
            }

            $count += 1
        }
    }
    return $count
}

function Get-RecentCount {
    param([string]$VaultRoot)

    $cutoffUtc = [datetime]::UtcNow.AddDays(-7)
    $count = 0
    foreach ($zone in @('00.memory', '10.notes', '20.work')) {
        $zonePath = Join-Path $VaultRoot $zone
        if (-not (Test-Path -LiteralPath $zonePath -PathType Container)) {
            continue
        }
        $count += (Get-RecentCountFromDirectory -VaultRoot $VaultRoot -Directory $zonePath -CutoffUtc $cutoffUtc)
    }
    return $count
}

function Get-LintLine {
    param([string]$StateRoot)

    if ([string]::IsNullOrWhiteSpace($StateRoot) -or (Test-HasControlCharacter -Value $StateRoot)) {
        return ''
    }
    try {
        $stateRootPath = Get-NormalizedDirectoryPath -Path $StateRoot
        $lintPath = Join-Path $stateRootPath 'lint-latest.txt'
        if (-not (Test-Path -LiteralPath $lintPath -PathType Leaf)) {
            return ''
        }
        $lintItem = Get-Item -LiteralPath $lintPath -Force
        if (Test-IsReparsePoint -Item $lintItem) {
            return ''
        }
        $reader = [System.IO.File]::OpenText($lintItem.FullName)
        try {
            $line = $reader.ReadLine()
        }
        finally {
            $reader.Dispose()
        }
        if ($null -ne $line -and
            $line -match '^kb-lint [0-9]{4}-[0-9]{2}-[0-9]{2}: ERR [0-9]+( — 모두 정상| — 상세는 kb_lint\.py 재실행)$') {
            return $line
        }
    }
    catch {
        return ''
    }
    return ''
}

try {
    # SessionStart sends JSON on stdin. Its fields are intentionally not trusted or echoed.
    if (-not (Read-BoundedSessionInput)) {
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $StateDirectory = $env:AI_SESSION_KIT_STATE_DIR
    }
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $StateDirectory = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }

    if ([string]::IsNullOrWhiteSpace($VaultPath)) {
        try {
            $VaultPath = Get-ConfiguredVaultFromState -StateRoot $StateDirectory
        }
        catch {
            exit 0
        }
        if ([string]::IsNullOrWhiteSpace($VaultPath)) {
            $VaultPath = $env:KB_VAULT
        }
    }

    if ([string]::IsNullOrWhiteSpace($VaultPath) -or
        (Test-HasControlCharacter -Value $VaultPath) -or
        -not [System.IO.Path]::IsPathRooted($VaultPath)) {
        exit 0
    }
    $vaultItem = Get-Item -LiteralPath $VaultPath -Force
    if (-not $vaultItem.PSIsContainer) {
        exit 0
    }
    $vaultRoot = Get-NormalizedDirectoryPath -Path $vaultItem.FullName

    $taskCount = Get-TaskCount -VaultRoot $vaultRoot
    $recentCount = Get-RecentCount -VaultRoot $vaultRoot
    $lintLine = Get-LintLine -StateRoot $StateDirectory
    if ([string]::IsNullOrEmpty($lintLine)) {
        $lintLine = '(lint 미실행 — session-end skill 실행 시 갱신)'
    }

    $context = @"
[지식 vault — SessionStart hook 자동 주입]
작업 착수 전 vault 조회 규칙은 kb-lookup skill을 따를 것.
세션 기록은 자동 저장하지 말 것. 긴 작업이 안전하게 넘길 수 있는 지점에 도달하면 session-end skill의 제안 mode를 대화당 한 번만 적용하고, 사용자가 직접 종료를 요청하거나 제안에 동의한 뒤에만 기록할 것.
project가 확인되기 전에는 다른 project의 제목이나 파일명을 자동으로 읽어 context에 넣지 말 것. 사용자가 "이어서 하자"라고 하면 session-start skill로 current project를 확인한 뒤 matching task만 조회할 것.

## Vault 요약
진행 중 태스크: ${taskCount}건
최근 7일 수정 문서: ${recentCount}건

## Vault 상태
$lintLine
인덱스: 10.notes/INDEX.md · 20.work/INDEX.md · 진입점: CLAUDE.md · AGENTS.md
"@

    $output = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'SessionStart'
            additionalContext = $context
        }
    }
    $json = $output | ConvertTo-Json -Compress -Depth 5
    [Console]::Out.Write($json)
    exit 0
}
catch {
    # Session context is optional. Never expose a path or exception in hook output.
    exit 0
}
