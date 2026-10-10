# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
Reads diff content from a PR reference XML with chunking and file filtering.
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
    [Parameter()]
    [Alias('i', 'Input')]
    [string]$InputPath = "",

    [Parameter(ParameterSetName = 'Chunk')]
    [Alias('c')]
    [int]$Chunk = 0,

    [Parameter()]
    [Alias('s')]
    [int]$ChunkSize = 500,

    [Parameter(ParameterSetName = 'Lines')]
    [Alias('l')]
    [string]$Lines = "",

    [Parameter(ParameterSetName = 'File')]
    [Alias('f')]
    [string]$File = "",

    [Parameter(ParameterSetName = 'Summary')]
    [switch]$Summary,

    [Parameter(ParameterSetName = 'Info')]
    [switch]$Info
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'shared.psm1') -Force

function Get-ChunkInfo {
    param([int]$TotalLines, [int]$ChunkSize)
    [PSCustomObject]@{
        TotalLines = $TotalLines
        ChunkSize = $ChunkSize
        TotalChunks = [math]::Ceiling($TotalLines / $ChunkSize)
    }
}

function Get-ChunkRange {
    param([int]$ChunkNumber, [int]$ChunkSize, [int]$TotalLines)
    [PSCustomObject]@{
        Start = (($ChunkNumber - 1) * $ChunkSize) + 1
        End = [math]::Min($ChunkNumber * $ChunkSize, $TotalLines)
    }
}

function Remove-DiffIndent {
    param([string]$Line)
    if ($Line -match '^\s{2}(diff --git|--- |\+\+\+ |@@ |\+|-| )') {
        return $Line.Substring(2)
    }
    return $Line
}

function Unquote-GitPath {
    param([string]$Path)
    $Path = $Path.Trim()
    if ($Path.Length -ge 2 -and $Path[0] -eq '"' -and $Path[$Path.Length - 1] -eq '"') {
        $inner = $Path.Substring(1, $Path.Length - 2)
        try {
            return [regex]::Unescape($inner)
        } catch {
            return $inner
        }
    }
    return $Path
}

function Get-DiffHeaderPath {
    param([string]$Line, [string]$Prefix)
    $normalized = Remove-DiffIndent $Line
    if ($normalized -notmatch ('^' + [regex]::Escape($Prefix))) { return $null }
    $value = $normalized.Substring($Prefix.Length)
    if ($value -match '^"(.*)"$') { return Unquote-GitPath $value }
    if ($value -match '^([^\t]+?)(?:\t.*)?$') { return Unquote-GitPath $Matches[1] }
    return $null
}

