[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$powerShellExe = Join-Path $PSHOME 'powershell.exe'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$skills = @(
    'session-start',
    'session-end',
    'kb-lookup',
    'kb-routing',
    'humanize-ko',
    'cognitive-rhythm-writing',
    'task-doc-writing',
    'weekly-summary',
    'monthly-summary'
)

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-ChildPowerShell {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$InputText = $null
    )

    $stderrPath = Join-Path $script:testRoot ('stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    $nativeArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $ScriptPath
    ) + $Arguments

    try {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            if ($null -eq $InputText) {
                $stdoutLines = @(& $script:powerShellExe @nativeArguments 2> $stderrPath)
            }
            else {
                $stdoutLines = @($InputText | & $script:powerShellExe @nativeArguments 2> $stderrPath)
            }
            $status = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            [System.IO.File]::ReadAllText($stderrPath)
        }
        else {
            ''
        }
        return [pscustomobject]@{
            Status = $status
            Stdout = ($stdoutLines -join "`n")
            Stderr = $stderr
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PowerShellHookCommand {
    param(
        [string]$Command,
        [string]$InputText
    )

    $stderrPath = Join-Path $script:testRoot ('powershell-command-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $stdoutLines = @($InputText | & $script:powerShellExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $Command 2> $stderrPath)
            $status = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            [System.IO.File]::ReadAllText($stderrPath)
        }
        else {
            ''
        }
        return [pscustomobject]@{
            Status = $status
            Stdout = ($stdoutLines -join "`n")
            Stderr = $stderr
        }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WindowsHookCommand {
    param(
        [string]$Command,
        [string]$InputText,
        [string]$WorkingDirectory = ''
    )

    $stderrPath = Join-Path $script:testRoot ('windows-command-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
    $commandInterpreter = $env:COMSPEC
    if ([string]::IsNullOrWhiteSpace($commandInterpreter)) {
        $commandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
    }
    $locationChanged = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Push-Location -LiteralPath $WorkingDirectory
            $locationChanged = $true
        }
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $stdoutLines = @($InputText | & $commandInterpreter /D /S /C $Command 2> $stderrPath)
            $status = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            [System.IO.File]::ReadAllText($stderrPath)
        }
        else {
            ''
        }
        return [pscustomobject]@{
            Status = $status
            Stdout = ($stdoutLines -join "`n")
            Stderr = $stderr
        }
    }
    finally {
        if ($locationChanged) {
            Pop-Location
        }
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, $script:utf8NoBom)
}

function ConvertTo-CompactJson {
    param([object]$Value)

    return ($Value | ConvertTo-Json -Compress -Depth 20)
}

function Get-HookHandlers {
    param(
        [object]$Config,
        [string]$EventName
    )

    if ($null -eq $Config -or $null -eq $Config.PSObject.Properties['hooks']) {
        return @()
    }
    $hooks = $Config.PSObject.Properties['hooks'].Value
    if ($null -eq $hooks -or $null -eq $hooks.PSObject.Properties[$EventName]) {
        return @()
    }

    $handlers = New-Object 'System.Collections.Generic.List[object]'
    foreach ($group in @($hooks.PSObject.Properties[$EventName].Value)) {
        if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) {
            continue
        }
        foreach ($handler in @($group.PSObject.Properties['hooks'].Value)) {
            if ($null -ne $handler) {
                [void]$handlers.Add($handler)
            }
        }
    }
    return $handlers.ToArray()
}

function Get-OwnedHandlers {
    param(
        [object]$Config,
        [string]$EventName,
        [string]$HookFileName
    )

    return @(Get-HookHandlers -Config $Config -EventName $EventName | Where-Object {
        $null -ne $_.PSObject.Properties['command'] -and
        [string]$_.PSObject.Properties['command'].Value -like ('*' + $HookFileName + '*')
    })
}

function Get-TreeFingerprint {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return ''
    }
    $prefixLength = $Root.TrimEnd('\').Length + 1
    $lines = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
        Sort-Object -Property FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($prefixLength)
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            '{0}|{1}' -f $relative, $hash
        })
    return ($lines -join "`n")
}

