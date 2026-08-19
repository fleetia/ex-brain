[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$StateMarker = 'ai-session-kit-state-v2'
$LegacyStateMarker = 'ai-session-kit-state-v1'
$RuntimeMarker = '.ai-session-kit-runtime'
$RuntimeMarkerContent = 'ai-session-kit-runtime-v1'
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
  if (-not [string]::Equals([string]$item.LinkType, 'Junction', [System.StringComparison]::OrdinalIgnoreCase)) {
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

  [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
  New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
  if (-not (Test-PathsEqual (Get-JunctionTarget $Path) $Target)) {
    Fail "skill junction 복원 검증 실패: $Path"
  }
}

function Write-Utf8File {
  param(
    [string]$Path,
    [string]$Content
  )

  [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function New-BackupFile {
  param([string]$Source)

  $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
  $backup = '{0}.bak-{1}-{2}' -f $Source, $timestamp, ([guid]::NewGuid().ToString('N').Substring(0, 8))
  Copy-Item -LiteralPath $Source -Destination $backup -Force
  return $backup
}

function Move-FileAtomically {
  param(
    [string]$Source,
    [string]$Destination
  )

  if ([System.IO.File]::Exists($Destination)) {
    [System.IO.File]::Replace($Source, $Destination, $null)
  }
  else {
    Move-Item -LiteralPath $Source -Destination $Destination
  }
}

function Quote-BashArgument {
  param([string]$Value)

  return "'" + $Value.Replace("'", "'\''") + "'"
}

function Get-ObjectProperty {
  param(
    $Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
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
    return $null
  }
  if ($item.PSIsContainer -or (Test-ReparsePoint $item)) {
    Fail "유효한 JSON hook 설정이 아니어서 보존했습니다: $Path"
  }
  try {
    $config = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
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
    [string[]]$OwnedCommands,
    [ref]$Changed
  )

  $result = New-Object System.Collections.ArrayList
  foreach ($group in $Groups) {
    $handlers = @(Get-ObjectProperty $group 'hooks')
    $remaining = New-Object System.Collections.ArrayList
    foreach ($handler in $handlers) {
      if (Test-OwnedCommand $handler $OwnedCommands) {
        $Changed.Value = $true
      }
      else {
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

function Prepare-HookRemoval {
  param(
    [string]$Path,
    [string[]]$SessionCommands,
    [string[]]$PiiCommands
  )

  $config = Read-HookConfig $Path
  if ($null -eq $config) {
    return [pscustomobject]@{ Path = $Path; Exists = $false; Changed = $false; Config = $null; Temporary = ''; Backup = ''; Committed = $false }
  }
  $hooks = Get-ObjectProperty $config 'hooks'
  if ($null -eq $hooks) {
    return [pscustomobject]@{ Path = $Path; Exists = $true; Changed = $false; Config = $config; Temporary = ''; Backup = ''; Committed = $false }
  }
  $changed = $false
  $sessionGroups = Get-ObjectProperty $hooks 'SessionStart'
  if ($null -ne $sessionGroups) {
    Set-ObjectProperty $hooks 'SessionStart' @(Remove-OwnedHookGroups @($sessionGroups) $SessionCommands ([ref]$changed))
  }
  foreach ($eventName in @('PreToolUse', 'PostToolUse')) {
    $groups = Get-ObjectProperty $hooks $eventName
    if ($null -ne $groups) {
      Set-ObjectProperty $hooks $eventName @(Remove-OwnedHookGroups @($groups) $PiiCommands ([ref]$changed))
    }
  }
  if (-not (Test-HookConfigObject $config)) {
    Fail "hook 설정 정리 결과가 유효하지 않습니다: $Path"
  }
  return [pscustomobject]@{ Path = $Path; Exists = $true; Changed = $changed; Config = $config; Temporary = ''; Backup = ''; Committed = $false }
}

function Prepare-ConfigFile {
  param($Plan)

  if (-not [bool]$Plan.Changed) {
    return
  }
  $directory = Split-Path -Parent ([string]$Plan.Path)
  $temporary = Join-Path $directory ('.hooks.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
  $json = $Plan.Config | ConvertTo-Json -Depth 100
  Write-Utf8File $temporary ($json + [Environment]::NewLine)
  $Plan.Temporary = $temporary
  $Plan.Backup = New-BackupFile ([string]$Plan.Path)
}

function Commit-ConfigFile {
  param($Plan)

  if (-not [bool]$Plan.Changed) {
    return
  }
  Move-FileAtomically ([string]$Plan.Temporary) ([string]$Plan.Path)
  $Plan.Temporary = ''
  $Plan.Committed = $true
}

function Restore-ConfigFile {
  param($Plan)

  if ([bool]$Plan.Committed) {
    Copy-Item -LiteralPath ([string]$Plan.Backup) -Destination ([string]$Plan.Path) -Force
    $Plan.Committed = $false
  }
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

function Get-DirectoryFingerprint {
  param([string]$Root)

  $entries = New-Object System.Collections.ArrayList
  foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName) {
    if (Test-ReparsePoint $item) {
      Fail "runtime에 reparse point가 있습니다: $($item.FullName)"
    }
    $relative = $item.FullName.Substring($Root.Length).TrimStart([char[]]@(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    ))
    if ($item.PSIsContainer) {
      [void]$entries.Add("D`t$relative")
    }
    else {
      $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
      [void]$entries.Add("F`t$relative`t$($item.Length)`t$hash")
    }
  }
  return @($entries.ToArray())
}

function Test-DirectoryEquivalent {
  param(
    [string]$Left,
    [string]$Right
  )

  $leftEntries = @(Get-DirectoryFingerprint $Left)
  $rightEntries = @(Get-DirectoryFingerprint $Right)
  if ($leftEntries.Count -ne $rightEntries.Count) {
    return $false
  }
  for ($index = 0; $index -lt $leftEntries.Count; $index += 1) {
    if (-not [string]::Equals($leftEntries[$index], $rightEntries[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
      return $false
    }
  }
  return $true
}

function Restore-DirectoryFromCopy {
  param(
    [string]$Source,
    [string]$Destination
  )

  $destinationItem = Get-PathItem $Destination
  if ($null -ne $destinationItem -and (-not $destinationItem.PSIsContainer -or (Test-ReparsePoint $destinationItem))) {
    Fail "runtime rollback 경로가 안전하지 않습니다: $Destination"
  }
  if ($null -ne $destinationItem) {
    [void](Get-DirectoryFingerprint $Destination)
  }
  [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
  foreach ($sourceDirectory in Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force | Sort-Object { $_.FullName.Length }) {
    $relative = $sourceDirectory.FullName.Substring($Source.Length).TrimStart([char[]]@(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    ))
    [System.IO.Directory]::CreateDirectory((Join-Path $Destination $relative)) | Out-Null
  }
  foreach ($sourceFile in Get-ChildItem -LiteralPath $Source -File -Recurse -Force) {
    $relative = $sourceFile.FullName.Substring($Source.Length).TrimStart([char[]]@(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    ))
    $destinationFile = Join-Path $Destination $relative
    $shouldCopy = -not [System.IO.File]::Exists($destinationFile)
    if (-not $shouldCopy) {
      $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
      $destinationHash = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash
      $shouldCopy = -not [string]::Equals($sourceHash, $destinationHash, [System.StringComparison]::OrdinalIgnoreCase)
    }
    if ($shouldCopy) {
      Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationFile -Force
    }
  }
}

function Restore-Wiring {
  param(
    [object[]]$ConfigPlans,
    [object[]]$SkillSnapshots,
    [string]$RuntimeDirectory,
    [string]$RuntimeRestore,
    [bool]$RuntimeRestoreReady,
    [bool]$RuntimeWasPresent
  )

  $restoreFailed = $false
  foreach ($plan in $ConfigPlans) {
    try {
      Restore-ConfigFile $plan
    }
    catch {
      $restoreFailed = $true
    }
  }
  try {
    if ($RuntimeWasPresent -and $RuntimeRestoreReady -and -not [string]::IsNullOrEmpty($RuntimeRestore) -and [System.IO.Directory]::Exists($RuntimeRestore)) {
      Restore-DirectoryFromCopy $RuntimeRestore $RuntimeDirectory
      if (-not (Test-DirectoryEquivalent $RuntimeRestore $RuntimeDirectory)) {
        Fail 'runtime rollback 복사본 검증에 실패했습니다'
      }
    }
    elseif ($RuntimeWasPresent -and $null -eq (Get-PathItem $RuntimeDirectory)) {
      Fail 'runtime rollback 복사본이 없습니다'
    }
  }
  catch {
    $restoreFailed = $true
  }
  foreach ($snapshot in $SkillSnapshots) {
    try {
      if (-not [bool]$snapshot.Existed) {
        continue
      }
      $path = [string]$snapshot.Path
      $item = Get-PathItem $path
      if ($null -eq $item) {
        New-OwnedJunction $path ([string]$snapshot.Target)
      }
      elseif (-not (Test-PathsEqual (Get-JunctionTarget $path) ([string]$snapshot.Target))) {
        Fail "skill junction rollback 중 foreign 항목을 발견했습니다: $path"
      }
    }
    catch {
      $restoreFailed = $true
    }
  }
  if ($restoreFailed) {
    Fail 'rollback 일부를 복원하지 못했습니다'
  }
}

$userHomeValue = $env:AI_SESSION_KIT_USER_HOME
if ([string]::IsNullOrWhiteSpace($userHomeValue)) {
  $userHomeValue = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
}
$userHome = Get-NormalizedPath $userHomeValue
$claudeSettings = Join-Path (Join-Path $userHome '.claude') 'settings.json'
$codexHooks = Join-Path (Join-Path $userHome '.codex') 'hooks.json'
$stateDirectory = Join-Path $userHome '.ai-session-kit'
$stateFile = Join-Path $stateDirectory 'install-state'
$runtimeDirectory = Join-Path $stateDirectory 'runtime'
$skillRoots = @(
  (Join-Path (Join-Path $userHome '.claude') 'skills'),
  (Join-Path $userHome '.agents\skills')
)

$stateDirectoryItem = Get-PathItem $stateDirectory
if ($null -eq $stateDirectoryItem -or -not $stateDirectoryItem.PSIsContainer -or (Test-ReparsePoint $stateDirectoryItem)) {
  Fail "로컬 설치 상태 경로가 안전한 폴더가 아닙니다: $stateDirectory"
}
$stateItem = Get-PathItem $stateFile
if ($null -eq $stateItem -or $stateItem.PSIsContainer -or (Test-ReparsePoint $stateItem)) {
  Fail "설치 상태 파일을 확인할 수 없어 installer 소유 junction을 식별할 수 없습니다: $stateFile"
}
$stateLines = @([System.IO.File]::ReadAllLines($stateFile))
$originalStateContent = [System.IO.File]::ReadAllText($stateFile)
if ($stateLines.Count -lt 2 -or ($stateLines[0] -ne $StateMarker -and $stateLines[0] -ne $LegacyStateMarker)) {
  Fail "설치 상태 파일 형식을 확인할 수 없습니다: $stateFile"
}
$installedVault = Get-NormalizedPath $stateLines[1]
$installedSessionCommand = ''
$installedPiiCommand = ''
if ($stateLines.Count -ge 3) {
  $installedSessionCommand = $stateLines[2]
}
if ($stateLines.Count -ge 4) {
  $installedPiiCommand = $stateLines[3]
}
if ($stateLines[0] -eq $StateMarker -and ([string]::IsNullOrEmpty($installedSessionCommand) -or [string]::IsNullOrEmpty($installedPiiCommand))) {
  Fail "설치 상태에 exact hook command가 없습니다: $stateFile"
}

$legacySessionBare = Join-Path $installedVault '_kit\hooks\session-context.sh'
$legacyPiiBare = Join-Path $installedVault '_kit\hooks\check-pii.sh'
$legacySessionCommand = 'AI_SESSION_KIT_HOOK=session-context bash ' + (Quote-BashArgument $legacySessionBare)
$legacyPiiCommand = 'AI_SESSION_KIT_HOOK=check-pii bash ' + (Quote-BashArgument $legacyPiiBare)
$ownedSessionCommands = @($installedSessionCommand, $legacySessionBare, $legacySessionCommand) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique
$ownedPiiCommands = @($installedPiiCommand, $legacyPiiBare, $legacyPiiCommand) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique

$skillSnapshots = New-Object System.Collections.ArrayList
$preflightFailed = $false
foreach ($skillRoot in $skillRoots) {
  foreach ($skill in $Skills) {
    $path = Join-Path $skillRoot $skill
    $expected = Join-Path (Join-Path $runtimeDirectory 'skills') $skill
    $legacyExpected = Join-Path (Join-Path $installedVault '_kit\skills') $skill
    $item = Get-PathItem $path
    if ($null -eq $item) {
      [void]$skillSnapshots.Add([pscustomobject]@{ Path = $path; Existed = $false; Target = '' })
      continue
    }
    $actual = Get-JunctionTarget $path
    if ($null -eq $actual -or (-not (Test-PathsEqual $actual $expected) -and -not (Test-PathsEqual $actual $legacyExpected))) {
      [Console]::Error.WriteLine("! installer 경로의 foreign 파일/폴더/link 보존: $path")
      $preflightFailed = $true
      continue
    }
    [void]$skillSnapshots.Add([pscustomobject]@{ Path = $path; Existed = $true; Target = $actual })
  }
}

$runtimeWasPresent = $false
$runtimeItem = Get-PathItem $runtimeDirectory
if ($null -ne $runtimeItem) {
  $runtimeWasPresent = $true
  $markerPath = Join-Path $runtimeDirectory $RuntimeMarker
  $markerItem = Get-PathItem $markerPath
  $markerValue = ''
  if ($null -ne $markerItem -and -not $markerItem.PSIsContainer -and -not (Test-ReparsePoint $markerItem)) {
    $markerValue = [System.IO.File]::ReadAllText($markerPath).TrimEnd([char[]]@([char]13, [char]10))
  }
  if (-not $runtimeItem.PSIsContainer -or (Test-ReparsePoint $runtimeItem) -or $markerValue -ne $RuntimeMarkerContent) {
    [Console]::Error.WriteLine("✗ installer 소유 runtime으로 확인되지 않아 제거하지 않습니다: $runtimeDirectory")
    $preflightFailed = $true
  }
  else {
    try {
      [void](Get-DirectoryFingerprint $runtimeDirectory)
    }
    catch {
      [Console]::Error.WriteLine("✗ local runtime 구조를 안전하게 확인할 수 없습니다: $runtimeDirectory")
      $preflightFailed = $true
    }
  }
}

$configPlans = @()
try {
  $configPlans = @(
    (Prepare-HookRemoval $claudeSettings $ownedSessionCommands $ownedPiiCommands),
    (Prepare-HookRemoval $codexHooks $ownedSessionCommands $ownedPiiCommands)
  )
}
catch {
  [Console]::Error.WriteLine("✗ $($_.Exception.Message)")
  $preflightFailed = $true
}

if ($preflightFailed) {
  [Console]::Error.WriteLine('제거를 시작하지 않았습니다. 위 경고를 해결한 뒤 uninstall.ps1을 다시 실행하세요. vault는 그대로 남아 있습니다.')
  exit 1
}

$runtimeRestore = ''
$runtimeRestoreReady = $false
$removedJunctions = 0
$stateRemoved = $false
$operationCompleted = $false
$rollbackSucceeded = $false
try {
  foreach ($plan in $configPlans) {
    Prepare-ConfigFile $plan
  }
  foreach ($plan in $configPlans) {
    Commit-ConfigFile $plan
    if ([bool]$plan.Changed) {
      Write-Host "✓ installer 소유 hook 제거: $($plan.Path) (백업: $($plan.Backup))"
    }
    else {
      Write-Host "· installer 소유 hook 없음: $($plan.Path)"
    }
  }

  if ($runtimeWasPresent) {
    $runtimeRestore = Join-Path $stateDirectory ('.runtime-restore.{0}' -f [guid]::NewGuid().ToString('N'))
    Copy-DirectoryContents $runtimeDirectory $runtimeRestore
    if (-not (Test-DirectoryEquivalent $runtimeDirectory $runtimeRestore)) {
      Fail 'runtime rollback 복사본을 검증할 수 없어 제거를 중단했습니다'
    }
    $runtimeRestoreReady = $true
  }

  foreach ($snapshot in $skillSnapshots) {
    if ([bool]$snapshot.Existed) {
      Remove-Junction ([string]$snapshot.Path) ([string]$snapshot.Target)
      $removedJunctions += 1
    }
  }
  Write-Host "✓ installer 소유 skill junction $removedJunctions 개 제거 (Claude + Codex)"

  if ($runtimeWasPresent) {
    Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force
    if ($null -ne (Get-PathItem $runtimeDirectory)) {
      Fail "runtime 제거 검증 실패: $runtimeDirectory"
    }
  }

  [System.IO.File]::Delete($stateFile)
  if ([System.IO.File]::Exists($stateFile)) {
    Fail "install-state 제거 검증 실패: $stateFile"
  }
  $stateRemoved = $true

  if (-not [string]::IsNullOrEmpty($runtimeRestore) -and [System.IO.Directory]::Exists($runtimeRestore)) {
    try {
      Remove-Item -LiteralPath $runtimeRestore -Recurse -Force
      $runtimeRestore = ''
      $runtimeRestoreReady = $false
    }
    catch {
      Write-Warning "제거는 완료됐지만 runtime rollback 복사본을 지우지 못했습니다: $runtimeRestore"
    }
  }
  Write-Host "✓ installer 소유 local runtime 제거: $runtimeDirectory"
  $operationCompleted = $true
  Write-Host ''
  Write-Host '제거 완료. vault(지식 폴더)는 그대로 남아 있습니다.'
}
catch {
  $rollbackFailed = $false
  if ($stateRemoved) {
    try {
      Write-Utf8File $stateFile $originalStateContent
      $stateRemoved = $false
    }
    catch {
      $rollbackFailed = $true
    }
  }
  try {
    Restore-Wiring $configPlans @($skillSnapshots.ToArray()) $runtimeDirectory $runtimeRestore $runtimeRestoreReady $runtimeWasPresent
  }
  catch {
    $rollbackFailed = $true
  }
  if (-not $rollbackFailed -and -not [string]::IsNullOrEmpty($runtimeRestore) -and [System.IO.Directory]::Exists($runtimeRestore)) {
    try {
      Remove-Item -LiteralPath $runtimeRestore -Recurse -Force
      $runtimeRestore = ''
      $runtimeRestoreReady = $false
    }
    catch {
      $rollbackFailed = $true
    }
  }
  if ($rollbackFailed) {
    [Console]::Error.WriteLine('✗ 제거와 rollback 일부가 실패했습니다. install-state와 backup 파일을 확인하세요.')
  }
  else {
    $rollbackSucceeded = $true
    [Console]::Error.WriteLine('✗ 제거 실패로 기존 runtime·hook·skill 연결을 복원했습니다.')
  }
  [Console]::Error.WriteLine("원인: $($_.Exception.Message)")
  exit 1
}
finally {
  foreach ($plan in $configPlans) {
    if (-not [string]::IsNullOrEmpty([string]$plan.Temporary) -and [System.IO.File]::Exists([string]$plan.Temporary)) {
      Remove-Item -LiteralPath ([string]$plan.Temporary) -Force -ErrorAction SilentlyContinue
    }
  }
  if (($operationCompleted -or $rollbackSucceeded) -and -not [string]::IsNullOrEmpty($runtimeRestore) -and [System.IO.Directory]::Exists($runtimeRestore)) {
    Remove-Item -LiteralPath $runtimeRestore -Recurse -Force -ErrorAction SilentlyContinue
  }
}
