# PreToolUse hook: fail-closed PII guard for native Windows vault writes.

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

$maxScanBytes = 5242880
$maxJsonBytes = 6291456
$script:vaultLexicalRoot = ''
$script:vaultIdentityRoot = ''

function Stop-WithFailure {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
    exit 2
}

try {
    if ($null -eq ('AiSessionKit.NativePath' -as [type])) {
        [void](Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace AiSessionKit
{
    public static class NativePath
    {
        private const uint FileShareAll = 0x00000007;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint InvalidFileAttributes = 0xFFFFFFFF;
        private const uint VolumeNameNt = 0x00000002;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            StringBuilder filePath,
            uint filePathSize,
            uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern uint GetFileAttributesW(string fileName);

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation fileInformation);

        public static bool Exists(string path)
        {
            uint attributes = GetFileAttributesW(path);
            if (attributes != InvalidFileAttributes)
            {
                return true;
            }

            int error = Marshal.GetLastWin32Error();
            if (error == 2 || error == 3)
            {
                return false;
            }
            throw new Win32Exception(error);
        }

        public static string GetFinalNtPath(string path)
        {
            using (SafeFileHandle handle = CreateFileW(
                path,
                0,
                FileShareAll,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                int capacity = 512;
                while (capacity <= 65536)
                {
                    StringBuilder buffer = new StringBuilder(capacity);
                    uint length = GetFinalPathNameByHandleW(
                        handle,
                        buffer,
                        (uint)buffer.Capacity,
                        VolumeNameNt);
                    if (length == 0)
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    if (length < (uint)buffer.Capacity)
                    {
                        return buffer.ToString();
                    }
                    capacity = checked((int)length + 1);
                }
                throw new InvalidOperationException("Resolved path is too long.");
            }
        }

        public static uint GetLinkCount(string path)
        {
            using (SafeFileHandle handle = CreateFileW(
                path,
                0,
                FileShareAll,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return information.NumberOfLinks;
            }
        }

        public static long GetProspectiveUtf8Length(
            string source,
            string oldValue,
            string newValue,
            bool replaceAll,
            long maximumLength)
        {
            if (String.IsNullOrEmpty(oldValue))
            {
                return -1;
            }

            int index = source.IndexOf(oldValue, StringComparison.Ordinal);
            if (index < 0)
            {
                return -1;
            }

            UTF8Encoding encoding = new UTF8Encoding(false, true);
            long sourceLength = encoding.GetByteCount(source);
            long oldLength = encoding.GetByteCount(oldValue);
            long newLength = encoding.GetByteCount(newValue);
            long delta = newLength - oldLength;
            long result = sourceLength + delta;
            if (!replaceAll || delta <= 0 || result > maximumLength)
            {
                return result;
            }

            int searchIndex = index + oldValue.Length;
            while (searchIndex <= source.Length - oldValue.Length)
            {
                index = source.IndexOf(oldValue, searchIndex, StringComparison.Ordinal);
                if (index < 0)
                {
                    break;
                }
                result += delta;
                if (result > maximumLength)
                {
                    return result;
                }
                searchIndex = index + oldValue.Length;
            }
            return result;
        }
    }
}
'@ -ErrorAction Stop)
    }
}
catch {
    Stop-WithFailure -Message 'PII guard could not initialize Windows path verification, so the write was blocked.'
}

function Test-HasControlCharacter {
    param([AllowEmptyString()][string]$Value)

    return $Value -match '[\x00-\x1F\x7F\p{Cf}\p{Zl}\p{Zp}]'
}

function Read-BoundedJsonInput {
    $stream = [Console]::OpenStandardInput()
    $memory = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $read -gt $script:maxJsonBytes) {
                Stop-WithFailure -Message 'PII guard blocked a PreToolUse request larger than 6 MiB.'
            }
            $memory.Write($buffer, 0, $read)
        }
        $bytes = $memory.ToArray()
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        $offset = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $offset = 3
        }
        return $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch {
        Stop-WithFailure -Message 'PII guard could not safely read the PreToolUse request, so the write was blocked.'
    }
    finally {
        $memory.Dispose()
    }
}

function Test-IsWithinContentLimit {
    param([AllowEmptyString()][string]$Content)

    try {
        return $script:utf8NoBom.GetByteCount($Content) -le $script:maxScanBytes
    }
    catch {
        return $false
    }
}

