#requires -Module WebSocket
<#
.SYNOPSIS
    Standard Site Indexer
.DESCRIPTION
    Standard Site Indexer.

    Uses the [WebSocket](https://github.com/PowerShellWeb/WebSocket) module to 
    index new `site.standard.document` and `site.standard.publication` records.
.NOTES
    This is a fairly standard script.  
    
    Feel free to copy it and reuse this convention elsewhere.

    The WebSocket module is a really good simple way to build an at protocol indexer.
#>
param(
# The jetstream url
[uri]
$jetstreamUrl = 
    "wss://jetstream$(1,2 | Get-Random).us-west.bsky.network/subscribe",

# The collections we are interested in.
[string[]]
$Collections = @("site.standard.document","site.standard.publication"),

# Any specific dids we want to watch.
[string[]]
$Dids = @(),

# The time back we want to ask for.
# (Generally only two days are available)
[TimeSpan]
$Since = [TimeSpan]::FromHours(24),

# The timeout.
# This is how long the job should run.
[TimeSpan]
$TimeOut = [TimeSpan]::FromMinutes(7),

# The root used to store content.
[string]
$Root = $PSScriptRoot
)

#region Declare Filters
filter getAt {
    $in = $_
    if ($in -notmatch '^at://') { return }
    $null, $did, $type, $rkey = $in -split '/{1,2}' -ne ''

    if (
        (-not $did) -or 
        (-not $type) -or 
        (-not $rkey)
    ) {return}

    $xrpcUrl = "https://bsky.social/xrpc/com.atproto.repo.getRecord?repo=$(
        $did
    )&collection=$(
        $type
    )&rkey=$(
        $rkey
    )"

    if (-not $script:atRecordCache) {
        $script:atRecordCache = @{}
    }
    if (-not $script:atRecordCache[$xrpcUrl]) {
        $script:atRecordCache[$xrpcUrl] = try {
            Invoke-RestMethod -Uri $xrpcUrl -ErrorAction Ignore
        } catch {
            Write-Warning "$_"
            $_
        }
    }
    $script:atRecordCache[$xrpcUrl]
}

filter toAtUri {
    $in = $_
    $did = $in.did
    $rkey = $in.commit.rkey
    $recordType = $in.commit.record.'$type'
    "at://$did/$recordType/$rkey"
}

filter toLocalPath {
    if ($in.uri -match '^at://') {
        $null, $did, $recordType, $rkey = $in.uri -split '/{1,2}'
    } else {
        $did = $in.did
        $rkey = $in.commit.rkey
        $recordType = $in.commit.record.'$type'
    }       
    
    if (-not $did) { return }
    if (-not $rkey) { return }
    if (-not $recordType) { return }
    "$(@($recordType -split '\.' -ne'')[-1])/$($did -replace ':', '_')/$rkey.json"
}


filter updateDocumentIndex {
    $in = $_ 
    $localPath = $in | toLocalPath   
    if (-not $localPath) { return }
    
    $inFilePath = Join-Path $root $localPath
    # We want to keep an index of the data, not the whole thing.

    $index = [Ordered]@{
        title = $in.commit.record.title
        path = $in.commit.record.path
        site = $in.commit.record.site
        atUri = $in | toAtUri
        publishedAt = $in.commit.record.publishedAt                
    }

    if ($in.commit.record.tags) {
        $index.tags = $in.commit.record.tags -join ';'
    }
        
    if (-not (Test-Path $inFilePath)) {                    
        New-Item -Path $inFilePath -Force -Value (ConvertTo-Json -InputObject $index -Compress)
    } else {
        Get-Item -Path $inFilePath
    }

}

filter updatePublicationIndex {
    $in = $_    
    $localPath = $in | toLocalPath   
    if (-not $localPath) { return }

    $inFilePath = Join-Path $root $localPath
    # We want to keep an index of the data, not the whole thing.    
    
    if ($in.commit.record.name) {
        $index = [Ordered]@{
            name = $in.commit.record.name
            atUri = $in | toAtUri
            description = $in.commit.record.description
            url = $in.commit.record.url        
        }     
    } else {
        $index = [Ordered]@{
            name = $in.value.name
            atUri = $in.uri
            description = $in.value.description
            url = $in.value.url
        }
    }

    if (
        $in.commit.record.preferences.showInDiscover -eq $false -or
        $in.value.preferences.showInDiscover -eq $false
    ) {
        $index.optout = $true
    }
       
    if (-not (Test-Path $inFilePath)) {                    
        New-Item -Path $inFilePath -Force -Value (ConvertTo-Json -InputObject $index -Compress)
    } else {
        Get-Item -Path $inFilePath
    }    
}