function Get-DiffBlocks {
    param([string[]]$Content)
    $blocks = @()
    $current = $null
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

function Get-BlockPaths {
    param([string[]]$Block)
    $oldPath = $null
    $newPath = $null
    $renameFrom = $null
    $renameTo = $null
    foreach ($rawLine in $Block) {
        $line = Remove-DiffIndent $rawLine
        if (-not $oldPath -and $line -match '^---\s+(.+?)(?:\t.*)?$') {
            $oldPath = Unquote-GitPath $Matches[1]
        }
        elseif (-not $newPath -and $line -match '^\+\+\+\s+(.+?)(?:\t.*)?$') {
            $newPath = Unquote-GitPath $Matches[1]
        }
        elseif (-not $renameFrom -and $line -match '^rename from\s+(.+)$') {
            $renameFrom = Unquote-GitPath $Matches[1]
        }
        elseif (-not $renameTo -and $line -match '^rename to\s+(.+)$') {
            $renameTo = Unquote-GitPath $Matches[1]
        }
    }
    if ($oldPath -like 'a/*') { $oldPath = $oldPath.Substring(2) }
    if ($newPath -like 'b/*') { $newPath = $newPath.Substring(2) }
    [PSCustomObject]@{
        Old = if ($renameFrom) { $renameFrom } else { $oldPath }
        New = if ($renameTo) { $renameTo } else { $newPath }
    }
}

function Get-BlockStats {
    param([string[]]$Block)
    $added = 0
    $removed = 0
    $inHunk = $false
    foreach ($rawLine in $Block) {
        $line = Remove-DiffIndent $rawLine
        if ($line -match '^@@(?:\s|$)') { $inHunk = $true; continue }
        if (-not $inHunk) { continue }
        if ($line -match '^\+\+\+') { continue }
        if ($line -match '^---') { continue }
        if ($line.StartsWith('+')) { $added++; continue }
        if ($line.StartsWith('-')) { $removed++; continue }
    }
    [PSCustomObject]@{ Added = $added; Removed = $removed }
}

function Get-FileDiff {
    param([string[]]$Content, [string]$FilePath)
    foreach ($block in Get-DiffBlocks $Content) {
        $paths = Get-BlockPaths $block
        if ($paths.New -eq $FilePath -or $paths.Old -eq $FilePath) {
            return ($block -join [Environment]::NewLine)
        }
    }
    return ""
}

function Get-DiffSummary {
    param([string[]]$Content)
    $files = @()
    foreach ($block in Get-DiffBlocks $Content) {
        $paths = Get-BlockPaths $block
        $stats = Get-BlockStats $block
        $path = if ($paths.New) { $paths.New } else { $paths.Old }
        if ($path) {
            $files += [PSCustomObject]@{ Path = $path; Added = $stats.Added; Removed = $stats.Removed }
        }
    }
    $output = @('Changed files:')
    foreach ($file in ($files | Sort-Object -Property Path)) {
        $output += "  $($file.Path) (+$($file.Added)/-$($file.Removed))"
    }
    return $output -join [Environment]::NewLine
}

function Invoke-ReadDiff {
    param(
        [string]$InputPath = "", [int]$Chunk = 0, [int]$ChunkSize = 500,
        [string]$Lines = "", [string]$File = "", [switch]$Summary, [switch]$Info
    )
    $repoRoot = Get-RepositoryRoot
    $xmlPath = if ($InputPath) { $InputPath } else { Join-Path $repoRoot '.copilot-tracking/pr/pr-reference.xml' }
    if (-not (Test-Path -LiteralPath $xmlPath)) { throw "PR reference file not found: $xmlPath`nRun generate.ps1 first to create the PR reference." }
    $content = @(Get-Content -LiteralPath $xmlPath)
    $totalLines = $content.Count
    $chunkInfo = Get-ChunkInfo $totalLines $ChunkSize

    if ($Info) {
        Write-Output "File: $xmlPath"
        Write-Output "Total lines: $totalLines"
        Write-Output "Chunk size: $ChunkSize"
        Write-Output "Total chunks: $($chunkInfo.TotalChunks)"
        Write-Output ""
        Write-Output "Chunk breakdown:"
        for ($i = 1; $i -le $chunkInfo.TotalChunks; $i++) {
            $range = Get-ChunkRange $i $ChunkSize $totalLines
            Write-Output "  Chunk ${i}: lines $($range.Start)-$($range.End)"
        }
        return
    }
    if ($Summary) { Write-Output (Get-DiffSummary $content); return }
    if ($File) {
        $fileDiff = Get-FileDiff $content $File
        if ($fileDiff) { Write-Output $fileDiff } else { Write-Warning "No diff found for file: $File" }
        return
    }
    if ($Chunk -gt 0) {
        if ($Chunk -gt $chunkInfo.TotalChunks) { throw "Chunk $Chunk exceeds file (only $($chunkInfo.TotalChunks) chunks available)" }
        $range = Get-ChunkRange $Chunk $ChunkSize $totalLines
        Write-Output "# Chunk $Chunk/$($chunkInfo.TotalChunks) (lines $($range.Start)-$($range.End) of $totalLines)"
        Write-Output ""
        $content[($range.Start - 1)..($range.End - 1)] | ForEach-Object { Write-Output $_ }
        return
    }
    if ($Lines) {
        $rangeParts = $Lines -replace ',', '-' -split '-'
        if ($rangeParts.Count -ne 2) { throw "Invalid line range format. Use START,END or START-END" }
        $start = [int]$rangeParts[0]
        $end = [math]::Min([int]$rangeParts[1], $totalLines)
        if ($start -gt $totalLines) { throw "Start line $start exceeds file length ($totalLines lines)" }
        Write-Output "# Lines $start-$end of $totalLines"
        Write-Output ""
        $content[($start - 1)..($end - 1)] | ForEach-Object { Write-Output $_ }
        return
    }
    Write-Output "File: $xmlPath"
    Write-Output "Total lines: $totalLines"
    Write-Output "Total chunks: $($chunkInfo.TotalChunks) (at $ChunkSize lines/chunk)"
    Write-Output ""
    Write-Output "Use -Chunk N to read a specific chunk, -Lines START,END for a range,"
    Write-Output "or -File PATH to extract a specific file's diff."
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-ReadDiff -InputPath $InputPath -Chunk $Chunk -ChunkSize $ChunkSize -Lines $Lines -File $File -Summary:$Summary -Info:$Info
        exit 0
    } catch {
        Write-Error -ErrorAction Continue $_.Exception.Message
        exit 1
    }
}
