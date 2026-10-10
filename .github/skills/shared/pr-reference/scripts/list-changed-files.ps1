# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
Extracts and lists all changed files from a PR reference XML.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [Alias('i', 'Input')]
    [string]$InputPath = "",
    [Parameter()]
    [Alias('t')]
    [string[]]$Type = @('All'),
    [Parameter()]
    [string[]]$ExcludeType = @(),
    [Parameter()]
    [Alias('f')]
    [ValidateSet('Plain', 'Json', 'Markdown')]
    [string]$Format = "Plain"
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'shared.psm1') -Force

function Remove-DiffIndent {
    param([string]$Line)
    if ($Line -match '^\s{2}(diff --git|--- |\+\+\+ |@@ |\+|-| )') { return $Line.Substring(2) }
    return $Line
}

function Unquote-GitPath {
    param([string]$Path)
    $Path = $Path.Trim()
    if ($Path.Length -ge 2 -and $Path[0] -eq '"' -and $Path[$Path.Length - 1] -eq '"') {
        $inner = $Path.Substring(1, $Path.Length - 2)
        try { return [regex]::Unescape($inner) } catch { return $inner }
    }
    return $Path
}

function Get-DiffBlocks {
    param([string[]]$Content)
    $blocks = @(); $current = $null
    foreach ($rawLine in $Content) {
        $line = Remove-DiffIndent $rawLine
        if ($line -match '^diff --git(?:\s|$)') {
            if ($null -ne $current) { $blocks += ,$current }
            $current = [System.Collections.Generic.List[string]]::new()
        }
        if ($null -ne $current) { $current.Add($rawLine) }
    }
    if ($null -ne $current) { $blocks += ,$current }
    return $blocks
}

function Get-BlockMetadata {
    param([string[]]$Block)
    $oldPath = $null; $newPath = $null; $renameFrom = $null; $renameTo = $null; $isAdded = $false; $isDeleted = $false
    foreach ($rawLine in $Block) {
        $line = Remove-DiffIndent $rawLine
        if ($line -match '^new file mode') { $isAdded = $true }
        elseif ($line -match '^deleted file mode') { $isDeleted = $true }
        elseif (-not $oldPath -and $line -match '^---\s+(.+)$') { $oldPath = Unquote-GitPath $Matches[1] }
        elseif (-not $newPath -and $line -match '^\+\+\+\s+(.+)$') { $newPath = Unquote-GitPath $Matches[1] }
        elseif (-not $renameFrom -and $line -match '^rename from\s+(.+)$') { $renameFrom = Unquote-GitPath $Matches[1] }
        elseif (-not $renameTo -and $line -match '^rename to\s+(.+)$') { $renameTo = Unquote-GitPath $Matches[1] }
    }
    if ($oldPath -like 'a/*') { $oldPath = $oldPath.Substring(2) }
    if ($newPath -like 'b/*') { $newPath = $newPath.Substring(2) }
    $old = if ($renameFrom) { $renameFrom } else { $oldPath }
    $new = if ($renameTo) { $renameTo } else { $newPath }
    $type = if ($isAdded) { 'Added' } elseif ($isDeleted) { 'Deleted' } elseif ($renameFrom -or $renameTo -or ($old -and $new -and $old -ne $new)) { 'Renamed' } else { 'Modified' }
    [PSCustomObject]@{ Old = $old; New = $new; Type = $type }
}

function Get-FileChanges {
    param([string]$XmlPath, [string[]]$FilterType = @('All'), [string[]]$ExcludeFilterType = @())
    $normalizedFilter = @($FilterType | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $normalizedExclude = @($ExcludeFilterType | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $validTypes = @('All', 'Added', 'Deleted', 'Modified', 'Renamed')
    foreach ($t in $normalizedFilter) { if ($t -notin $validTypes) { throw "Invalid type filter: '$t'. Valid values: $($validTypes -join ', ')" } }
    foreach ($t in $normalizedExclude) { if ($t -notin @('Added', 'Deleted', 'Modified', 'Renamed')) { throw "Invalid exclude type: '$t'. Valid values: Added, Deleted, Modified, Renamed" } }

    $content = @(Get-Content -LiteralPath $XmlPath)
    $changes = @()
    foreach ($block in Get-DiffBlocks $content) {
        $metadata = Get-BlockMetadata $block
        if ($metadata.Type -in $normalizedExclude) { continue }
        if ('All' -notin $normalizedFilter -and $metadata.Type -notin $normalizedFilter) { continue }
        $displayPath = if ($metadata.Type -eq 'Renamed') { "$($metadata.Old) -> $($metadata.New)" } else { $metadata.New ?? $metadata.Old }
        if ($displayPath) { $changes += [PSCustomObject]@{ Path = $displayPath; Type = $metadata.Type } }
    }
    return $changes | Sort-Object -Property Path
}

function Format-Output {
    param([PSCustomObject[]]$Changes, [string]$OutputFormat = 'Plain')
    switch ($OutputFormat) {
        'Plain' { return ($Changes | ForEach-Object { $_.Path }) -join [Environment]::NewLine }
        'Json' { return $Changes | ConvertTo-Json -Depth 2 }
        'Markdown' {
            $lines = @('| File | Change Type |', '|------|-------------|')
            foreach ($change in $Changes) { $lines += "| ``$($change.Path)`` | $($change.Type) |" }
            return $lines -join [Environment]::NewLine
        }
    }
}

function Invoke-ListChangedFiles {
    param([string]$InputPath = "", [string[]]$Type = @('All'), [string[]]$ExcludeType = @(), [string]$Format = 'Plain')
    $hasNonAllType = ($Type | Where-Object { $_ -ne 'All' }).Count -gt 0
    if ($hasNonAllType -and $ExcludeType.Count -gt 0) { throw "-Type and -ExcludeType are mutually exclusive when -Type is not 'All'." }
    $repoRoot = Get-RepositoryRoot
    $xmlPath = if ($InputPath) { $InputPath } else { Join-Path $repoRoot '.copilot-tracking/pr/pr-reference.xml' }
    if (-not (Test-Path -LiteralPath $xmlPath)) { throw "PR reference file not found: $xmlPath`nRun generate.ps1 first to create the PR reference." }
    Write-Output (Format-Output -Changes (Get-FileChanges -XmlPath $xmlPath -FilterType $Type -ExcludeFilterType $ExcludeType) -OutputFormat $Format)
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-ListChangedFiles -InputPath $InputPath -Type $Type -ExcludeType $ExcludeType -Format $Format; exit 0 }
    catch { Write-Error -ErrorAction Continue $_.Exception.Message; exit 1 }
}