function Get-ConfiguredVaultFromState {
    param(
        [string]$StateRoot,
        [string]$WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($StateRoot) -or (Test-HasControlCharacter -Value $StateRoot)) {
        throw 'Unsafe state directory.'
    }
    $normalizedStateRoot = Get-NormalizedLexicalPath -RawPath $StateRoot -WorkingDirectory $WorkingDirectory
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
    $stateItem = Get-Item -LiteralPath $statePath -Force -ErrorAction Stop
    if ($stateItem.PSIsContainer -or (Test-IsReparsePoint -Item $stateItem)) {
        throw 'Unsafe install state.'
    }
    $stateLines = [System.IO.File]::ReadAllLines($stateItem.FullName)
    if ($stateLines.Length -lt 2 -or
        ($stateLines[0] -cne 'ai-session-kit-state-v1' -and $stateLines[0] -cne 'ai-session-kit-state-v2') -or
        [string]::IsNullOrWhiteSpace($stateLines[1]) -or
        (Test-HasControlCharacter -Value $stateLines[1]) -or
        -not [System.IO.Path]::IsPathRooted($stateLines[1])) {
        throw 'Invalid install state.'
    }
    return $stateLines[1]
}

function Test-IsJsonObject {
    param($Value)

    return $null -ne $Value -and $Value -is [System.Management.Automation.PSCustomObject]
}

