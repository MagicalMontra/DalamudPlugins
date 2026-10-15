#requires -Version 5.1
<#
.SYNOPSIS
Creates/publishes MagicalMontra/DalamudPlugins as a combined Dalamud feed.
.DESCRIPTION
No PackagePath: migrate the currently published Vendor Runner and Wahventory
packages into the new repository. PackagePath: publish a new local compiled
package, preserving other feed entries. Without -Publish, prepare locally only.
No old repository is deleted. No source repository visibility is changed.
#>
[CmdletBinding()]
param(
    [string[]]$PackagePath = @(),
    [string]$OutputDirectory,
    [switch]$Publish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Owner = 'MagicalMontra'
$Repository = 'MagicalMontra/DalamudPlugins'
$RepositoryUrl = "https://github.com/$Repository"
$Marker = 'MagicalMontra combined Dalamud plugin feed'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Work = Join-Path ([IO.Path]::GetTempPath()) ('combined-feed-' + [Guid]::NewGuid().ToString('N'))
$Sources = @(
    @{ Id = 'VendorRunner'; Repo = 'MagicalMontra/VendorRunner-Feed' },
    @{ Id = 'wahventory'; Repo = 'MagicalMontra/wahventory' }
)

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Get-Property($Object, [string]$Name, $Default) {
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Invoke-Gh([string[]]$Arguments, [switch]$AllowMissing) {
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& gh @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($code -ne 0) {
        if ($AllowMissing -and $text -match '(HTTP 404|"status"\s*:\s*"?404"?)') { return $null }
        throw "GitHub CLI failed (exit $code):`n$text"
    }
    return $text
}

function Read-Api([string]$Endpoint, [switch]$AllowMissing) {
    $text = Invoke-Gh -Arguments @('api', '--hostname', 'github.com', '--method', 'GET', $Endpoint) -AllowMissing:$AllowMissing
    if ($null -eq $text) { return $null }
    $decoded = ConvertFrom-Json -InputObject $text
    return $decoded
}

function Write-Api([string]$Method, [string]$Endpoint, $Body) {
    $path = Join-Path $script:Work ('request-' + [Guid]::NewGuid().ToString('N') + '.json')
    Write-Text $path (ConvertTo-Json -InputObject $Body -Depth 50)
    $text = Invoke-Gh -Arguments @('api', '--hostname', 'github.com', '--method', $Method, $Endpoint, '--input', $path)
    if (-not [string]::IsNullOrWhiteSpace($text)) { return ($text | ConvertFrom-Json) }
}

function Download-Public([string]$Url, [string]$Path) {
    if (([Uri]$Url).Scheme -ne 'https') { throw 'Only HTTPS downloads are allowed.' }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -UseBasicParsing -OutFile $Path -TimeoutSec 60 -MaximumRedirection 10 | Out-Null
            return
        } catch {
            if ($attempt -eq 4) { throw "Anonymous download failed: $Url`n$($_.Exception.Message)" }
            Start-Sleep -Seconds (2 * ($attempt + 1))
        }
    }
}

function Hash-Of([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Identity($Manifest) {
    $id = [string](Get-Property $Manifest 'InternalName' '')
    if (@('VendorRunner', 'wahventory') -cnotcontains $id) {
        throw "Unrecognized InternalName '$id'. Only your Vendor Runner and Wahventory fork are supported."
    }
    $version = [string](Get-Property $Manifest 'AssemblyVersion' '')
    if ($version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "Invalid AssemblyVersion for $id." }
    $null = [Version]$version
    if ([int](Get-Property $Manifest 'DalamudApiLevel' 0) -le 0) { throw "Missing DalamudApiLevel for $id." }
    foreach ($field in @('Name', 'Author')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-Property $Manifest $field ''))) { throw "Missing $field for $id." }
    }
    $testing = [string](Get-Property $Manifest 'TestingAssemblyVersion' '')
    if ($testing -and $testing -ne $version) {
        throw "A separate testing version for $id needs separate assets. This publisher will not silently collapse stable/testing versions."
    }
}