filter standardSiteRecord {
    $message = $_
    switch ($message.commit.collection) {
        site.standard.document {
            $message | updateDocumentIndex
        }
        site.standard.publication {
            $message | updatePublicationIndex
        }
    }
}
#endregion Declare Filters

#region Ride the Jetstream
$jetstreamUrl = @(
    "$jetstreamUrl"
    '?'
    @(
        foreach ($collection in $Collections) {            
            "wantedCollections=$([Uri]::EscapeDataString($collection))"
        }
        foreach ($did in $Dids) {
            "wantedDids=$([Uri]::EscapeDataString($did))"
        }
        "cursor=$([DateTimeOffset]::Now.Add(-$Since).ToUnixTimeMilliseconds())" 
    ) -join '&'
) -join ''

$Jetstream = WebSocket -SocketUrl $jetstreamUrl -Query @{
    wantedCollections = $collections
    cursor = ([DateTimeOffset]::Now - $since).ToUnixTimeMilliseconds()
} -TimeOut $TimeOut

Write-Host "Listening To Jetstream: $jetstreamUrl" -ForegroundColor Cyan
Write-Host "Starting loop @ $([DateTime]::Now)" -ForegroundColor Cyan
$batchStart = [DateTime]::Now
$filesFound = @()
do {
    $batch =$Jetstream | Receive-Job -ErrorAction Ignore     
    $batchStart = [DateTime]::Now
    $newFiles = $batch | 
        standardSiteRecord |
        Add-Member NoteProperty CommitMessage "Syncing from at protocol [skip ci]" -Force -PassThru
    if ($batch) {
        $lastPostTime = [DateTimeOffset]::FromUnixTimeMilliseconds($batch[-1].time_us / 1000).DateTime
        Write-Host "Processed batch of $($batch.Length) in $([DateTime]::Now - $batchStart) - Last Post @ $($lastPostTime)" -ForegroundColor Green
        if ($newFiles) {
            Write-Host "Found $(@($newFiles).Length) items to index" -ForegroundColor Green
            $filesFound += $newFiles            
            $newFiles
        }
    }
    
    Start-Sleep -Milliseconds (Get-Random -Min .1kb -Max 1kb)
} while ($Jetstream.JobStateInfo.State -in 'NotStarted','Running') 

$Jetstream | 
    Receive-Job -ErrorAction Ignore | 
    standardSiteRecord |
    Add-Member NoteProperty CommitMessage "Syncing from at protocol [skip ci]" -Force -PassThru
#endregion Ride the Jetstream

#region Backfill Publications

# When we see new articles, we might not yet have their publications

# So find all of the site uris
$siteUris = 
    Get-ChildItem ./document/ -recurse -file | 
    Get-Content -Raw | 
    ConvertFrom-Json |
    Select-Object -ExpandProperty site -Unique

# and see which ones we have already cached.
$pubUris = 
    Get-ChildItem ./publication/ -recurse -file | 
    Get-Content -Raw | 
    ConvertFrom-Json |
    Select-Object -ExpandProperty atUri -Unique

# Then make a list of which are missing.
$missingPublications = 
    @($siteUris |
        Where-Object {
            $_ -match '^at://' -and
            $_ -notin $pubUris
        })

# If any are missing, backfill the publications
if ($missingPublications.Count) {
    Write-Host "Backfilling $($missingPublications.Length) publications" -ForegroundColor Cyan

    $backfilled = $missingPublications | getAt

    $backfilled |
        Where-Object { $_ -isnot [Management.Automation.ErrorRecord]} | 
        updatePublicationIndex |
        Add-Member NoteProperty CommitMessage "Syncing from at protocol [skip ci]" -Force -PassThru
}
#endregion Backfill Publications