function Test-HasProperty {
    param(
        $Object,
        [string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Test-IsStringProperty {
    param(
        $Object,
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    return $null -ne $property -and $property.Value -is [string]
}

function Test-IsReparsePoint {
    param([System.IO.FileSystemInfo]$Item)

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-ComparisonPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directorySeparator = [System.IO.Path]::DirectorySeparatorChar
    $alternateSeparator = [System.IO.Path]::AltDirectorySeparatorChar
    $fullPath = $fullPath.Replace($alternateSeparator, $directorySeparator)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrEmpty($root)) {
        throw 'Path has no filesystem root.'
    }
    while ($fullPath.Length -gt $root.Length -and
        $fullPath.EndsWith($directorySeparator.ToString(), [System.StringComparison]::Ordinal)) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
}

function Get-NormalizedLexicalPath {
    param(
        [string]$RawPath,
        [string]$WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($RawPath) -or (Test-HasControlCharacter -Value $RawPath)) {
        throw 'Unsafe path.'
    }
    if ($RawPath.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or
        $RawPath.StartsWith('\\.\', [System.StringComparison]::Ordinal) -or
        $RawPath.StartsWith('\??\', [System.StringComparison]::Ordinal)) {
        throw 'Device paths are not supported.'
    }
    if ($RawPath -match '^[A-Za-z]:[^\\/]') {
        throw 'Drive-relative paths are not supported.'
    }

    if ([System.IO.Path]::IsPathRooted($RawPath)) {
        $candidate = $RawPath
    }
    else {
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or
            (Test-HasControlCharacter -Value $WorkingDirectory) -or
            -not [System.IO.Path]::IsPathRooted($WorkingDirectory)) {
            throw 'Unsafe working directory.'
        }
        $candidate = [System.IO.Path]::Combine($WorkingDirectory, $RawPath)
    }

    $fullPath = Get-ComparisonPath -Path $candidate
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $relativePart = $fullPath.Substring($root.Length)
    if ($relativePart.Contains(':') -or $relativePart -match '(?:^|[\\/])[^\\/]*[ .](?:[\\/]|$)') {
        throw 'Ambiguous Windows path.'
    }
    return $fullPath
}

function Get-NormalizedNtIdentity {
    param([string]$Identity)

    if ([string]::IsNullOrWhiteSpace($Identity) -or (Test-HasControlCharacter -Value $Identity)) {
        throw 'Invalid Windows path identity.'
    }
    $normalized = $Identity.Replace('/', '\')
    if ($normalized.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or
        $normalized.StartsWith('\??\', [System.StringComparison]::Ordinal)) {
        throw 'Windows path identity was not returned in NT form.'
    }
    if ($normalized -match '^(?i:\\Device\\(?:Mup|LanmanRedirector)\\;[^\\]+\\)(.+)$') {
        $normalized = '\Device\Mup\' + $Matches[1]
    }
    elseif ($normalized -match '^(?i:\\Device\\LanmanRedirector\\)(.+)$') {
        $normalized = '\Device\Mup\' + $Matches[1]
    }
    if (-not $normalized.StartsWith('\', [System.StringComparison]::Ordinal)) {
        throw 'Windows path identity is not absolute.'
    }
    while ($normalized.Length -gt 1 -and
        $normalized.EndsWith('\', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }
    return $normalized
}

function Get-PathIdentity {
    param([string]$Path)

    $fullPath = Get-ComparisonPath -Path $Path
    $missingParts = New-Object 'System.Collections.Generic.List[string]'
    $ancestor = $fullPath
    while (-not [AiSessionKit.NativePath]::Exists($ancestor)) {
        $leaf = [System.IO.Path]::GetFileName($ancestor)
        $parent = [System.IO.Path]::GetDirectoryName($ancestor)
        if ([string]::IsNullOrEmpty($leaf) -or [string]::IsNullOrEmpty($parent) -or
            $parent.Equals($ancestor, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'No existing path ancestor could be verified.'
        }
        if ($leaf -in @('.', '..') -or $leaf.Contains(':') -or
            $leaf -match '[ .]$' -or (Test-HasControlCharacter -Value $leaf)) {
            throw 'Unsafe missing path component.'
        }
        [void]$missingParts.Insert(0, $leaf)
        $ancestor = Get-ComparisonPath -Path $parent
    }

    $identity = Get-NormalizedNtIdentity -Identity ([AiSessionKit.NativePath]::GetFinalNtPath($ancestor))
    foreach ($part in $missingParts) {
        $identity = $identity + '\' + $part
    }
    return Get-NormalizedNtIdentity -Identity $identity
}

function Test-IsWithinOrSameIdentity {
    param(
        [string]$Candidate,
        [string]$Root
    )

    $candidateIdentity = Get-NormalizedNtIdentity -Identity $Candidate
    $rootIdentity = Get-NormalizedNtIdentity -Identity $Root
    if ($candidateIdentity.Equals($rootIdentity, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($rootIdentity.EndsWith('\', [System.StringComparison]::Ordinal)) {
        $prefix = $rootIdentity
    }
    else {
        $prefix = $rootIdentity + '\'
    }
    return $candidateIdentity.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsLocalProviderIdentity {
    param([string]$Identity)

    $normalized = Get-NormalizedNtIdentity -Identity $Identity
    $mupRoot = '\Device\Mup'
    $p9Root = '\Device\P9Rdr'
    if ($normalized.Equals($p9Root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith($p9Root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($normalized.Equals($mupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $mupPrefix = $mupRoot + '\'
    if (-not $normalized.StartsWith($mupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $providerPath = $normalized.Substring($mupPrefix.Length)
    $separatorIndex = $providerPath.IndexOf('\')
    if ($separatorIndex -le 0) {
        return $true
    }
    $hostName = $providerPath.Substring(0, $separatorIndex)
    if ($hostName -in @('localhost', '127.0.0.1', '[::1]', 'wsl$', 'wsl.localhost')) {
        return $true
    }

    $machineName = [Environment]::MachineName
    if ([string]::IsNullOrWhiteSpace($machineName)) {
        return $false
    }
    if ($hostName.Equals($machineName, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $hostName.StartsWith($machineName + '.', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-LexicalVaultTraversal {
    param(
        [string]$LexicalPath,
        [ref]$TraversedVault,
        [ref]$InternalReparsePoint
    )

    $TraversedVault.Value = $false
    $InternalReparsePoint.Value = $false
    $path = Get-ComparisonPath -Path $LexicalPath
    $root = [System.IO.Path]::GetPathRoot($path)
    if (-not [AiSessionKit.NativePath]::Exists($root)) {
        throw 'Path root could not be verified.'
    }

    $rootIdentity = Get-PathIdentity -Path $root
    if (Test-IsWithinOrSameIdentity -Candidate $rootIdentity -Root $script:vaultIdentityRoot) {
        $TraversedVault.Value = $true
    }

    $trimCharacters = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $relativePart = $path.Substring($root.Length).TrimStart($trimCharacters)
    $parts = @($relativePart -split '[\\/]' | Where-Object { $_.Length -gt 0 })
    $currentPath = $root
    foreach ($part in $parts) {
        $currentPath = [System.IO.Path]::Combine($currentPath, $part)
        if (-not [AiSessionKit.NativePath]::Exists($currentPath)) {
            break
        }
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        $wasInsideVault = [bool]$TraversedVault.Value
        if ($wasInsideVault -and (Test-IsReparsePoint -Item $item)) {
            $InternalReparsePoint.Value = $true
        }
        $componentIdentity = Get-PathIdentity -Path $currentPath
        if (Test-IsWithinOrSameIdentity -Candidate $componentIdentity -Root $script:vaultIdentityRoot) {
            $TraversedVault.Value = $true
        }
    }
}

# Status 0: vault target, 1: outside target, 2: unsafe or indeterminate.
function Get-TargetClassification {
    param(
        [string]$RawPath,
        [string]$WorkingDirectory,
        [ref]$TargetPath
    )

    $TargetPath.Value = ''
    try {
        $lexicalPath = Get-NormalizedLexicalPath -RawPath $RawPath -WorkingDirectory $WorkingDirectory
        $targetIdentity = Get-PathIdentity -Path $lexicalPath
        $traversedVault = $false
        $internalReparsePoint = $false
        $traversalArguments = @{
            LexicalPath = $lexicalPath
            TraversedVault = [ref]$traversedVault
            InternalReparsePoint = [ref]$internalReparsePoint
        }
        Get-LexicalVaultTraversal @traversalArguments
        if ($internalReparsePoint) {
            return 2
        }
        if (Test-IsWithinOrSameIdentity -Candidate $targetIdentity -Root $script:vaultIdentityRoot) {
            $TargetPath.Value = $lexicalPath
            return 0
        }
        if ($traversedVault) {
            return 2
        }
        if (Test-IsLocalProviderIdentity -Identity $targetIdentity) {
            return 2
        }
        if ([AiSessionKit.NativePath]::Exists($lexicalPath)) {
            $existingTarget = Get-Item -LiteralPath $lexicalPath -Force -ErrorAction Stop
            if (-not $existingTarget.PSIsContainer -and
                -not (Test-IsReparsePoint -Item $existingTarget) -and
                [AiSessionKit.NativePath]::GetLinkCount($lexicalPath) -gt 1) {
                return 2
            }
        }
        return 1
    }
    catch {
        return 2
    }
}

function Get-VaultRelativePath {
    param([string]$TargetPath)

    $targetIdentity = Get-PathIdentity -Path $TargetPath
    $rootIdentity = Get-NormalizedNtIdentity -Identity $script:vaultIdentityRoot
    if (-not (Test-IsWithinOrSameIdentity -Candidate $targetIdentity -Root $rootIdentity)) {
        throw 'Target is outside the vault.'
    }
    $relativePath = $targetIdentity.Substring($rootIdentity.Length).TrimStart([char]'\')
    return $relativePath.Replace('\', '/')
}

function Get-SensitiveCategories {
    param([AllowEmptyString()][string]$Content)

    $categories = New-Object 'System.Collections.Generic.List[string]'
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    foreach ($match in [regex]::Matches($Content, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', $ignoreCase)) {
        $value = $match.Value
        if ($value -match '(?i)(@example\.com$|^test@|^noreply@|placeholder|masked|^user@domain\.)') {
            continue
        }
        [void]$categories.Add('EMAIL')
        break
    }

    foreach ($match in [regex]::Matches($Content, '[0-9xX]{2,4}-[0-9xX]{3,4}-[0-9xX]{4}')) {
        $value = $match.Value
        if ($value -match '^(010-0000-0000|[xX]{2,4}-[xX]{3,4}-[xX]{4}|02-1234-5678)$') {
            continue
        }
        [void]$categories.Add('PHONE')
        break
    }

    $hasSecret = $false
    foreach ($match in [regex]::Matches(
            $Content,
            '(password|secret|api[_-]?key|access[_-]?token|private[_-]?key)\s*[:=]\s*[''"]?[A-Za-z0-9+/_.=-]{16,}',
            $ignoreCase
        )) {
        if ($match.Value -notmatch '(?i)(placeholder|masked|example)') {
            $hasSecret = $true
            break
        }
    }
    if (-not $hasSecret) {
        $hasSecret = [regex]::IsMatch(
            $Content,
            '(bearer\s+[A-Za-z0-9._~-]{16,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)',
            $ignoreCase
        )
    }
    if ($hasSecret) {
        [void]$categories.Add('SECRET')
    }

    foreach ($match in [regex]::Matches(
            $Content,
            '(mysql|postgres|mongodb|redis|amqp|sentry)://[^\s"<>]+',
            $ignoreCase
        )) {
        if ($match.Value -match '(?i)(://localhost([/:]|$)|://127\.0\.0\.1([/:]|$)|example|placeholder)') {
            continue
        }
        [void]$categories.Add('DSN')
        break
    }

    foreach ($match in [regex]::Matches($Content, '[0-9]{1,3}(\.[0-9]{1,3}){3}')) {
        $value = $match.Value
        if ($value -match '^(127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})$') {
            continue
        }
        [void]$categories.Add('IP')
        break
    }
    return $categories.ToArray()
}

function Write-DenyAndExit {
    param([string[]]$Categories)

    $categoryText = $Categories -join ', '
    $reason = "민감정보 후보($categoryText)가 포함된 vault write를 차단했습니다. 값은 출력하지 않았습니다. 마스킹하거나 역할명·예시값으로 바꾼 뒤 다시 시도하세요."
    $output = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = $reason
        }
    }
    $json = $output | ConvertTo-Json -Compress -Depth 5
    [Console]::Out.Write($json)
    exit 0
}

function Invoke-ScanContent {
    param([AllowEmptyString()][string]$Content)

    if (-not (Test-IsWithinContentLimit -Content $Content)) {
        Stop-WithFailure -Message 'PII guard blocked content larger than 5 MiB.'
    }
    $categories = @(Get-SensitiveCategories -Content $Content)
    if ($categories.Count -gt 0) {
        Write-DenyAndExit -Categories $categories
    }
}

function Invoke-ScanVaultTargetPath {
    param([string]$TargetPath)

    $relativePath = Get-VaultRelativePath -TargetPath $TargetPath
    Invoke-ScanContent -Content $relativePath
}

function Try-ReadTextFile {
    param(
        [string]$Path,
        [ref]$Text
    )

    $Text.Value = $null
    $stream = $null
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (Test-IsReparsePoint -Item $item)) {
            return $false
        }
        $stream = [System.IO.File]::Open(
            $item.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        if ($stream.Length -gt $script:maxScanBytes) {
            return $false
        }
        $expectedLength = [int]$stream.Length
        $bytes = New-Object byte[] $expectedLength
        $totalRead = 0
        while ($totalRead -lt $expectedLength) {
            $read = $stream.Read($bytes, $totalRead, $expectedLength - $totalRead)
            if ($read -le 0) {
                return $false
            }
            $totalRead += $read
        }
        if ($stream.ReadByte() -ne -1) {
            return $false
        }

        $offset = 0
        $count = $bytes.Length
        if ($bytes.Length -ge 4 -and
            (($bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) -or
             ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00))) {
            return $false
        }
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
            $offset = 3
            $count -= 3
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
            $offset = 2
            $count -= 2
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
            $offset = 2
            $count -= 2
        }
        else {
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
        }
        $content = $encoding.GetString($bytes, $offset, $count)
        if ($content.IndexOf([char]0) -ge 0) {
            return $false
        }
        $Text.Value = $content
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Invoke-InspectWrite {
    param(
        [string]$RawPath,
        [AllowEmptyString()][string]$Content,
        [string]$WorkingDirectory
    )

    $targetPath = ''
    $status = Get-TargetClassification -RawPath $RawPath -WorkingDirectory $WorkingDirectory -TargetPath ([ref]$targetPath)
    switch ($status) {
        0 {
            Invoke-ScanVaultTargetPath -TargetPath $targetPath
            Invoke-ScanContent -Content $Content
            return
        }
        1 { return }
        default { Stop-WithFailure -Message 'PII guard could not safely resolve a write target, so the write was blocked.' }
    }
}

function Invoke-InspectEdit {
    param(
        [string]$RawPath,
        [AllowEmptyString()][string]$OldString,
        [AllowEmptyString()][string]$NewString,
        [bool]$ReplaceAll,
        [string]$WorkingDirectory
    )

    $targetPath = ''
    $status = Get-TargetClassification -RawPath $RawPath -WorkingDirectory $WorkingDirectory -TargetPath ([ref]$targetPath)
    if ($status -eq 1) {
        return
    }
    if ($status -ne 0) {
        Stop-WithFailure -Message 'PII guard could not safely resolve the Edit target, so the write was blocked.'
    }
    Invoke-ScanVaultTargetPath -TargetPath $targetPath

    $source = $null
    if (-not (Try-ReadTextFile -Path $targetPath -Text ([ref]$source))) {
        Stop-WithFailure -Message 'PII guard could not safely read the Edit target, so the write was blocked.'
    }
    if ([string]::IsNullOrEmpty($OldString)) {
        Stop-WithFailure -Message 'PII guard could not reconstruct the Edit result, so the write was blocked.'
    }
    try {
        $prospectiveByteCount = [AiSessionKit.NativePath]::GetProspectiveUtf8Length(
            $source,
            $OldString,
            $NewString,
            $ReplaceAll,
            $script:maxScanBytes
        )
    }
    catch {
        Stop-WithFailure -Message 'PII guard could not reconstruct the Edit result, so the write was blocked.'
    }
    if ($prospectiveByteCount -lt 0) {
        Stop-WithFailure -Message 'PII guard could not reconstruct the Edit result, so the write was blocked.'
    }
    if ($prospectiveByteCount -gt $script:maxScanBytes) {
        Stop-WithFailure -Message 'PII guard blocked an Edit result larger than 5 MiB.'
    }
    if ($ReplaceAll) {
        $prospective = $source.Replace($OldString, $NewString)
    }
    else {
        $offset = $source.IndexOf($OldString, [System.StringComparison]::Ordinal)
        $prospective = $source.Substring(0, $offset) + $NewString +
            $source.Substring($offset + $OldString.Length)
    }
    if (-not (Test-IsWithinContentLimit -Content $prospective)) {
        Stop-WithFailure -Message 'PII guard blocked an Edit result larger than 5 MiB.'
    }
    Invoke-ScanContent -Content $prospective
}

function Invoke-InspectPatch {
    param(
        [string]$Patch,
        [string]$WorkingDirectory
    )

    $currentPath = $null
    $sourcePath = $null
    $pending = New-Object 'System.Collections.Generic.List[string]'
    $sawHeader = $false
    $reader = New-Object System.IO.StringReader($Patch)
    $lineCount = 0
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineCount += 1
            if ($lineCount -gt 20000 -or $line.Length -gt 262144) {
                Stop-WithFailure -Message 'PII guard blocked an apply_patch payload with unsafe line structure.'
            }
            $isAdd = $line.StartsWith('*** Add File: ', [System.StringComparison]::Ordinal)
            $isUpdate = $line.StartsWith('*** Update File: ', [System.StringComparison]::Ordinal)
            $isDelete = $line.StartsWith('*** Delete File: ', [System.StringComparison]::Ordinal)
            if ($isAdd -or $isUpdate -or $isDelete) {
                if ($null -ne $currentPath -and $pending.Count -gt 0) {
                    Invoke-InspectWrite -RawPath $currentPath -Content ([string]::Join("`n", $pending.ToArray())) -WorkingDirectory $WorkingDirectory
                }
                $pending.Clear()
                $sawHeader = $true
                if ($isAdd) {
                    $currentPath = $line.Substring('*** Add File: '.Length)
                    $sourcePath = $null
                    Invoke-InspectWrite -RawPath $currentPath -Content '' -WorkingDirectory $WorkingDirectory
                }
                elseif ($isUpdate) {
                    $currentPath = $line.Substring('*** Update File: '.Length)
                    $sourcePath = $currentPath
                    Invoke-InspectWrite -RawPath $currentPath -Content '' -WorkingDirectory $WorkingDirectory
                }
                else {
                    $currentPath = $null
                    $sourcePath = $null
                }
                continue
            }

            if ($line.StartsWith('*** Move to: ', [System.StringComparison]::Ordinal)) {
                $destination = $line.Substring('*** Move to: '.Length)
                $destinationTarget = ''
                $destinationStatus = Get-TargetClassification -RawPath $destination -WorkingDirectory $WorkingDirectory -TargetPath ([ref]$destinationTarget)
                if ($destinationStatus -eq 2) {
                    Stop-WithFailure -Message 'PII guard could not safely resolve an apply_patch move target, so the write was blocked.'
                }
                if ($destinationStatus -eq 0) {
                    Invoke-ScanVaultTargetPath -TargetPath $destinationTarget
                    if ([string]::IsNullOrEmpty($sourcePath)) {
                        Stop-WithFailure -Message 'PII guard could not resolve an apply_patch move source, so the write was blocked.'
                    }
                    $sourceTarget = ''
                    $sourceStatus = Get-TargetClassification -RawPath $sourcePath -WorkingDirectory $WorkingDirectory -TargetPath ([ref]$sourceTarget)
                    if ($sourceStatus -ne 0) {
                        Stop-WithFailure -Message 'PII guard blocks moves into the vault unless the source is a regular vault file.'
                    }
                    $sourceContent = $null
                    if (-not (Try-ReadTextFile -Path $sourceTarget -Text ([ref]$sourceContent))) {
                        Stop-WithFailure -Message 'PII guard could not safely read an apply_patch move source.'
                    }
                    if ($pending.Count -gt 0) {
                        if ($sourceContent.Length -gt 0) {
                            $sourceContent += "`n"
                        }
                        $sourceContent += [string]::Join("`n", $pending.ToArray())
                    }
                    Invoke-ScanContent -Content $sourceContent
                }
                $pending.Clear()
                $currentPath = $destination
                $sourcePath = $null
                $sawHeader = $true
                continue
            }

            if ($line.StartsWith('+', [System.StringComparison]::Ordinal)) {
                if ($null -eq $currentPath) {
                    Stop-WithFailure -Message 'PII guard could not associate apply_patch content with a target, so the write was blocked.'
                }
                [void]$pending.Add($line.Substring(1))
            }
        }
    }
    finally {
        $reader.Dispose()
    }

    if ($null -ne $currentPath -and $pending.Count -gt 0) {
        Invoke-InspectWrite -RawPath $currentPath -Content ([string]::Join("`n", $pending.ToArray())) -WorkingDirectory $WorkingDirectory
    }
    if (-not $sawHeader) {
        Stop-WithFailure -Message 'PII guard received an unrecognized apply_patch payload, so the write was blocked.'
    }
}

try {
    $rawInput = Read-BoundedJsonInput
    try {
        $request = $rawInput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Stop-WithFailure -Message 'PII guard received invalid PreToolUse JSON, so the write was blocked.'
    }
    if (-not (Test-IsJsonObject -Value $request) -or
        -not (Test-IsStringProperty -Object $request -Name 'tool_name') -or
        -not (Test-HasProperty -Object $request -Name 'tool_input') -or
        -not (Test-IsJsonObject -Value $request.tool_input)) {
        Stop-WithFailure -Message 'PII guard received an unsupported PreToolUse schema, so the write was blocked.'
    }
    if (Test-HasProperty -Object $request -Name 'cwd') {
        if ($null -ne $request.cwd -and -not ($request.cwd -is [string])) {
            Stop-WithFailure -Message 'PII guard received an unsupported PreToolUse schema, so the write was blocked.'
        }
        $workingDirectory = [string]$request.cwd
    }
    else {
        $workingDirectory = ''
    }
    if ([string]::IsNullOrWhiteSpace($workingDirectory)) {
        $workingDirectory = [System.IO.Directory]::GetCurrentDirectory()
    }
    if (Test-HasControlCharacter -Value $workingDirectory) {
        Stop-WithFailure -Message 'PII guard rejected a working directory containing control characters.'
    }
    $workingDirectory = Get-NormalizedLexicalPath -RawPath $workingDirectory -WorkingDirectory $workingDirectory
    $workingDirectoryItem = Get-Item -LiteralPath $workingDirectory -Force -ErrorAction Stop
    if (-not $workingDirectoryItem.PSIsContainer) {
        Stop-WithFailure -Message 'PII guard could not resolve the working directory, so the write was blocked.'
    }

    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $StateDirectory = $env:AI_SESSION_KIT_STATE_DIR
    }
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $StateDirectory = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    if ([string]::IsNullOrWhiteSpace($VaultPath)) {
        try {
            $VaultPath = Get-ConfiguredVaultFromState -StateRoot $StateDirectory -WorkingDirectory $workingDirectory
        }
        catch {
            Stop-WithFailure -Message 'PII guard could not resolve the configured vault, so the write was blocked.'
        }
        if ([string]::IsNullOrWhiteSpace($VaultPath)) {
            $VaultPath = $env:KB_VAULT
        }
    }
    if ([string]::IsNullOrWhiteSpace($VaultPath) -or
        (Test-HasControlCharacter -Value $VaultPath) -or
        -not [System.IO.Path]::IsPathRooted($VaultPath)) {
        Stop-WithFailure -Message 'PII guard could not resolve the configured vault, so the write was blocked.'
    }

    try {
        $script:vaultLexicalRoot = Get-NormalizedLexicalPath -RawPath $VaultPath -WorkingDirectory $workingDirectory
        $vaultItem = Get-Item -LiteralPath $script:vaultLexicalRoot -Force -ErrorAction Stop
        if (-not $vaultItem.PSIsContainer) {
            throw 'Vault is not a directory.'
        }
        $script:vaultIdentityRoot = Get-PathIdentity -Path $script:vaultLexicalRoot
        if (Test-IsLocalProviderIdentity -Identity $script:vaultIdentityRoot) {
            throw 'Local provider aliases are not supported as the configured vault path.'
        }
    }
    catch {
        Stop-WithFailure -Message 'PII guard could not resolve the configured vault, so the write was blocked.'
    }

    $toolName = [string]$request.tool_name
    $toolInput = $request.tool_input
    switch ($toolName) {
        'Write' {
            if (-not (Test-IsStringProperty -Object $toolInput -Name 'file_path') -or
                [string]::IsNullOrEmpty([string]$toolInput.file_path) -or
                (Test-HasControlCharacter -Value ([string]$toolInput.file_path)) -or
                -not (Test-IsStringProperty -Object $toolInput -Name 'content') -or
                ([string]$toolInput.content).IndexOf([char]0) -ge 0 -or
                -not (Test-IsWithinContentLimit -Content ([string]$toolInput.content))) {
                Stop-WithFailure -Message 'PII guard received an invalid Write payload, so the write was blocked.'
            }
            Invoke-InspectWrite -RawPath ([string]$toolInput.file_path) -Content ([string]$toolInput.content) -WorkingDirectory $workingDirectory
        }
        'Edit' {
            if (-not (Test-IsStringProperty -Object $toolInput -Name 'file_path') -or
                [string]::IsNullOrEmpty([string]$toolInput.file_path) -or
                (Test-HasControlCharacter -Value ([string]$toolInput.file_path)) -or
                -not (Test-IsStringProperty -Object $toolInput -Name 'old_string') -or
                -not (Test-IsStringProperty -Object $toolInput -Name 'new_string') -or
                ([string]$toolInput.old_string).IndexOf([char]0) -ge 0 -or
                ([string]$toolInput.new_string).IndexOf([char]0) -ge 0 -or
                -not (Test-IsWithinContentLimit -Content ([string]$toolInput.old_string)) -or
                -not (Test-IsWithinContentLimit -Content ([string]$toolInput.new_string))) {
                Stop-WithFailure -Message 'PII guard received an invalid Edit payload, so the write was blocked.'
            }
            $replaceAll = $false
            if (Test-HasProperty -Object $toolInput -Name 'replace_all') {
                if ($null -ne $toolInput.replace_all -and -not ($toolInput.replace_all -is [bool])) {
                    Stop-WithFailure -Message 'PII guard received an invalid Edit payload, so the write was blocked.'
                }
                if ($null -ne $toolInput.replace_all) {
                    $replaceAll = [bool]$toolInput.replace_all
                }
            }
            $editArguments = @{
                RawPath = [string]$toolInput.file_path
                OldString = [string]$toolInput.old_string
                NewString = [string]$toolInput.new_string
                ReplaceAll = $replaceAll
                WorkingDirectory = $workingDirectory
            }
            Invoke-InspectEdit @editArguments
        }
        'apply_patch' {
            if (-not (Test-IsStringProperty -Object $toolInput -Name 'command') -or
                [string]::IsNullOrEmpty([string]$toolInput.command) -or
                ([string]$toolInput.command).IndexOf([char]0) -ge 0 -or
                -not (Test-IsWithinContentLimit -Content ([string]$toolInput.command))) {
                Stop-WithFailure -Message 'PII guard received an invalid apply_patch payload, so the write was blocked.'
            }
            Invoke-InspectPatch -Patch ([string]$toolInput.command) -WorkingDirectory $workingDirectory
        }
        default {
            Stop-WithFailure -Message 'PII guard received an unsupported tool name, so the write was blocked.'
        }
    }
    exit 0
}
catch {
    Stop-WithFailure -Message 'PII guard could not safely inspect the write request, so the write was blocked.'
}