function Read-Package([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @('VendorRunner.json', 'wahventory.json')
        $matches = @($zip.Entries | Where-Object { $names -ccontains $_.FullName })
        if ($matches.Count -ne 1 -or $matches[0].Length -gt 1048576) {
            throw 'Package needs exactly one supported plugin manifest at the ZIP root. Do not use a source ZIP.'
        }
        $reader = New-Object IO.StreamReader($matches[0].Open())
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        Assert-Identity $manifest
        $dllName = [string]$manifest.InternalName + '.dll'
        $dlls = @($zip.Entries | Where-Object { $_.FullName -ceq $dllName })
        if ($dlls.Count -ne 1 -or $dlls[0].Length -lt 64) { throw "Missing/non-assembly root file: $dllName" }
        $stream = $dlls[0].Open()
        try {
            if ($stream.ReadByte() -ne 77 -or $stream.ReadByte() -ne 90) { throw "$dllName does not have a PE header." }
        } finally { $stream.Dispose() }
        if ($manifest.InternalName -ceq 'VendorRunner' -and $null -eq $zip.GetEntry('VendorRunner.Core.dll')) {
            throw 'VendorRunner.Core.dll is missing.'
        }
        return $manifest
    } finally { $zip.Dispose() }
}

function Prepare-LocalPackage([string]$InputPath, [string]$Destination) {
    # Public-source migrations copy already-public packages byte for byte.
    # Local builds are reduced to runtime files to exclude source, PDBs and logs.
    $inputZip = [IO.Compression.ZipFile]::OpenRead($InputPath)
    $outputZip = [IO.Compression.ZipFile]::Open($Destination, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $seen = @{}
        foreach ($file in $inputZip.Entries) {
            $name = $file.FullName.Replace('\', '/')
            if ($name.EndsWith('/')) { continue }
            if ($name.StartsWith('/') -or $name.Contains('../') -or $name.Contains(':')) { throw "Unsafe ZIP path: $name" }
            if ($name -match '(^|/)(src|source|docs|logs|verification|\.git)(/|$)') { continue }
            if ($name -notmatch '(?i)(\.(dll|json|xml|png|jpg|jpeg|webp|svg|dat|bin|yaml|yml)$|(^|/)(LICENSE[^/]*|COPYING[^/]*|NOTICE[^/]*|THIRD.PARTY.NOTICES[^/]*))') { continue }
            if ($seen.ContainsKey($name)) { throw "Duplicate ZIP entry: $name" }
            $seen[$name] = $true
            $target = $outputZip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $target.LastWriteTime = [DateTimeOffset]::Parse('2000-01-01T00:00:00+00:00')
            $from = $file.Open()
            $to = $target.Open()
            try { $from.CopyTo($to) } finally { $to.Dispose(); $from.Dispose() }
        }
    } finally { $outputZip.Dispose(); $inputZip.Dispose() }
}

function Find-Release([string]$Tag) {
    $release = Read-Api "repos/$script:Repository/releases/tags/$Tag" -AllowMissing
    if ($null -eq $release) {
        # Find drafts left by interrupted uploads without overwriting their assets.
        for ($page = 1; $page -le 20; $page++) {
            $items = @(Read-Api "repos/$script:Repository/releases?per_page=100&page=$page")
            $matches = @($items | Where-Object { $_.tag_name -ceq $Tag })
            if ($matches.Count -gt 1) { throw "Ambiguous release tag: $Tag" }
            if ($matches.Count -eq 1) { return $matches[0] }
            if ($items.Count -lt 100) { return $null }
        }
        throw 'Release enumeration exceeded the page limit.'
    }
    return $release
}

function Read-Feed([string]$Text) {
    if (-not $Text.TrimStart().StartsWith('[')) { throw 'Feed must be a JSON array.' }
    # Windows PowerShell can emit a JSON array as a single pipeline object.
    # Assign first, then enumerate the decoded value, avoiding nested arrays.
    $decoded = ConvertFrom-Json -InputObject $Text
    $items = @($decoded)
    $seen = @{}
    foreach ($entry in $items) {
        Assert-Identity $entry
        if ($seen.ContainsKey($entry.InternalName)) { throw 'Duplicate plugin identity in feed.' }
        $seen[$entry.InternalName] = $true
    }
    return $items
}

try {
    # Resolve defaults after parameter binding, not inside param(). A caller that
    # supplies -OutputDirectory does not depend on script-root discovery at all.
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $baseDirectory = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($baseDirectory) -and
            -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
            $baseDirectory = Split-Path -Path $PSCommandPath -Parent
        }
        if ([string]::IsNullOrWhiteSpace($baseDirectory)) {
            throw 'Could not determine the publisher directory. Run the saved .ps1 using -File, or supply an absolute -OutputDirectory path.'
        }
        $OutputDirectory = Join-Path -Path $baseDirectory -ChildPath 'DalamudPlugins-publication'
    }
    New-Item -ItemType Directory -Path $Work | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $jobs = @()

    if ($PackagePath.Count -eq 0) {
        foreach ($source in $Sources) {
            $sourceFile = Join-Path $Work ($source.Id + '-source.json')
            Download-Public "https://raw.githubusercontent.com/$($source.Repo)/main/repo.json" $sourceFile
            $entries = @(Read-Feed ([IO.File]::ReadAllText($sourceFile)))
            $matching = @($entries | Where-Object { $_.InternalName -ceq $source.Id })
            if ($matching.Count -ne 1) { throw "Expected exactly one $($source.Id) in its original feed." }
            $entry = $matching[0]
            Assert-Identity $entry
            $url = [string]$entry.DownloadLinkInstall
            $prefix = "https://github.com/$($source.Repo)/releases/download/"
            if (-not $url.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Unexpected source download repository.' }
            foreach ($key in @('DownloadLinkUpdate', 'DownloadLinkTesting')) {
                $other = [string](Get-Property $entry $key '')
                if ($other -and $other -cne $url) { throw 'Distinct source assets require explicit migration; refusing to discard a download channel.' }
            }
            $path = Join-Path $Work ($source.Id + '-original.zip')
            Download-Public $url $path
            $manifest = Read-Package $path
            if ($manifest.InternalName -cne $entry.InternalName -or
                [string]$manifest.AssemblyVersion -cne [string]$entry.AssemblyVersion -or
                [int]$manifest.DalamudApiLevel -ne [int]$entry.DalamudApiLevel) {
                throw 'Source ZIP and its feed metadata disagree. Nothing will be advertised.'
            }
            $jobs += [PSCustomObject]@{ Entry = $entry; Zip = $path; Hash = (Hash-Of $path) }
        }
    } else {
        foreach ($inputPath in $PackagePath) {
            if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw "Package not found: $inputPath" }
            $resolved = (Resolve-Path -LiteralPath $inputPath).Path
            $manifest = Read-Package $resolved
            $path = Join-Path $Work ([Guid]::NewGuid().ToString('N') + '.zip')
            Prepare-LocalPackage $resolved $path
            $manifest = Read-Package $path
            $jobs += [PSCustomObject]@{ Entry = $manifest; Zip = $path; Hash = (Hash-Of $path) }
        }
    }
    $identities = @{}
    foreach ($job in $jobs) {
        $id = [string]$job.Entry.InternalName
        if ($identities.ContainsKey($id)) { throw "Two input packages refer to $id." }
        $identities[$id] = $true
        $assetName = "$id-$($job.Entry.AssemblyVersion).zip"
        Copy-Item -LiteralPath $job.Zip -Destination (Join-Path $OutputDirectory $assetName) -Force
        Write-Text (Join-Path $OutputDirectory ($id + '-manifest.json')) (ConvertTo-Json -InputObject $job.Entry -Depth 50)
        Write-Host "Prepared $id $($job.Entry.AssemblyVersion), SHA256 $($job.Hash)"
    }
    if (-not $Publish) {
        Write-Host "Prepared locally: $OutputDirectory"
        Write-Host 'Nothing created on GitHub. Run with -Publish to create/update the public combined repository.'
        return
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI (gh) is required. Run gh auth login --hostname github.com.' }
    $login = (Invoke-Gh -Arguments @('api', '--hostname', 'github.com', 'user', '--jq', '.login')).Trim()
    if ($login -ine $Owner) { throw "Active GitHub account is $login, not $Owner." }
    $repo = Read-Api "repos/$Repository" -AllowMissing
    if ($null -eq $repo) {
        $repo = Write-Api 'POST' 'user/repos' ([ordered]@{
            name = 'DalamudPlugins'; description = $Marker; private = $false; auto_init = $true; has_wiki = $false
        })
    }
    if ($repo.private -or $repo.description -cne $Marker) {
        throw 'Existing repository is private or unrelated. It was not overwritten or made public.'
    }
    $branch = [string]$repo.default_branch
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Repository default branch is not ready. Run the script again.' }
    $feedUrl = "https://raw.githubusercontent.com/$Repository/$branch/repo.json"
    $file = Read-Api "repos/$Repository/contents/repo.json?ref=$([Uri]::EscapeDataString($branch))" -AllowMissing
    $combined = @()
    if ($null -ne $file) {
        $existingText = $Utf8.GetString([Convert]::FromBase64String([string]$file.content))
        $combined = @(Read-Feed $existingText)
    }
    foreach ($entry in $combined) {
        foreach ($key in @('DownloadLinkInstall', 'DownloadLinkUpdate', 'DownloadLinkTesting')) {
            $link = [string](Get-Property $entry $key '')
            if ($link -and -not $link.StartsWith("$RepositoryUrl/releases/download/", [StringComparison]::Ordinal)) {
                throw 'Existing combined feed still references an external release. Refusing a partial migration.'
            }
        }
    }
    foreach ($job in $jobs) {
        $entry = $job.Entry
        $id = [string]$entry.InternalName
        $version = [string]$entry.AssemblyVersion
        $prior = @($combined | Where-Object { $_.InternalName -ceq $id })
        if ($prior.Count -eq 1 -and [Version]$prior[0].AssemblyVersion -gt [Version]$version) {
            throw "Refusing to downgrade $id. The current combined feed is newer than this input."
        }
        $tag = "$id-v$version"
        $assetName = "$id-$version.zip"
        $uploadPath = Join-Path $OutputDirectory $assetName
        $downloadUrl = "$RepositoryUrl/releases/download/$tag/$assetName"
        $release = Find-Release $tag
        if ($null -eq $release) {
            $body = "$id $version. Compiled package; no claim of live-game validation.`n`nSHA256: $($job.Hash)`n`nFeed: $feedUrl"
            if ($id -ceq 'wahventory') { $body += "`n`nSource and license: https://github.com/MagicalMontra/wahventory" }
            $release = Write-Api 'POST' "repos/$Repository/releases" ([ordered]@{
                tag_name = $tag; target_commitish = $branch; name = "$id $version"; body = $body; draft = $true; prerelease = ($id -ceq 'VendorRunner')
            })
        }
        $assets = @($release.assets | Where-Object { $_.name -ceq $assetName })
        if ($assets.Count -eq 0) {
            Invoke-Gh -Arguments @('release', 'upload', $tag, $uploadPath, '--repo', $RepositoryUrl) | Out-Null
        } elseif ($assets.Count -eq 1) {
            $checkDir = Join-Path $Work ($id + '-existing')
            New-Item -ItemType Directory -Path $checkDir | Out-Null
            Invoke-Gh -Arguments @('release', 'download', $tag, '--repo', $RepositoryUrl, '--pattern', $assetName, '--dir', $checkDir) | Out-Null
            if ((Hash-Of (Join-Path $checkDir $assetName)) -cne $job.Hash) {
                throw "$tag already contains different bytes. Bump the version and rebuild; this script never overwrites a published asset."
            }
        } else { throw 'Duplicate release asset names.' }
        if ($release.draft) {
            Write-Api 'PATCH' "repos/$Repository/releases/$($release.id)" @{ draft = $false } | Out-Null
        }
        $publicZip = Join-Path $Work ($id + '-public.zip')
        Download-Public $downloadUrl $publicZip
        if ((Hash-Of $publicZip) -cne $job.Hash) { throw 'Public download hash differs. Feed has not been updated.' }
        $newEntry = [ordered]@{}
        foreach ($p in $entry.PSObject.Properties) { $newEntry[$p.Name] = $p.Value }
        foreach ($key in @('InstalledFromUrl', 'Disabled', 'ScheduledForDeletion', 'WorkingPluginId')) { $newEntry.Remove($key) }
        $newEntry['DownloadLinkInstall'] = $downloadUrl
        $newEntry['DownloadLinkUpdate'] = $downloadUrl
        $newEntry['DownloadLinkTesting'] = $downloadUrl
        $newEntry['LastUpdate'] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($id -ceq 'VendorRunner') { $newEntry['RepoUrl'] = $RepositoryUrl }
        else { $newEntry['RepoUrl'] = 'https://github.com/MagicalMontra/wahventory' }
        $combined = @($combined | Where-Object { $_.InternalName -cne $id }) + @([PSCustomObject]$newEntry)
    }
    $combined = @($combined | Sort-Object InternalName)
    $json = ConvertTo-Json -InputObject $combined -Depth 50
    $payload = [ordered]@{
        message = 'Publish combined Dalamud plugin feed'
        content = [Convert]::ToBase64String($Utf8.GetBytes($json))
        branch = $branch
    }
    if ($null -ne $file) { $payload['sha'] = [string]$file.sha }
    Write-Api 'PUT' "repos/$Repository/contents/repo.json" $payload | Out-Null
    Write-Text (Join-Path $OutputDirectory 'repo.json') $json
    # Persist this publisher in the new repo, but never overwrite another revision.
    $scriptRemote = Read-Api "repos/$Repository/contents/Publish-DalamudPlugins.ps1?ref=$([Uri]::EscapeDataString($branch))" -AllowMissing
    if ($null -eq $scriptRemote) {
        $scriptText = [IO.File]::ReadAllText($PSCommandPath)
        Write-Api 'PUT' "repos/$Repository/contents/Publish-DalamudPlugins.ps1" ([ordered]@{
            message = 'Add shared publisher for future compiled plugin updates'
            content = [Convert]::ToBase64String($Utf8.GetBytes($scriptText)); branch = $branch
        }) | Out-Null
    }
    $usageFile = Read-Api "repos/$Repository/contents/FEED_USAGE.md?ref=$([Uri]::EscapeDataString($branch))" -AllowMissing
    if ($null -eq $usageFile) {
        $usage = "# MagicalMontra combined Dalamud feed`n`n" +
            "Custom repository URL: $feedUrl`n`n" +
            "Contains Vendor Runner and the custom Wahventory fork. Release ZIPs are hosted in this repository.`n`n" +
            "For future versions, run Publish-DalamudPlugins.ps1 -PackagePath <compiled-plugin.zip> -Publish. " +
            "The publisher merges the updated entry and preserves the other plugin. Bump the assembly version for changed binaries.`n`n" +
            "No-argument migration reads the old feeds; it is for initial setup, not a scheduled update service. " +
            "After retiring the old feed-only repository, publish new packages directly here.`n`n" +
            "Keep the source repositories: MagicalMontra/VendorRunner and https://github.com/MagicalMontra/wahventory . " +
            "No automatic source merge, repository deletion or visibility change is performed.`n`n" +
            "When changing a third-party source URL in Dalamud, reinstall from the new source while retaining plugin configuration.`n"
        Write-Api 'PUT' "repos/$Repository/contents/FEED_USAGE.md" ([ordered]@{
            message = 'Document combined feed usage and update publishing'
            content = [Convert]::ToBase64String($Utf8.GetBytes($usage)); branch = $branch
        }) | Out-Null
    }
    # Public feed checks never use GitHub authentication.
    $verified = $false
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            $publicFile = Join-Path $Work 'public-feed.json'
            Download-Public $feedUrl $publicFile
            $actual = @(Read-Feed ([IO.File]::ReadAllText($publicFile)))
            if ($actual.Count -ne $combined.Count) { throw 'Public feed is not current yet.' }
            foreach ($expected in $combined) {
                $match = @($actual | Where-Object { $_.InternalName -ceq $expected.InternalName })
                if ($match.Count -ne 1) { throw 'Public feed is missing a plugin.' }
                foreach ($key in @('AssemblyVersion', 'DalamudApiLevel', 'DownloadLinkInstall', 'DownloadLinkUpdate', 'DownloadLinkTesting')) {
                    if ([string]$match[0].$key -cne [string]$expected.$key) { throw 'Public feed is not current yet.' }
                }
            }
            $verified = $true
            break
        } catch {
            if ($attempt -eq 5) { throw "Feed committed, but anonymous verification failed. Keep old repositories until verification succeeds.`n$($_.Exception.Message)" }
            Start-Sleep -Seconds 5
        }
    }
    if (-not $verified) { throw 'Public verification incomplete.' }
    Write-Text (Join-Path $OutputDirectory 'FEED_URL.txt') ($feedUrl + "`n")
    Write-Host ''
    Write-Host 'FEED READY'
    Write-Host $feedUrl
    foreach ($entry in $combined) { Write-Host ("  " + $entry.InternalName + ' ' + $entry.AssemblyVersion) }
    Write-Host 'All install/update downloads in this feed are hosted in the new repository.'
    Write-Host 'Keep the VendorRunner and wahventory SOURCE repositories. Nothing was deleted.'
    Write-Host 'Future updates: run this publisher with -PackagePath <new-built-zip> -Publish.'
} catch {
    Write-Error -ErrorAction Continue $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

# END COMBINED DALAMUD FEED PUBLISHER
