[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$VaultPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$StateMarker = 'ai-session-kit-state-v2'
$LegacyStateMarker = 'ai-session-kit-state-v1'
$RuntimeMarker = '.ai-session-kit-runtime'
$RuntimeMarkerContent = 'ai-session-kit-runtime-v1'
$SystemPowerShell = [System.IO.Path]::Combine(
  [Environment]::SystemDirectory,
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe'
)
$Skills = @(
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
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Fail {
  param([string]$Message)

  throw $Message
}

function Get-NormalizedPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
    Fail "절대경로가 아닙니다: $Path"
  }
  if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or
    $Path.StartsWith('\\.\', [System.StringComparison]::Ordinal) -or
    $Path.StartsWith('\??\', [System.StringComparison]::Ordinal) -or
    $Path -match '^[A-Za-z]:[^\\/]') {
    Fail "device path나 drive-relative path는 사용할 수 없습니다: $Path"
  }
  if ($Path.IndexOfAny([char[]]@([char]0, [char]9, [char]10, [char]13, [char]96)) -ge 0) {
    Fail "경로에 제어문자나 backtick을 사용할 수 없습니다: $Path"
  }
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetPathRoot($fullPath)
  if (-not [string]::Equals($fullPath, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
    $fullPath = $fullPath.TrimEnd([char[]]@(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    ))
  }
  return $fullPath
}

function Test-IsUnsupportedLocalProviderPath {
  param([string]$Path)

  if (-not $Path.StartsWith('\\', [System.StringComparison]::Ordinal)) {
    return $false
  }
  $providerPath = $Path.Substring(2)
  $separatorIndex = $providerPath.IndexOf('\')
  if ($separatorIndex -le 0) {
    return $false
  }
  $hostName = $providerPath.Substring(0, $separatorIndex)
  if ($hostName -in @('localhost', '127.0.0.1', '[::1]', 'wsl$', 'wsl.localhost')) {
    return $true
  }
  $machineName = [Environment]::MachineName
  return -not [string]::IsNullOrWhiteSpace($machineName) -and
    ($hostName.Equals($machineName, [System.StringComparison]::OrdinalIgnoreCase) -or
     $hostName.StartsWith($machineName + '.', [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-PathsEqual {
  param(
    [string]$Left,
    [string]$Right
  )

  if ([string]::IsNullOrEmpty($Left) -or [string]::IsNullOrEmpty($Right)) {
    return $false
  }
  try {
    return [string]::Equals(
      (Get-NormalizedPath $Left),
      (Get-NormalizedPath $Right),
      [System.StringComparison]::OrdinalIgnoreCase
    )
  }
  catch {
    return $false
  }
}

function Get-PathItem {
  param([string]$Path)

  return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Test-ReparsePoint {
  param($Item)

  if ($null -eq $Item) {
    return $false
  }
  return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-JunctionTarget {
  param([string]$Path)

  $item = Get-PathItem $Path
  if ($null -eq $item -or -not $item.PSIsContainer -or -not (Test-ReparsePoint $item)) {
    return $null
  }
  $linkType = [string]$item.LinkType
  if (-not [string]::Equals($linkType, 'Junction', [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  $rawTarget = $item.Target
  if ($rawTarget -is [System.Array]) {
    if ($rawTarget.Count -ne 1) {
      return $null
    }
    $rawTarget = $rawTarget[0]
  }
  $target = [string]$rawTarget
  if ($target.StartsWith('\??\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
    $target = '\\' + $target.Substring(8)
  }
  elseif ($target.StartsWith('\??\', [System.StringComparison]::OrdinalIgnoreCase)) {
    $target = $target.Substring(4)
  }
  elseif ($target.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
    $target = '\\' + $target.Substring(8)
  }
  elseif ($target.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
    $target = $target.Substring(4)
  }
  try {
    return Get-NormalizedPath $target
  }
  catch {
    return $null
  }
}

function Remove-Junction {
  param(
    [string]$Path,
    [string]$ExpectedTarget
  )

  $actualTarget = Get-JunctionTarget $Path
  if ($null -eq $actualTarget -or -not (Test-PathsEqual $actualTarget $ExpectedTarget)) {
    Fail "installer 소유 junction으로 확인되지 않습니다: $Path"
  }
  [System.IO.Directory]::Delete($Path)
}

function New-OwnedJunction {
  param(
    [string]$Path,
    [string]$Target
  )

  $parent = Split-Path -Parent $Path
  [System.IO.Directory]::CreateDirectory($parent) | Out-Null
  New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
  $actual = Get-JunctionTarget $Path
  if (-not (Test-PathsEqual $actual $Target)) {
    Fail "skill junction 검증 실패: $Path"
  }
}

function Write-Utf8File {
  param(
    [string]$Path,
    [string]$Content
  )

  [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Test-FileContentEqual {
  param(
    [string]$Left,
    [string]$Right
  )

  if (-not [System.IO.File]::Exists($Left) -or -not [System.IO.File]::Exists($Right)) {
    return $false
  }
  $leftBytes = [System.IO.File]::ReadAllBytes($Left)
  $rightBytes = [System.IO.File]::ReadAllBytes($Right)
  if ($leftBytes.Length -ne $rightBytes.Length) {
    return $false
  }
  for ($index = 0; $index -lt $leftBytes.Length; $index += 1) {
    if ($leftBytes[$index] -ne $rightBytes[$index]) {
      return $false
    }
  }
  return $true
}

function Move-FileAtomically {
  param(
    [string]$Source,
    [string]$Destination
  )

  if ([System.IO.File]::Exists($Destination)) {
    [System.IO.File]::Replace(
      $Source,
      $Destination,
      [System.Management.Automation.Language.NullString]::Value
    )
  }
  else {
    Move-Item -LiteralPath $Source -Destination $Destination
  }
}

function New-BackupFile {
  param([string]$Source)

  $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
  $backup = '{0}.bak-{1}-{2}' -f $Source, $timestamp, ([guid]::NewGuid().ToString('N').Substring(0, 8))
  Copy-Item -LiteralPath $Source -Destination $backup -Force
  return $backup
}

function Get-ObjectProperty {
  param(
    $Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return
  }
  return $property.Value
}

function Set-ObjectProperty {
  param(
    $Object,
    [string]$Name,
    $Value
  )

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
  }
  else {
    $property.Value = $Value
  }
}

function Test-HookConfigObject {
  param($Config)

  if ($null -eq $Config -or -not ($Config -is [pscustomobject])) {
    return $false
  }
  $hooks = Get-ObjectProperty $Config 'hooks'
  if ($null -eq $hooks) {
    return $true
  }
  if (-not ($hooks -is [pscustomobject])) {
    return $false
  }
  foreach ($eventName in @('SessionStart', 'PreToolUse', 'PostToolUse')) {
    $groupsProperty = $hooks.PSObject.Properties[$eventName]
    if ($null -eq $groupsProperty -or $null -eq $groupsProperty.Value) {
      continue
    }
    $groups = $groupsProperty.Value
    if (-not ($groups -is [System.Array])) {
      return $false
    }
    foreach ($group in $groups) {
      if ($null -eq $group -or -not ($group -is [pscustomobject])) {
        return $false
      }
      $handlersProperty = $group.PSObject.Properties['hooks']
      if ($null -eq $handlersProperty) {
        return $false
      }
      $handlers = $handlersProperty.Value
      if (-not ($handlers -is [System.Array])) {
        return $false
      }
      foreach ($handler in $handlers) {
        if ($null -eq $handler -or -not ($handler -is [pscustomobject])) {
          return $false
        }
        foreach ($commandName in @('command', 'commandWindows')) {
          $commandProperty = $handler.PSObject.Properties[$commandName]
          if ($null -ne $commandProperty -and $null -ne $commandProperty.Value -and -not ($commandProperty.Value -is [string])) {
            return $false
          }
        }
      }
    }
  }
  return $true
}

function Read-HookConfig {
  param([string]$Path)

  $item = Get-PathItem $Path
  if ($null -eq $item) {
    return [pscustomobject]@{}
  }
  if ($item.PSIsContainer -or (Test-ReparsePoint $item)) {
    Fail "유효한 JSON hook 설정이 아니어서 보존했습니다: $Path"
  }
  try {
    $raw = [System.IO.File]::ReadAllText($Path)
    $config = $raw | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    Fail "유효한 JSON hook 설정이 아니어서 보존했습니다: $Path"
  }
  if (-not (Test-HookConfigObject $config)) {
    Fail "지원하는 hook JSON 구조가 아니어서 보존했습니다: $Path"
  }
  return $config
}

function Test-OwnedCommand {
  param(
    $Handler,
    [string[]]$OwnedCommands
  )

  $command = Get-ObjectProperty $Handler 'command'
  if ($null -eq $command) {
    return $false
  }
  foreach ($owned in $OwnedCommands) {
    if (-not [string]::IsNullOrEmpty($owned) -and [string]::Equals([string]$command, $owned, [System.StringComparison]::Ordinal)) {
      return $true
    }
  }
  return $false
}

function Remove-OwnedHookGroups {
  param(
    [object[]]$Groups,
    [string[]]$OwnedCommands
  )

  $result = New-Object System.Collections.ArrayList
  foreach ($group in $Groups) {
    $handlers = @(Get-ObjectProperty $group 'hooks')
    $remaining = New-Object System.Collections.ArrayList
    foreach ($handler in $handlers) {
      if (-not (Test-OwnedCommand $handler $OwnedCommands)) {
        [void]$remaining.Add($handler)
      }
    }
    if ($remaining.Count -eq $handlers.Count) {
      [void]$result.Add($group)
    }
    elseif ($remaining.Count -gt 0) {
      Set-ObjectProperty $group 'hooks' @($remaining.ToArray())
      [void]$result.Add($group)
    }
  }
  return @($result.ToArray())
}

function Quote-BashArgument {
  param([string]$Value)

  return "'" + $Value.Replace("'", "'\''") + "'"
}

function New-HookCommand {
  param(
    [string]$ScriptPath,
    [string]$Vault,
    [string]$StateDirectory,
    [ValidateSet('PowerShell', 'Windows')]
    [string]$Style
  )

  $hookFileName = Split-Path -Leaf $ScriptPath
  if ($hookFileName -notin @('session-context.ps1', 'check-pii.ps1')) {
    Fail "지원하지 않는 Windows hook 파일입니다: $hookFileName"
  }
  $scriptBody = '$userHome=$env:AI_SESSION_KIT_USER_HOME;if([string]::IsNullOrWhiteSpace($userHome)){$userHome=[Environment]::GetFolderPath(''UserProfile'')};$stateDirectory=[IO.Path]::Combine($userHome,''.ai-session-kit'');& ([IO.Path]::Combine($stateDirectory,''runtime'',''hooks'',''' + $hookFileName + ''')) -StateDirectory $stateDirectory;exit $LASTEXITCODE'
  if ($Style -eq 'Windows') {
    return '"' + $script:SystemPowerShell + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + $scriptBody + '"'
  }
  return $scriptBody
}

function Configure-Hooks {
  param(
    [string]$Path,
    [string]$SessionMatcher,
    [string]$PiiMatcher,
    [string]$SessionCommand,
    [string]$PiiCommand,
    [string]$SessionWindowsCommand,
    [string]$PiiWindowsCommand,
    [string[]]$PreviousSessionCommands,
    [string[]]$PreviousPiiCommands,
    [bool]$UsePowerShellShell,
    [bool]$IncludeWindowsOverride
  )

  $config = Read-HookConfig $Path
  $hooks = Get-ObjectProperty $config 'hooks'
  if ($null -eq $hooks) {
    $hooks = [pscustomobject]@{}
    Set-ObjectProperty $config 'hooks' $hooks
  }

  $sessionGroups = @(Get-ObjectProperty $hooks 'SessionStart')
  $sessionGroups = @(Remove-OwnedHookGroups $sessionGroups $PreviousSessionCommands)
  $sessionHandler = [ordered]@{
    type = 'command'
    command = $SessionCommand
    timeout = 10
    statusMessage = '지식베이스 컨텍스트 로딩...'
  }
  if ($IncludeWindowsOverride) {
    $sessionHandler['commandWindows'] = $SessionWindowsCommand
  }
  if ($UsePowerShellShell) {
    $sessionHandler['shell'] = 'powershell'
  }
  $sessionGroups += [pscustomobject]@{
    matcher = $SessionMatcher
    hooks = @([pscustomobject]$sessionHandler)
  }
  Set-ObjectProperty $hooks 'SessionStart' @($sessionGroups)

  $piiGroups = @(Get-ObjectProperty $hooks 'PreToolUse')
  $piiGroups = @(Remove-OwnedHookGroups $piiGroups $PreviousPiiCommands)
  $piiHandler = [ordered]@{
    type = 'command'
    command = $PiiCommand
    timeout = 10
  }
  if ($IncludeWindowsOverride) {
    $piiHandler['commandWindows'] = $PiiWindowsCommand
  }
  if ($UsePowerShellShell) {
    $piiHandler['shell'] = 'powershell'
  }
  $piiGroups += [pscustomobject]@{
    matcher = $PiiMatcher
    hooks = @([pscustomobject]$piiHandler)
  }
  Set-ObjectProperty $hooks 'PreToolUse' @($piiGroups)

  $postGroups = Get-ObjectProperty $hooks 'PostToolUse'
  if ($null -ne $postGroups) {
    Set-ObjectProperty $hooks 'PostToolUse' @(Remove-OwnedHookGroups @($postGroups) $PreviousPiiCommands)
  }

  if (-not (Test-HookConfigObject $config)) {
    Fail "hook 설정 병합 결과가 유효하지 않습니다: $Path"
  }
  return $config
}

function Write-ConfigAtomically {
  param(
    [string]$Path,
    $Config
  )

  $directory = Split-Path -Parent $Path
  [System.IO.Directory]::CreateDirectory($directory) | Out-Null
  $temporary = Join-Path $directory ('.hooks.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
  try {
    $json = $Config | ConvertTo-Json -Depth 100
    Write-Utf8File $temporary ($json + [Environment]::NewLine)
    if ([System.IO.File]::Exists($Path) -and (Test-FileContentEqual $Path $temporary)) {
      Remove-Item -LiteralPath $temporary -Force
      return $null
    }
    $backup = $null
    if ([System.IO.File]::Exists($Path)) {
      $backup = New-BackupFile $Path
    }
    Move-FileAtomically $temporary $Path
    return $backup
  }
  catch {
    if ([System.IO.File]::Exists($temporary)) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}

function Test-HookInstallation {
  param(
    [string]$Path,
    [string]$SessionCommand,
    [string]$PiiCommand,
    [string]$SessionWindowsCommand,
    [string]$PiiWindowsCommand,
    [bool]$RequirePowerShellShell,
    [bool]$RequireWindowsOverride
  )

  $config = Read-HookConfig $Path
  $hooks = Get-ObjectProperty $config 'hooks'
  $sessionCount = 0
  $sessionWindowsCount = 0
  $sessionPowerShellCount = 0
  foreach ($group in @(Get-ObjectProperty $hooks 'SessionStart')) {
    foreach ($handler in @(Get-ObjectProperty $group 'hooks')) {
      if ([string]::Equals([string](Get-ObjectProperty $handler 'command'), $SessionCommand, [System.StringComparison]::Ordinal)) {
        $sessionCount += 1
        if ([string]::Equals([string](Get-ObjectProperty $handler 'commandWindows'), $SessionWindowsCommand, [System.StringComparison]::Ordinal)) {
          $sessionWindowsCount += 1
        }
        if ([string]::Equals([string](Get-ObjectProperty $handler 'shell'), 'powershell', [System.StringComparison]::OrdinalIgnoreCase)) {
          $sessionPowerShellCount += 1
        }
      }
    }
  }
  $piiCount = 0
  $piiWindowsCount = 0
  $piiPowerShellCount = 0
  foreach ($group in @(Get-ObjectProperty $hooks 'PreToolUse')) {
    foreach ($handler in @(Get-ObjectProperty $group 'hooks')) {
      if ([string]::Equals([string](Get-ObjectProperty $handler 'command'), $PiiCommand, [System.StringComparison]::Ordinal)) {
        $piiCount += 1
        if ([string]::Equals([string](Get-ObjectProperty $handler 'commandWindows'), $PiiWindowsCommand, [System.StringComparison]::Ordinal)) {
          $piiWindowsCount += 1
        }
        if ([string]::Equals([string](Get-ObjectProperty $handler 'shell'), 'powershell', [System.StringComparison]::OrdinalIgnoreCase)) {
          $piiPowerShellCount += 1
        }
      }
    }
  }
  foreach ($group in @(Get-ObjectProperty $hooks 'PostToolUse')) {
    foreach ($handler in @(Get-ObjectProperty $group 'hooks')) {
      if ([string]::Equals([string](Get-ObjectProperty $handler 'command'), $PiiCommand, [System.StringComparison]::Ordinal)) {
        return $false
      }
    }
  }
  if ($sessionCount -ne 1 -or $piiCount -ne 1) {
    return $false
  }
  if ($RequireWindowsOverride -and ($sessionWindowsCount -ne 1 -or $piiWindowsCount -ne 1)) {
    return $false
  }
  if ($RequirePowerShellShell -and ($sessionPowerShellCount -ne 1 -or $piiPowerShellCount -ne 1)) {
    return $false
  }
  return $true
}

function Copy-DirectoryContents {
  param(
    [string]$Source,
    [string]$Destination
  )

  [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
  }
}

function Restore-FileSnapshot {
  param(
    [string]$Path,
    [string]$Snapshot,
    [bool]$Existed
  )

  if ($Existed) {
    if ([System.IO.File]::Exists($Path) -and (Test-FileContentEqual $Path $Snapshot)) {
      return
    }
    Copy-Item -LiteralPath $Snapshot -Destination $Path -Force
  }
  else {
    $item = Get-PathItem $Path
    if ($null -ne $item -and -not $item.PSIsContainer -and -not (Test-ReparsePoint $item)) {
      Remove-Item -LiteralPath $Path -Force
    }
  }
}

$kit = Get-NormalizedPath (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not [System.IO.File]::Exists($SystemPowerShell)) {
  Fail "Windows PowerShell 5.1 executable을 찾을 수 없습니다: $SystemPowerShell"
}
$userHomeValue = $env:AI_SESSION_KIT_USER_HOME
$usingHomeOverride = -not [string]::IsNullOrWhiteSpace($userHomeValue)
if (-not $usingHomeOverride) {
  $userHomeValue = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}
$userHome = Get-NormalizedPath $userHomeValue
if ([string]::IsNullOrWhiteSpace($VaultPath)) {
  $VaultPath = Join-Path $userHome 'KnowledgeBase'
}
$vault = Get-NormalizedPath $VaultPath
if ([string]::Equals($vault, [System.IO.Path]::GetPathRoot($vault), [System.StringComparison]::OrdinalIgnoreCase)) {
  Fail '파일시스템 루트는 vault로 사용할 수 없습니다'
}
if (Test-IsUnsupportedLocalProviderPath $vault) {
  Fail 'native Windows에서는 local drive 경로를 vault로 사용하세요. WSL 경로는 WSL 안에서 setup.sh로 설치합니다.'
}

$claudeDirectory = Join-Path $userHome '.claude'
$codexDirectory = Join-Path $userHome '.codex'
$claudeSettings = Join-Path $claudeDirectory 'settings.json'
$codexHooks = Join-Path $codexDirectory 'hooks.json'
$stateDirectory = Join-Path $userHome '.ai-session-kit'
$stateFile = Join-Path $stateDirectory 'install-state'
$runtimeDirectory = Join-Path $stateDirectory 'runtime'
$skillRoots = @(
  (Join-Path $claudeDirectory 'skills'),
  (Join-Path $userHome '.agents\skills')
)

$stateDirectoryItem = Get-PathItem $stateDirectory
if ($null -ne $stateDirectoryItem -and (-not $stateDirectoryItem.PSIsContainer -or (Test-ReparsePoint $stateDirectoryItem))) {
  Fail "로컬 설치 상태 경로가 안전한 폴더가 아닙니다: $stateDirectory"
}
[System.IO.Directory]::CreateDirectory($stateDirectory) | Out-Null

$oldVault = ''
$previousSessionCommand = ''
$previousPiiCommand = ''
$stateItem = Get-PathItem $stateFile
if ($null -ne $stateItem) {
  if ($stateItem.PSIsContainer -or (Test-ReparsePoint $stateItem)) {
    Fail "설치 상태 파일이 손상되었습니다: $stateFile"
  }
  $stateLines = @([System.IO.File]::ReadAllLines($stateFile))
  if ($stateLines.Count -lt 2 -or ($stateLines[0] -ne $StateMarker -and $stateLines[0] -ne $LegacyStateMarker)) {
    Fail "설치 상태 파일 형식을 확인할 수 없습니다: $stateFile"
  }
  $oldVault = Get-NormalizedPath $stateLines[1]
  if ($stateLines.Count -ge 3) {
    $previousSessionCommand = $stateLines[2]
  }
  if ($stateLines.Count -ge 4) {
    $previousPiiCommand = $stateLines[3]
  }
  if ($stateLines[0] -eq $StateMarker -and ([string]::IsNullOrEmpty($previousSessionCommand) -or [string]::IsNullOrEmpty($previousPiiCommand))) {
    Fail "설치 상태에 exact hook command가 없습니다: $stateFile"
  }
}

$requiredSources = @(
  (Join-Path $kit 'vault-template'),
  (Join-Path $kit 'hooks\session-context.ps1'),
  (Join-Path $kit 'hooks\check-pii.ps1'),
  (Join-Path $kit 'scripts\kb_lint.py'),
  (Join-Path $kit 'scripts\kb-lint.ps1')
)
foreach ($requiredSource in $requiredSources) {
  if (-not (Test-Path -LiteralPath $requiredSource)) {
    Fail "설치 파일이 누락되었습니다: $requiredSource"
  }
}
foreach ($skill in $Skills) {
  $skillSource = Join-Path (Join-Path $kit 'skills') $skill
  if (-not [System.IO.Directory]::Exists($skillSource)) {
    Fail "설치할 skill이 누락되었습니다: $skillSource"
  }
}

$vaultItem = Get-PathItem $vault
if ($null -ne $vaultItem -and (-not $vaultItem.PSIsContainer -or (Test-ReparsePoint $vaultItem))) {
  Fail "vault 경로가 안전한 폴더가 아닙니다: $vault"
}
$templateRoot = Join-Path $kit 'vault-template'
foreach ($sourceDirectory in Get-ChildItem -LiteralPath $templateRoot -Directory -Recurse -Force) {
  $relative = $sourceDirectory.FullName.Substring($templateRoot.Length).TrimStart([char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  ))
  $destination = Join-Path $vault $relative
  $destinationItem = Get-PathItem $destination
  if ($null -ne $destinationItem -and (-not $destinationItem.PSIsContainer -or (Test-ReparsePoint $destinationItem))) {
    Fail "필수 vault 폴더 자리에 안전하지 않은 항목이 있습니다: $destination"
  }
}
foreach ($sourceFile in Get-ChildItem -LiteralPath $templateRoot -File -Recurse -Force) {
  $relative = $sourceFile.FullName.Substring($templateRoot.Length).TrimStart([char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  ))
  $destination = Join-Path $vault $relative
  $destinationItem = Get-PathItem $destination
  if ($null -ne $destinationItem -and ($destinationItem.PSIsContainer -or (Test-ReparsePoint $destinationItem))) {
    Fail "필수 vault 파일 자리에 안전하지 않은 항목이 있습니다: $destination"
  }
}

[System.IO.Directory]::CreateDirectory($vault) | Out-Null
$legacyEntrypoint = Join-Path $kit 'legacy-vault-entrypoint-v0.md'
foreach ($entrypointName in @('CLAUDE.md', 'AGENTS.md')) {
  $destination = Join-Path $vault $entrypointName
  $current = Join-Path $templateRoot $entrypointName
  if ([System.IO.File]::Exists($legacyEntrypoint) -and [System.IO.File]::Exists($destination) -and [System.IO.File]::Exists($current) -and (Test-FileContentEqual $destination $legacyEntrypoint)) {
    $backup = New-BackupFile $destination
    Copy-Item -LiteralPath $current -Destination $destination -Force
    Write-Host "✓ 구버전 기본 $entrypointName 을 갱신했습니다 (백업: $backup)"
  }
}

$mergedCount = 0
foreach ($sourceDirectory in Get-ChildItem -LiteralPath $templateRoot -Directory -Recurse -Force) {
  $relative = $sourceDirectory.FullName.Substring($templateRoot.Length).TrimStart([char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  ))
  [System.IO.Directory]::CreateDirectory((Join-Path $vault $relative)) | Out-Null
}
foreach ($sourceFile in Get-ChildItem -LiteralPath $templateRoot -File -Recurse -Force) {
  $relative = $sourceFile.FullName.Substring($templateRoot.Length).TrimStart([char[]]@(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  ))
  $destination = Join-Path $vault $relative
  if ($null -eq (Get-PathItem $destination)) {
    $parent = Split-Path -Parent $destination
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    Copy-Item -LiteralPath $sourceFile.FullName -Destination $destination
    $mergedCount += 1
  }
}
$vault = Get-NormalizedPath $vault
Write-Host "✓ vault 기본 구조 확인 (누락 파일 $mergedCount 개 추가, 기존 내용 보존)"
Write-Host "지식 vault: $vault"

$runtimeItem = Get-PathItem $runtimeDirectory
if ($null -ne $runtimeItem) {
  $runtimeMarkerPath = Join-Path $runtimeDirectory $RuntimeMarker
  $runtimeMarkerItem = Get-PathItem $runtimeMarkerPath
  $runtimeMarkerValue = ''
  if ($null -ne $runtimeMarkerItem -and -not $runtimeMarkerItem.PSIsContainer -and -not (Test-ReparsePoint $runtimeMarkerItem)) {
    $runtimeMarkerValue = [System.IO.File]::ReadAllText($runtimeMarkerPath).TrimEnd([char[]]@([char]13, [char]10))
  }
  if (-not $runtimeItem.PSIsContainer -or (Test-ReparsePoint $runtimeItem) -or $runtimeMarkerValue -ne $RuntimeMarkerContent) {
    Fail "installer 소유 marker가 없는 runtime을 보존했습니다: $runtimeDirectory"
  }
  foreach ($runtimeNode in Get-ChildItem -LiteralPath $runtimeDirectory -Recurse -Force) {
    if (Test-ReparsePoint $runtimeNode) {
      Fail "local runtime에 reparse point가 있어 보존했습니다: $($runtimeNode.FullName)"
    }
  }
}

$skillSnapshots = New-Object System.Collections.ArrayList
$hasSkillConflict = $false
foreach ($skillRoot in $skillRoots) {
  foreach ($skill in $Skills) {
    $target = Join-Path $skillRoot $skill
    $expected = Join-Path (Join-Path $runtimeDirectory 'skills') $skill
    $legacyExpected = ''
    if (-not [string]::IsNullOrEmpty($oldVault)) {
      $legacyExpected = Join-Path (Join-Path $oldVault '_kit\skills') $skill
    }
    $item = Get-PathItem $target
    if ($null -eq $item) {
      [void]$skillSnapshots.Add([pscustomobject]@{ Path = $target; Existed = $false; Target = '' })
      continue
    }
    $actual = Get-JunctionTarget $target
    if ($null -eq $actual -or (-not (Test-PathsEqual $actual $expected) -and ([string]::IsNullOrEmpty($legacyExpected) -or -not (Test-PathsEqual $actual $legacyExpected)))) {
      [Console]::Error.WriteLine("✗ 기존 파일/폴더 또는 unrelated link를 보존합니다: $target")
      $hasSkillConflict = $true
      continue
    }
    [void]$skillSnapshots.Add([pscustomobject]@{ Path = $target; Existed = $true; Target = $actual })
  }
}
if ($hasSkillConflict) {
  Fail '기존 skill 항목과 충돌하여 junction 설치를 중단했습니다'
}

$claudeConfig = Read-HookConfig $claudeSettings
$codexConfig = Read-HookConfig $codexHooks
$claudeHadConfig = [System.IO.File]::Exists($claudeSettings)
$codexHadConfig = [System.IO.File]::Exists($codexHooks)
$claudeSnapshot = Join-Path $stateDirectory ('.hook-snapshot.{0}' -f [guid]::NewGuid().ToString('N'))
$codexSnapshot = Join-Path $stateDirectory ('.hook-snapshot.{0}' -f [guid]::NewGuid().ToString('N'))
if ($claudeHadConfig) {
  Copy-Item -LiteralPath $claudeSettings -Destination $claudeSnapshot
}
if ($codexHadConfig) {
  Copy-Item -LiteralPath $codexHooks -Destination $codexSnapshot
}

$stage = Join-Path $stateDirectory ('.runtime-stage.{0}' -f [guid]::NewGuid().ToString('N'))
$runtimeOld = ''
$runtimeSwapped = $false
$runtimeOldMoved = $false
$transactionStarted = $false
$transactionCommitted = $false
$rollbackFailed = $false
$stateTemporary = ''

try {
  [System.IO.Directory]::CreateDirectory((Join-Path $stage 'hooks')) | Out-Null
  [System.IO.Directory]::CreateDirectory((Join-Path $stage 'scripts')) | Out-Null
  [System.IO.Directory]::CreateDirectory((Join-Path $stage 'skills')) | Out-Null
  Copy-Item -LiteralPath (Join-Path $kit 'hooks\session-context.ps1') -Destination (Join-Path $stage 'hooks\session-context.ps1')
  Copy-Item -LiteralPath (Join-Path $kit 'hooks\check-pii.ps1') -Destination (Join-Path $stage 'hooks\check-pii.ps1')
  Copy-Item -LiteralPath (Join-Path $kit 'scripts\kb_lint.py') -Destination (Join-Path $stage 'scripts\kb_lint.py')
  Copy-Item -LiteralPath (Join-Path $kit 'scripts\kb-lint.ps1') -Destination (Join-Path $stage 'scripts\kb-lint.ps1')

  $powerShellLiteral = "'" + $SystemPowerShell.Replace("'", "''") + "'"
  $lintCommand = '& ' + $powerShellLiteral + ' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ([IO.Path]::Combine([Environment]::GetFolderPath(''UserProfile''), ''.ai-session-kit'', ''runtime'', ''scripts'', ''kb-lint.ps1''))"'
  foreach ($skill in $Skills) {
    $source = Join-Path (Join-Path $kit 'skills') $skill
    $destination = Join-Path (Join-Path $stage 'skills') $skill
    Copy-DirectoryContents $source $destination
    $skillFile = Join-Path $destination 'SKILL.md'
    $skillContent = [System.IO.File]::ReadAllText($skillFile)
    $skillContent = $skillContent.Replace('~/KnowledgeBase', $vault).Replace('__KB_LINT_COMMAND__', $lintCommand)
    Write-Utf8File $skillFile $skillContent
  }
  Write-Utf8File (Join-Path $stage $RuntimeMarker) ($RuntimeMarkerContent + [Environment]::NewLine)

  $transactionStarted = $true
  if ([System.IO.Directory]::Exists($runtimeDirectory)) {
    $runtimeOld = Join-Path $stateDirectory ('.runtime-old.{0}' -f [guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $runtimeDirectory -Destination $runtimeOld
    $runtimeOldMoved = $true
  }
  Move-Item -LiteralPath $stage -Destination $runtimeDirectory
  $stage = ''
  $runtimeSwapped = $true
  Write-Host "✓ 스킬 $($Skills.Count)개 + 훅 2개 + lint 스크립트 → $runtimeDirectory"

  $sessionScript = Join-Path $runtimeDirectory 'hooks\session-context.ps1'
  $piiScript = Join-Path $runtimeDirectory 'hooks\check-pii.ps1'
  $sessionCommand = New-HookCommand $sessionScript $vault $stateDirectory 'PowerShell'
  $piiCommand = New-HookCommand $piiScript $vault $stateDirectory 'PowerShell'
  $sessionWindowsCommand = New-HookCommand $sessionScript $vault $stateDirectory 'Windows'
  $piiWindowsCommand = New-HookCommand $piiScript $vault $stateDirectory 'Windows'

  $legacySessionBare = ''
  $legacyPiiBare = ''
  $legacySessionCommand = ''
  $legacyPiiCommand = ''
  if (-not [string]::IsNullOrEmpty($oldVault)) {
    $legacySessionBare = Join-Path $oldVault '_kit\hooks\session-context.sh'
    $legacyPiiBare = Join-Path $oldVault '_kit\hooks\check-pii.sh'
    $legacySessionCommand = 'AI_SESSION_KIT_HOOK=session-context bash ' + (Quote-BashArgument $legacySessionBare)
    $legacyPiiCommand = 'AI_SESSION_KIT_HOOK=check-pii bash ' + (Quote-BashArgument $legacyPiiBare)
  }
  $ownedSessionCommands = @($sessionCommand, $previousSessionCommand, $legacySessionBare, $legacySessionCommand) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique
  $ownedPiiCommands = @($piiCommand, $previousPiiCommand, $legacyPiiBare, $legacyPiiCommand) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique

  $claudeConfig = Configure-Hooks $claudeSettings 'startup|resume|clear|compact' 'Write|Edit' $sessionCommand $piiCommand $sessionWindowsCommand $piiWindowsCommand $ownedSessionCommands $ownedPiiCommands $true $false
  $codexConfig = Configure-Hooks $codexHooks 'startup|resume|clear|compact' 'apply_patch|Edit|Write' $sessionCommand $piiCommand $sessionWindowsCommand $piiWindowsCommand $ownedSessionCommands $ownedPiiCommands $false $true
  $claudeBackup = Write-ConfigAtomically $claudeSettings $claudeConfig
  $codexBackup = Write-ConfigAtomically $codexHooks $codexConfig

  if (-not (Test-HookInstallation $claudeSettings $sessionCommand $piiCommand $sessionWindowsCommand $piiWindowsCommand $true $false)) {
    Fail "Claude hook 검증 실패: $claudeSettings"
  }
  if (-not (Test-HookInstallation $codexHooks $sessionCommand $piiCommand $sessionWindowsCommand $piiWindowsCommand $false $true)) {
    Fail "Codex hook 검증 실패: $codexHooks"
  }
  Write-Host '✓ Claude + Codex SessionStart/PreToolUse hook 등록·검증 완료'

  foreach ($snapshot in $skillSnapshots) {
    $target = [string]$snapshot.Path
    $expected = Join-Path (Join-Path $runtimeDirectory 'skills') (Split-Path -Leaf $target)
    $existingItem = Get-PathItem $target
    $existingTarget = Get-JunctionTarget $target
    if ([bool]$snapshot.Existed) {
      if ($null -eq $existingTarget -or -not (Test-PathsEqual $existingTarget ([string]$snapshot.Target))) {
        Fail "skill junction이 preflight 이후 변경되어 보존했습니다: $target"
      }
      if (-not (Test-PathsEqual $existingTarget $expected)) {
        Remove-Junction $target ([string]$snapshot.Target)
      }
    }
    elseif ($null -ne $existingItem) {
      Fail "skill 경로가 preflight 이후 생성되어 보존했습니다: $target"
    }
    if ($null -eq (Get-PathItem $target)) {
      New-OwnedJunction $target $expected
    }
    if (-not (Test-PathsEqual (Get-JunctionTarget $target) $expected)) {
      Fail "skill junction 검증 실패: $target"
    }
  }
  Write-Host '✓ Claude + Codex skill junction 설치·검증 완료'

  $stateTemporary = Join-Path $stateDirectory ('.install-state.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
  $stateContent = @($StateMarker, $vault, $sessionCommand, $piiCommand) -join "`n"
  Write-Utf8File $stateTemporary ($stateContent + "`n")
  Move-FileAtomically $stateTemporary $stateFile
  $stateTemporary = ''
  $transactionCommitted = $true

  if (-not [string]::IsNullOrEmpty($runtimeOld) -and [System.IO.Directory]::Exists($runtimeOld)) {
    try {
      Remove-Item -LiteralPath $runtimeOld -Recurse -Force
      $runtimeOld = ''
    }
    catch {
      Write-Warning "설치는 완료됐지만 이전 runtime 임시 폴더를 지우지 못했습니다: $runtimeOld"
    }
  }

  $smokeOutput = '{}' | & $SystemPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $sessionScript -VaultPath $vault -StateDirectory $stateDirectory 2>$null
  if ([string]::IsNullOrWhiteSpace(($smokeOutput -join [Environment]::NewLine))) {
    Write-Warning "설치는 완료됐지만 SessionStart hook이 아무것도 출력하지 않았습니다: $sessionScript"
  }
  else {
    Write-Host '✓ SessionStart hook 스모크 테스트 통과'
  }

  if (-not $usingHomeOverride) {
    try {
      & $SystemPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $runtimeDirectory 'scripts\kb-lint.ps1') | Out-Host
      Write-Host '✓ lint 스모크 테스트 실행 완료'
    }
    catch {
      Write-Warning '설치는 완료됐지만 lint 검증을 실행하지 못했습니다. session-end skill에서 다시 실행하세요.'
    }
  }
  else {
    Write-Host '· test HOME override — lint smoke 생략'
  }

  Write-Host ''
  Write-Host '설치 후 확인:'
  Write-Host '- Claude: 새 세션에서 SessionStart hook이 진행 중 작업을 로드합니다.'
  Write-Host '- Codex: /hooks에서 새 command hook 정의를 검토하고 trust해야 실행됩니다.'
  Write-Host '- 세션을 마칠 때 "세션 종료해줘"라고 요청해 session-end skill을 실행하세요.'
}
catch {
  $installError = $_.Exception.Message
  if ($transactionStarted -and -not $transactionCommitted) {
    $localRollbackFailed = $false
    foreach ($configRestore in @(
      [pscustomobject]@{ Path = $claudeSettings; Snapshot = $claudeSnapshot; Existed = $claudeHadConfig },
      [pscustomobject]@{ Path = $codexHooks; Snapshot = $codexSnapshot; Existed = $codexHadConfig }
    )) {
      try {
        Restore-FileSnapshot ([string]$configRestore.Path) ([string]$configRestore.Snapshot) ([bool]$configRestore.Existed)
      }
      catch {
        $localRollbackFailed = $true
      }
    }

    foreach ($snapshot in $skillSnapshots) {
      try {
        $target = [string]$snapshot.Path
        $currentTarget = Get-JunctionTarget $target
        $expected = Join-Path (Join-Path $runtimeDirectory 'skills') (Split-Path -Leaf $target)
        $shouldExist = [bool]$snapshot.Existed
        $installerCreated = $null -ne $currentTarget -and
          (Test-PathsEqual $currentTarget $expected) -and
          (-not $shouldExist -or -not (Test-PathsEqual ([string]$snapshot.Target) $expected))
        if ($installerCreated) {
          Remove-Junction $target $expected
        }
        elseif ($null -eq $currentTarget -and $null -ne (Get-PathItem $target)) {
          Fail "rollback 중 foreign skill 항목을 발견했습니다: $target"
        }
        elseif ($null -ne $currentTarget -and
          ((-not $shouldExist) -or -not (Test-PathsEqual $currentTarget ([string]$snapshot.Target)))) {
          Fail "rollback 중 변경된 foreign skill junction을 보존했습니다: $target"
        }
      }
      catch {
        $localRollbackFailed = $true
      }
    }

    try {
      if ($runtimeSwapped -and [System.IO.Directory]::Exists($runtimeDirectory)) {
        Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force
      }
      if ($runtimeOldMoved -and -not [string]::IsNullOrEmpty($runtimeOld) -and [System.IO.Directory]::Exists($runtimeOld)) {
        Move-Item -LiteralPath $runtimeOld -Destination $runtimeDirectory
        $runtimeOld = ''
        $runtimeOldMoved = $false
      }
    }
    catch {
      $localRollbackFailed = $true
    }

    foreach ($snapshot in $skillSnapshots) {
      try {
        $target = [string]$snapshot.Path
        if ([bool]$snapshot.Existed -and $null -eq (Get-PathItem $target)) {
          New-OwnedJunction $target ([string]$snapshot.Target)
        }
      }
      catch {
        $localRollbackFailed = $true
      }
    }

    if ($localRollbackFailed) {
      $rollbackFailed = $true
      [Console]::Error.WriteLine('✗ 설치 rollback 일부가 실패했습니다. install-state를 보존했으니 setup.ps1을 다시 실행하세요.')
    }
    else {
      Write-Warning '설치 실패로 기존 runtime·hook·skill 연결을 복원했습니다.'
    }
  }
  [Console]::Error.WriteLine("✗ 설치 실패: $installError")
  exit 1
}
finally {
  foreach ($temporaryPath in @($stage, $stateTemporary, $claudeSnapshot, $codexSnapshot)) {
    if ([string]::IsNullOrEmpty($temporaryPath)) {
      continue
    }
    $temporaryItem = Get-PathItem $temporaryPath
    if ($null -ne $temporaryItem) {
      if ($temporaryItem.PSIsContainer) {
        Remove-Item -LiteralPath $temporaryPath -Recurse -Force -ErrorAction SilentlyContinue
      }
      else {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
  if ($transactionCommitted -and $runtimeOldMoved -and -not $rollbackFailed -and -not [string]::IsNullOrEmpty($runtimeOld) -and [System.IO.Directory]::Exists($runtimeOld)) {
    Remove-Item -LiteralPath $runtimeOld -Recurse -Force -ErrorAction SilentlyContinue
  }
}