function Assert-JunctionTarget {
    param(
        [string]$Path,
        [string]$ExpectedTarget
    )

    $item = Get-Item -LiteralPath $Path -Force
    Assert-True ($item.LinkType -eq 'Junction') ('directory junction이 아닙니다: ' + $Path)
    $target = @($item.Target)[0]
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$target)) ('junction target을 읽을 수 없습니다: ' + $Path)
    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $Path) $target
    }
    $actual = [System.IO.Path]::GetFullPath($target).TrimEnd('\')
    $expected = [System.IO.Path]::GetFullPath($ExpectedTarget).TrimEnd('\')
    Assert-True ($actual -ieq $expected) ('junction target이 다릅니다: ' + $Path)
}

function Assert-DenyResult {
    param(
        [object]$Result,
        [string]$SensitiveValue,
        [string]$Message
    )

    Assert-True ($Result.Status -eq 0) ($Message + ' (hook status)')
    $parsed = $Result.Stdout | ConvertFrom-Json
    Assert-True ($parsed.hookSpecificOutput.hookEventName -eq 'PreToolUse') ($Message + ' (event)')
    Assert-True ($parsed.hookSpecificOutput.permissionDecision -eq 'deny') ($Message + ' (decision)')
    Assert-True (-not (($Result.Stdout + $Result.Stderr).Contains($SensitiveValue))) ($Message + ' (민감값 노출)')
}

function Assert-FailClosedResult {
    param(
        [object]$Result,
        [string]$SensitiveValue,
        [string]$Message
    )

    Assert-True ($Result.Status -eq 2) ($Message + ' (hook status)')
    Assert-True ([string]::IsNullOrWhiteSpace($Result.Stdout)) ($Message + ' (unexpected stdout)')
    Assert-True (-not [string]::IsNullOrWhiteSpace($Result.Stderr)) ($Message + ' (missing blocking stderr)')
    Assert-True (-not (($Result.Stdout + $Result.Stderr).Contains($SensitiveValue))) ($Message + ' (민감값 노출)')
}

$originalOverride = $env:AI_SESSION_KIT_USER_HOME
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-session-kit-windows-' + [guid]::NewGuid().ToString('N'))
$setupScript = Join-Path $repoRoot 'setup.ps1'
$uninstallScript = Join-Path $repoRoot 'uninstall.ps1'
$substDrive = $null
$substExecutable = Join-Path $env:SystemRoot 'System32\subst.exe'

try {
    [void](New-Item -ItemType Directory -Path $testRoot)

    foreach ($scriptPath in @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -File -Recurse |
        Where-Object { $_.FullName -notlike '*\dist\*' } |
        Select-Object -ExpandProperty FullName)) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        Assert-True ($parseErrors.Count -eq 0) ('PowerShell parse 실패: ' + $scriptPath + ' — ' + ($parseErrors -join '; '))
    }

    $userHome = Join-Path $testRoot 'User Home'
    $vaultA = Join-Path $testRoot 'Vault - Work & O''Brien $Money'
    $vaultB = Join-Path $testRoot 'Second Vault'
    $claudeSettings = Join-Path $userHome '.claude\settings.json'
    $codexHooks = Join-Path $userHome '.codex\hooks.json'
    $stateDirectory = Join-Path $userHome '.ai-session-kit'
    $stateFile = Join-Path $stateDirectory 'install-state'
    $runtime = Join-Path $stateDirectory 'runtime'
    $env:AI_SESSION_KIT_USER_HOME = $userHome

    $rejectedHome = Join-Path $testRoot 'Rejected WSL Home'
    $env:AI_SESSION_KIT_USER_HOME = $rejectedHome
    $rejectedWslInstall = Invoke-ChildPowerShell -ScriptPath $setupScript -Arguments @('-VaultPath', '\\wsl.localhost\distro\mnt\c\Vault')
    Assert-True ($rejectedWslInstall.Status -ne 0) 'WSL UNC vault preflight가 성공했습니다.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($rejectedWslInstall.Stderr)) 'WSL UNC vault preflight stderr를 수집하지 못했습니다.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rejectedHome '.ai-session-kit\install-state'))) 'WSL UNC vault preflight 실패가 state를 남겼습니다.'
    $env:AI_SESSION_KIT_USER_HOME = $userHome

    Write-JsonFile -Path $claudeSettings -Value ([ordered]@{
        keep = 'claude-foreign'
        hooks = [ordered]@{
            SessionStart = @([ordered]@{
                matcher = 'startup'
                hooks = @([ordered]@{ type = 'command'; command = 'Write-Output foreign-claude-session' })
            })
            PreToolUse = @([ordered]@{
                matcher = 'Write'
                hooks = @([ordered]@{ type = 'command'; command = 'Write-Output foreign-claude-write' })
            })
        }
    })
    Write-JsonFile -Path $codexHooks -Value ([ordered]@{
        description = 'foreign description'
        hooks = [ordered]@{
            SessionStart = @([ordered]@{
                matcher = 'startup'
                hooks = @([ordered]@{ type = 'command'; command = 'Write-Output foreign-codex-session' })
            })
            PreToolUse = $null
        }
    })

    $install = Invoke-ChildPowerShell -ScriptPath $setupScript -Arguments @('-VaultPath', $vaultA)
    Assert-True ($install.Status -eq 0) ('setup.ps1 실패: ' + $install.Stderr + $install.Stdout)
    Assert-True (Test-Path -LiteralPath $stateFile -PathType Leaf) 'install-state가 없습니다.'
    Assert-True (Test-Path -LiteralPath (Join-Path $runtime 'hooks\session-context.ps1') -PathType Leaf) 'Windows SessionStart hook이 설치되지 않았습니다.'
    Assert-True (Test-Path -LiteralPath (Join-Path $runtime 'hooks\check-pii.ps1') -PathType Leaf) 'Windows PII hook이 설치되지 않았습니다.'
    $stateLines = [System.IO.File]::ReadAllLines($stateFile)
    Assert-True ($stateLines.Length -ge 4) 'install-state 형식이 잘못됐습니다.'
    Assert-True ($stateLines[0] -eq 'ai-session-kit-state-v2') 'install-state marker가 다릅니다.'
    Assert-True ($stateLines[1] -ieq [System.IO.Path]::GetFullPath($vaultA)) 'install-state vault가 다릅니다.'

    foreach ($root in @((Join-Path $userHome '.claude\skills'), (Join-Path $userHome '.agents\skills'))) {
        foreach ($skill in $skills) {
            Assert-JunctionTarget -Path (Join-Path $root $skill) -ExpectedTarget (Join-Path $runtime ('skills\' + $skill))
        }
    }

    $claudeConfig = [System.IO.File]::ReadAllText($claudeSettings) | ConvertFrom-Json
    $codexConfig = [System.IO.File]::ReadAllText($codexHooks) | ConvertFrom-Json
    Assert-True ($claudeConfig.keep -eq 'claude-foreign') 'Claude foreign top-level 설정이 사라졌습니다.'
    Assert-True ($codexConfig.description -eq 'foreign description') 'Codex foreign top-level 설정이 사라졌습니다.'
    Assert-True (($codexConfig.hooks.PreToolUse -is [System.Array]) -and $codexConfig.hooks.PreToolUse.Count -eq 1) 'Codex singleton PreToolUse array가 보존되지 않았습니다.'
    Assert-True (@(Get-HookHandlers $claudeConfig 'SessionStart' | Where-Object { $_.command -eq 'Write-Output foreign-claude-session' }).Count -eq 1) 'Claude foreign hook이 사라졌습니다.'
    Assert-True (@(Get-HookHandlers $codexConfig 'SessionStart' | Where-Object { $_.command -eq 'Write-Output foreign-codex-session' }).Count -eq 1) 'Codex foreign hook이 사라졌습니다.'
    $claudeSessionHandlers = @(Get-OwnedHandlers $claudeConfig 'SessionStart' 'session-context.ps1')
    $claudePiiHandlers = @(Get-OwnedHandlers $claudeConfig 'PreToolUse' 'check-pii.ps1')
    $codexSessionHandlers = @(Get-OwnedHandlers $codexConfig 'SessionStart' 'session-context.ps1')
    $codexPiiHandlers = @(Get-OwnedHandlers $codexConfig 'PreToolUse' 'check-pii.ps1')
    Assert-True ($claudeSessionHandlers.Count -eq 1) 'Claude SessionStart owned hook 수가 다릅니다.'
    Assert-True ($claudePiiHandlers.Count -eq 1) 'Claude PreToolUse owned hook 수가 다릅니다.'
    Assert-True ($codexSessionHandlers.Count -eq 1) 'Codex SessionStart owned hook 수가 다릅니다.'
    Assert-True ($codexPiiHandlers.Count -eq 1) 'Codex PreToolUse owned hook 수가 다릅니다.'
    Assert-True ($null -ne $codexSessionHandlers[0].PSObject.Properties['commandWindows']) 'Codex SessionStart commandWindows가 없습니다.'
    Assert-True ($null -ne $codexPiiHandlers[0].PSObject.Properties['commandWindows']) 'Codex PreToolUse commandWindows가 없습니다.'
    Assert-True ([string]$codexSessionHandlers[0].commandWindows -like '*session-context.ps1*') 'Codex SessionStart commandWindows가 PowerShell hook을 가리키지 않습니다.'
    Assert-True ([string]$codexPiiHandlers[0].commandWindows -like '*check-pii.ps1*') 'Codex PreToolUse commandWindows가 PowerShell hook을 가리키지 않습니다.'
    Assert-True ([string]$claudeSessionHandlers[0].shell -eq 'powershell') 'Claude SessionStart shell이 powershell이 아닙니다.'
    Assert-True ([string]$claudePiiHandlers[0].shell -eq 'powershell') 'Claude PreToolUse shell이 powershell이 아닙니다.'

    $taskDirectory = Join-Path $vaultA '00.memory\tasks\in-progress'
    $noteDirectory = Join-Path $vaultA '10.notes'
    [System.IO.File]::WriteAllText((Join-Path $taskDirectory '260819_windows-task.md'), 'task', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $noteDirectory 'recent.md'), 'recent', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $noteDirectory 'customer-private.person@corp.invalid.md'), 'safe', $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $noteDirectory 'archived.md'), "---`nstatus: archived`n---", $utf8NoBom)

    $sessionFromClaudeCommand = Invoke-PowerShellHookCommand -Command ([string]$claudeSessionHandlers[0].command) -InputText '{}'
    Assert-True ($sessionFromClaudeCommand.Status -eq 0) ('Claude PowerShell hook command 실패: ' + $sessionFromClaudeCommand.Stderr)
    $sessionJson = $sessionFromClaudeCommand.Stdout | ConvertFrom-Json
    $context = [string]$sessionJson.hookSpecificOutput.additionalContext
    Assert-True ($context.Contains('260819_windows-task.md')) 'SessionStart가 진행 중 task를 주입하지 않았습니다.'
    Assert-True (-not $context.Contains('private.person@corp.invalid')) 'SessionStart가 민감 filename을 노출했습니다.'
    Assert-True (-not $context.Contains('archived.md')) 'SessionStart가 archived 문서를 주입했습니다.'
    Assert-True ($context.Contains('민감정보 가능성이 있는 파일명 1건 숨김')) 'SessionStart filename redaction count가 없습니다.'

    $sessionFromWindows = Invoke-WindowsHookCommand -Command ([string]$codexSessionHandlers[0].commandWindows) -InputText '{}'
    Assert-True ($sessionFromWindows.Status -eq 0) ('Codex commandWindows 실패: ' + $sessionFromWindows.Stderr)
    $windowsSessionJson = $sessionFromWindows.Stdout | ConvertFrom-Json
    Assert-True ([string]$windowsSessionJson.hookSpecificOutput.additionalContext -like '*260819_windows-task.md*') 'commandWindows가 custom vault를 로드하지 못했습니다.'

    $piiHook = Join-Path $runtime 'hooks\check-pii.ps1'
    $secretValue = 'not-for-output-1234567890'
    $outsidePath = Join-Path $testRoot 'outside.md'
    $outsidePayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = $outsidePath; content = ('password=' + $secretValue) }
    })
    $outsideResult = Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $outsidePayload
    Assert-True ($outsideResult.Status -eq 0 -and [string]::IsNullOrWhiteSpace($outsideResult.Stdout)) 'vault 밖 Write를 검사했습니다.'

    $emailValue = 'private.person@real-domain.invalid'
    $writePayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = (Join-Path $noteDirectory 'private.md'); content = $emailValue }
    })
    $writeResult = Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $writePayload
    Assert-DenyResult -Result $writeResult -SensitiveValue $emailValue -Message 'Windows Write PII deny 실패'

    $registeredSafePayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = (Join-Path $noteDirectory 'registered-safe.md'); content = 'safe content' }
    })
    $originalHookVault = $env:KB_VAULT
    $originalHookState = $env:AI_SESSION_KIT_STATE_DIR
    $staleVault = Join-Path $testRoot 'Stale Environment Vault'
    $staleState = Join-Path $testRoot 'Stale Environment State'
    [void](New-Item -ItemType Directory -Path $staleVault -Force)
    [void](New-Item -ItemType Directory -Path $staleState -Force)
    [System.IO.File]::WriteAllLines(
        (Join-Path $staleState 'install-state'),
        [string[]]@('ai-session-kit-state-v2', $staleVault, 'stale-session-command', 'stale-pii-command'),
        $utf8NoBom
    )
    $env:KB_VAULT = $staleVault
    $env:AI_SESSION_KIT_STATE_DIR = $staleState
    try {
        $staleEnvironmentSession = Invoke-WindowsHookCommand -Command ([string]$codexSessionHandlers[0].commandWindows) -InputText '{}'
        Assert-True ($staleEnvironmentSession.Status -eq 0) ('stale env SessionStart commandWindows 실패: ' + $staleEnvironmentSession.Stderr)
        $staleEnvironmentContext = [string](($staleEnvironmentSession.Stdout | ConvertFrom-Json).hookSpecificOutput.additionalContext)
        Assert-True ($staleEnvironmentContext.Contains('260819_windows-task.md')) 'explicit installed state가 stale SessionStart env보다 우선되지 않았습니다.'

        $claudeSafeResult = Invoke-PowerShellHookCommand -Command ([string]$claudePiiHandlers[0].command) -InputText $registeredSafePayload
        Assert-True ($claudeSafeResult.Status -eq 0 -and [string]::IsNullOrWhiteSpace($claudeSafeResult.Stdout)) 'Claude registered PII command safe allow 실패'
        $claudeDenyResult = Invoke-PowerShellHookCommand -Command ([string]$claudePiiHandlers[0].command) -InputText $writePayload
        Assert-DenyResult -Result $claudeDenyResult -SensitiveValue $emailValue -Message 'Claude registered PII command deny 실패'

        $codexSafeResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $registeredSafePayload
        Assert-True ($codexSafeResult.Status -eq 0 -and [string]::IsNullOrWhiteSpace($codexSafeResult.Stdout)) 'Codex commandWindows PII safe allow 실패'
        $codexDenyResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $writePayload
        Assert-DenyResult -Result $codexDenyResult -SensitiveValue $emailValue -Message 'Codex commandWindows PII deny 실패'

        $maliciousWorkingDirectory = Join-Path $testRoot 'malicious-command-cwd'
        [void](New-Item -ItemType Directory -Path $maliciousWorkingDirectory -Force)
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination (Join-Path $maliciousWorkingDirectory 'powershell.exe')
        $codexMaliciousCwdResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $writePayload -WorkingDirectory $maliciousWorkingDirectory
        Assert-DenyResult -Result $codexMaliciousCwdResult -SensitiveValue $emailValue -Message 'Codex commandWindows executable shadowing 방어 실패'
    }
    finally {
        $env:KB_VAULT = $originalHookVault
        $env:AI_SESSION_KIT_STATE_DIR = $originalHookState
    }

    $oversizedMarker = 'oversized-value-must-not-be-output'
    $oversizedPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{
            file_path = (Join-Path $noteDirectory 'oversized.md')
            content = (('x' * 5242881) + $oversizedMarker)
        }
    })
    $oversizedResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $oversizedPayload
    Assert-FailClosedResult -Result $oversizedResult -SensitiveValue $oversizedMarker -Message 'registered commandWindows oversized Write fail-closed 실패'
    $oversizedPayload = $null

    $lineBombMarker = 'line-bomb-value-must-not-be-output'
    $lineBombPatch = "*** Begin Patch`n*** Add File: 10.notes/line-bomb.md`n" + ("+`n" * 20001) + "+password=$lineBombMarker`n*** End Patch"
    $lineBombPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'apply_patch'
        cwd = $vaultA
        tool_input = [ordered]@{ command = $lineBombPatch }
    })
    $lineBombStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lineBombResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $lineBombPayload
    $lineBombStopwatch.Stop()
    Assert-FailClosedResult -Result $lineBombResult -SensitiveValue $lineBombMarker -Message 'registered commandWindows apply_patch line bomb fail-closed 실패'
    Assert-True ($lineBombStopwatch.Elapsed.TotalSeconds -lt 8) 'apply_patch line bomb 차단이 Codex timeout에 너무 가깝습니다.'
    $lineBombPatch = $null
    $lineBombPayload = $null

    foreach ($letter in @('Z', 'Y', 'X', 'W', 'V')) {
        $candidateDrive = $letter + ':'
        if (-not [System.IO.Directory]::Exists($candidateDrive + '\')) {
            & $substExecutable $candidateDrive $vaultA | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $substDrive = $candidateDrive
                break
            }
        }
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace($substDrive)) 'subst 테스트 drive를 만들지 못했습니다.'
    try {
        $substPayload = ConvertTo-CompactJson ([ordered]@{
            tool_name = 'Write'
            cwd = $testRoot
            tool_input = [ordered]@{
                file_path = (Join-Path ($substDrive + '\') '10.notes\subst-alias.md')
                content = ('secret=' + $secretValue)
            }
        })
        $claudeSubstResult = Invoke-PowerShellHookCommand -Command ([string]$claudePiiHandlers[0].command) -InputText $substPayload
        Assert-DenyResult -Result $claudeSubstResult -SensitiveValue $secretValue -Message 'Claude command subst vault alias deny 실패'
        $codexSubstResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $substPayload
        Assert-DenyResult -Result $codexSubstResult -SensitiveValue $secretValue -Message 'Codex commandWindows subst vault alias deny 실패'
    }
    finally {
        & $substExecutable $substDrive /D | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $substDrive = $null
        }
        else {
            throw 'subst test drive를 해제하지 못했습니다.'
        }
    }

    $vaultFullPath = [System.IO.Path]::GetFullPath($vaultA)
    $vaultDriveRoot = [System.IO.Path]::GetPathRoot($vaultFullPath)
    if ($vaultDriveRoot -match '^[A-Za-z]:\\$') {
        $loopbackVault = '\\localhost\' + $vaultDriveRoot.Substring(0, 1) + '$\' + $vaultFullPath.Substring($vaultDriveRoot.Length)
        if ([System.IO.Directory]::Exists($loopbackVault)) {
            $loopbackPayload = ConvertTo-CompactJson ([ordered]@{
                tool_name = 'Write'
                cwd = $testRoot
                tool_input = [ordered]@{
                    file_path = (Join-Path $loopbackVault '10.notes\loopback-alias.md')
                    content = ('secret=' + $secretValue)
                }
            })
            $loopbackResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $loopbackPayload
            Assert-FailClosedResult -Result $loopbackResult -SensitiveValue $secretValue -Message 'localhost UNC vault alias fail-closed 실패'
        }
    }

    $mixedPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = (Join-Path $noteDirectory 'mixed.md'); content = ('test@example.com and ' + $emailValue) }
    })
    Assert-DenyResult -Result (Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $mixedPayload) -SensitiveValue $emailValue -Message 'mixed email deny 실패'

    foreach ($targetPath in @((Join-Path $noteDirectory 'private.pdf'), (Join-Path $vaultA '_kit\private.md'))) {
        $payload = ConvertTo-CompactJson ([ordered]@{
            tool_name = 'Write'
            cwd = $testRoot
            tool_input = [ordered]@{ file_path = $targetPath; content = ('secret=' + $secretValue) }
        })
        Assert-DenyResult -Result (Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $payload) -SensitiveValue $secretValue -Message 'extension/_kit deny 실패'
    }

    $sensitiveName = Join-Path $noteDirectory 'customer-private.person@corp.invalid-new.md'
    $namePayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = $sensitiveName; content = 'safe content' }
    })
    Assert-DenyResult -Result (Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $namePayload) -SensitiveValue 'private.person@corp.invalid' -Message 'filename PII deny 실패'

    $editPath = Join-Path $noteDirectory 'edit.md'
    [System.IO.File]::WriteAllText($editPath, "api_key=placeholder`r`n", $utf8NoBom)
    $editPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Edit'
        cwd = $testRoot
        tool_input = [ordered]@{
            file_path = $editPath
            old_string = 'placeholder'
            new_string = $secretValue
            replace_all = $false
        }
    })
    Assert-DenyResult -Result (Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $editPayload) -SensitiveValue $secretValue -Message 'Edit prospective deny 실패'

    $nulPath = Join-Path $noteDirectory 'edit-nul.md'
    [System.IO.File]::WriteAllBytes($nulPath, [byte[]](110, 111, 116, 101, 61, 0, 120, 10, 97, 112, 105, 95, 107, 101, 121, 61, 112, 108, 97, 99, 101, 104, 111, 108, 100, 101, 114, 10))
    $nulPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Edit'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = $nulPath; old_string = 'placeholder'; new_string = $secretValue; replace_all = $false }
    })
    $nulResult = Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $nulPayload
    Assert-FailClosedResult -Result $nulResult -SensitiveValue $secretValue -Message 'NUL Edit source fail-closed 실패'

    $outsideDirectory = Join-Path $testRoot 'outside-directory'
    [void](New-Item -ItemType Directory -Path $outsideDirectory)
    $escapeJunction = Join-Path $noteDirectory 'escape'
    [void](New-Item -ItemType Junction -Path $escapeJunction -Target $outsideDirectory)
    $escapePayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = (Join-Path $escapeJunction 'private.md'); content = ('secret=' + $secretValue) }
    })
    $escapeResult = Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $escapePayload
    Assert-FailClosedResult -Result $escapeResult -SensitiveValue $secretValue -Message 'vault 내부 junction escape fail-closed 실패'

    $vaultAlias = Join-Path $testRoot 'vault-alias'
    [void](New-Item -ItemType Junction -Path $vaultAlias -Target $noteDirectory)
    $aliasPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = (Join-Path $vaultAlias 'alias.md'); content = ('secret=' + $secretValue) }
    })
    $aliasResult = Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $aliasPayload
    Assert-DenyResult -Result $aliasResult -SensitiveValue $secretValue -Message 'vault 외부 junction alias deny 실패'

    $hardLinkVaultPath = Join-Path $noteDirectory 'hardlink-source.md'
    $hardLinkOutsidePath = Join-Path $testRoot 'hardlink-alias.md'
    [System.IO.File]::WriteAllText($hardLinkVaultPath, 'placeholder', $utf8NoBom)
    [void](New-Item -ItemType HardLink -Path $hardLinkOutsidePath -Target $hardLinkVaultPath)
    $hardLinkWritePayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Write'
        cwd = $testRoot
        tool_input = [ordered]@{ file_path = $hardLinkOutsidePath; content = ('secret=' + $secretValue) }
    })
    $hardLinkWriteResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $hardLinkWritePayload
    Assert-FailClosedResult -Result $hardLinkWriteResult -SensitiveValue $secretValue -Message 'outside hard link Write fail-closed 실패'

    $hardLinkEditPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Edit'
        cwd = $testRoot
        tool_input = [ordered]@{
            file_path = $hardLinkOutsidePath
            old_string = 'placeholder'
            new_string = $secretValue
            replace_all = $false
        }
    })
    $hardLinkEditResult = Invoke-PowerShellHookCommand -Command ([string]$claudePiiHandlers[0].command) -InputText $hardLinkEditPayload
    Assert-FailClosedResult -Result $hardLinkEditResult -SensitiveValue $secretValue -Message 'outside hard link Edit fail-closed 실패'
    Assert-True ([System.IO.File]::ReadAllText($hardLinkVaultPath) -ceq 'placeholder') 'hard link hook 검사 후 vault 원본이 바뀌었습니다.'

    $expansionPath = Join-Path $noteDirectory 'replace-all-expansion.md'
    [System.IO.File]::WriteAllText($expansionPath, ('a' * (5242880 - 1024)), $utf8NoBom)
    $expansionMarker = 'replace-all-value-must-not-be-output'
    $expansionPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'Edit'
        cwd = $testRoot
        tool_input = [ordered]@{
            file_path = $expansionPath
            old_string = 'a'
            new_string = ('password=' + $expansionMarker)
            replace_all = $true
        }
    })
    $expansionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $expansionResult = Invoke-WindowsHookCommand -Command ([string]$codexPiiHandlers[0].commandWindows) -InputText $expansionPayload
    $expansionStopwatch.Stop()
    Assert-FailClosedResult -Result $expansionResult -SensitiveValue $expansionMarker -Message 'replace_all expansion fail-closed 실패'
    Assert-True ($expansionStopwatch.Elapsed.TotalSeconds -lt 8) 'replace_all expansion 차단이 Codex timeout에 너무 가깝습니다.'

    $patchText = "*** Begin Patch`n*** Add File: 10.notes/new-private.md`n+secret=$secretValue`n*** End Patch"
    $patchPayload = ConvertTo-CompactJson ([ordered]@{
        tool_name = 'apply_patch'
        cwd = $vaultA
        tool_input = [ordered]@{ command = $patchText }
    })
    $patchResult = Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $patchPayload
    Assert-DenyResult -Result $patchResult -SensitiveValue $secretValue -Message 'apply_patch deny 실패'

    $unknownPayload = ConvertTo-CompactJson ([ordered]@{ tool_name = 'FutureWrite'; cwd = $testRoot; tool_input = [ordered]@{} })
    $unknownResult = Invoke-ChildPowerShell -ScriptPath $piiHook -Arguments @('-VaultPath', $vaultA, '-StateDirectory', $stateDirectory) -InputText $unknownPayload
    Assert-FailClosedResult -Result $unknownResult -SensitiveValue 'FutureWrite' -Message 'unknown tool fail-closed 실패'

    $stateBeforeFailure = [System.IO.File]::ReadAllText($stateFile)
    $runtimeBeforeFailure = Get-TreeFingerprint $runtime
    $claudeBeforeFailure = [System.IO.File]::ReadAllText($claudeSettings)
    $codexBeforeFailure = [System.IO.File]::ReadAllText($codexHooks)
    $configLock = [System.IO.File]::Open($codexHooks, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $failedMove = Invoke-ChildPowerShell -ScriptPath $setupScript -Arguments @('-VaultPath', $vaultB)
        Assert-True ($failedMove.Status -ne 0) 'locked Codex config에서 setup migration이 성공했습니다.'
    }
    finally {
        $configLock.Dispose()
    }
    Assert-True ([System.IO.File]::ReadAllText($stateFile) -ceq $stateBeforeFailure) '실패한 migration이 install-state를 바꿨습니다.'
    Assert-True ((Get-TreeFingerprint $runtime) -ceq $runtimeBeforeFailure) '실패한 migration이 runtime을 바꿨습니다.'
    Assert-True ([System.IO.File]::ReadAllText($claudeSettings) -ceq $claudeBeforeFailure) '실패한 migration이 Claude config를 바꿨습니다.'
    Assert-True ([System.IO.File]::ReadAllText($codexHooks) -ceq $codexBeforeFailure) '실패한 migration이 Codex config를 바꿨습니다.'

    $moveInstall = Invoke-ChildPowerShell -ScriptPath $setupScript -Arguments @('-VaultPath', $vaultB)
    Assert-True ($moveInstall.Status -eq 0) ('vault migration 실패: ' + $moveInstall.Stderr + $moveInstall.Stdout)
    $rerun = Invoke-ChildPowerShell -ScriptPath $setupScript -Arguments @('-VaultPath', $vaultB)
    Assert-True ($rerun.Status -eq 0) ('idempotent setup 실패: ' + $rerun.Stderr + $rerun.Stdout)
    $rerunClaude = [System.IO.File]::ReadAllText($claudeSettings) | ConvertFrom-Json
    $rerunCodex = [System.IO.File]::ReadAllText($codexHooks) | ConvertFrom-Json
    Assert-True (@(Get-OwnedHandlers $rerunClaude 'SessionStart' 'session-context.ps1').Count -eq 1) 'rerun이 Claude hook을 중복 등록했습니다.'
    Assert-True (@(Get-OwnedHandlers $rerunCodex 'SessionStart' 'session-context.ps1').Count -eq 1) 'rerun이 Codex hook을 중복 등록했습니다.'

    $stateBeforeRuntimeLockFailure = [System.IO.File]::ReadAllText($stateFile)
    $runtimeBeforeRuntimeLockFailure = Get-TreeFingerprint $runtime
    $claudeBeforeRuntimeLockFailure = [System.IO.File]::ReadAllText($claudeSettings)
    $codexBeforeRuntimeLockFailure = [System.IO.File]::ReadAllText($codexHooks)
    $runtimeLockPath = Join-Path $runtime 'hooks\check-pii.ps1'
    $runtimeLock = [System.IO.File]::Open(
        $runtimeLockPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        $runtimeLockedUninstall = Invoke-ChildPowerShell -ScriptPath $uninstallScript
        Assert-True ($runtimeLockedUninstall.Status -ne 0) 'locked runtime file에서 uninstall이 성공했습니다.'
    }
    finally {
        $runtimeLock.Dispose()
    }
    Assert-True ([System.IO.File]::ReadAllText($stateFile) -ceq $stateBeforeRuntimeLockFailure) 'runtime lock uninstall 실패가 install-state를 바꿘습니다.'
    Assert-True ((Get-TreeFingerprint $runtime) -ceq $runtimeBeforeRuntimeLockFailure) 'runtime lock uninstall 실패가 runtime을 바꿘습니다.'
    Assert-True ([System.IO.File]::ReadAllText($claudeSettings) -ceq $claudeBeforeRuntimeLockFailure) 'runtime lock uninstall 실패가 Claude config를 바꿘습니다.'
    Assert-True ([System.IO.File]::ReadAllText($codexHooks) -ceq $codexBeforeRuntimeLockFailure) 'runtime lock uninstall 실패가 Codex config를 바꿘습니다.'

    $stateBeforeUninstallFailure = [System.IO.File]::ReadAllText($stateFile)
    $runtimeBeforeUninstallFailure = Get-TreeFingerprint $runtime
    $claudeBeforeUninstallFailure = [System.IO.File]::ReadAllText($claudeSettings)
    $codexBeforeUninstallFailure = [System.IO.File]::ReadAllText($codexHooks)
    $configLock = [System.IO.File]::Open($codexHooks, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $failedUninstall = Invoke-ChildPowerShell -ScriptPath $uninstallScript
        Assert-True ($failedUninstall.Status -ne 0) 'locked Codex config에서 uninstall이 성공했습니다.'
    }
    finally {
        $configLock.Dispose()
    }
    Assert-True ([System.IO.File]::ReadAllText($stateFile) -ceq $stateBeforeUninstallFailure) '실패한 uninstall이 install-state를 바꿨습니다.'
    Assert-True ((Get-TreeFingerprint $runtime) -ceq $runtimeBeforeUninstallFailure) '실패한 uninstall이 runtime을 바꿨습니다.'
    Assert-True ([System.IO.File]::ReadAllText($claudeSettings) -ceq $claudeBeforeUninstallFailure) '실패한 uninstall이 Claude config를 바꿨습니다.'
    Assert-True ([System.IO.File]::ReadAllText($codexHooks) -ceq $codexBeforeUninstallFailure) '실패한 uninstall이 Codex config를 바꿨습니다.'

    $uninstall = Invoke-ChildPowerShell -ScriptPath $uninstallScript
    Assert-True ($uninstall.Status -eq 0) ('uninstall.ps1 실패: ' + $uninstall.Stderr + $uninstall.Stdout)
    Assert-True (-not (Test-Path -LiteralPath $stateFile)) 'uninstall이 install-state를 남겼습니다.'
    Assert-True (-not (Test-Path -LiteralPath $runtime)) 'uninstall이 runtime을 남겼습니다.'
    Assert-True (Test-Path -LiteralPath $vaultB -PathType Container) 'uninstall이 vault를 지웠습니다.'
    foreach ($root in @((Join-Path $userHome '.claude\skills'), (Join-Path $userHome '.agents\skills'))) {
        foreach ($skill in $skills) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $skill))) 'uninstall이 owned junction을 남겼습니다.'
        }
    }
    $afterClaude = [System.IO.File]::ReadAllText($claudeSettings) | ConvertFrom-Json
    $afterCodex = [System.IO.File]::ReadAllText($codexHooks) | ConvertFrom-Json
    Assert-True (@(Get-HookHandlers $afterClaude 'SessionStart' | Where-Object { $_.command -eq 'Write-Output foreign-claude-session' }).Count -eq 1) 'uninstall이 Claude foreign hook을 지웠습니다.'
    Assert-True (@(Get-HookHandlers $afterCodex 'SessionStart' | Where-Object { $_.command -eq 'Write-Output foreign-codex-session' }).Count -eq 1) 'uninstall이 Codex foreign hook을 지웠습니다.'
    Assert-True (@(Get-OwnedHandlers $afterClaude 'SessionStart' 'session-context.ps1').Count -eq 0) 'uninstall이 Claude owned hook을 남겼습니다.'
    Assert-True (@(Get-OwnedHandlers $afterCodex 'SessionStart' 'session-context.ps1').Count -eq 0) 'uninstall이 Codex owned hook을 남겼습니다.'

    $conflictHome = Join-Path $testRoot 'Conflict Home'
    $conflictTarget = Join-Path $conflictHome '.agents\skills\session-start'
    [void](New-Item -ItemType Directory -Path $conflictTarget -Force)
    [System.IO.File]::WriteAllText((Join-Path $conflictTarget 'keep.txt'), 'keep', $utf8NoBom)
    $env:AI_SESSION_KIT_USER_HOME = $conflictHome
    $conflictInstall = Invoke-ChildPowerShell -ScriptPath $setupScript -Arguments @('-VaultPath', (Join-Path $testRoot 'Conflict Vault'))
    Assert-True ($conflictInstall.Status -ne 0) 'foreign skill directory conflict에서 setup이 성공했습니다.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $conflictTarget 'keep.txt')) -eq 'keep') 'foreign skill directory를 변경했습니다.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $conflictHome '.ai-session-kit\install-state'))) 'conflict setup이 install-state를 만들었습니다.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $conflictHome '.ai-session-kit\runtime'))) 'conflict setup이 runtime을 만들었습니다.'

    Write-Output 'PASS: native Windows installer and hooks'
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($substDrive)) {
        & $substExecutable $substDrive /D 2>$null | Out-Null
    }
    $env:AI_SESSION_KIT_USER_HOME = $originalOverride
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
