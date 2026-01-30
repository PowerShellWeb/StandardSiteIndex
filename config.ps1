#requires -Module Organize, Turtle

if (-not $global:site) {
    $global:site = [Ordered]@{}
}

#region Populate At Protocol Data
if (-not $global:site.AtData.Tables) {
    $global:site.AtData = [Data.DataSet]::new()
    $ssd = $global:site.AtData.Tables.Add("site.standard.document")
    $ssd.Columns.AddRange(@(
        [Data.DataColumn]::new('title', [string], '', 'Attribute')
        [Data.DataColumn]::new('path', [string], '', 'Attribute')
        [Data.DataColumn]::new('site', [string], '', 'Attribute')
        [Data.DataColumn]::new('atUri', [string], '', 'Attribute')
        [Data.DataColumn]::new('publishedAt', [DateTime], '', 'Attribute')
        [Data.DataColumn]::new('tags', [string], '', 'Attribute')
    ))

    Get-ChildItem -Path ./document -Recurse -File |
        Get-Content -Raw |
        ConvertFrom-Json |
        Foreach-Object {
            $in = $_
            $newRow = $ssd.NewRow()
            $newRow.title = $in.title
            $newRow.path = $in.path
            $newRow.site = $in.site
            $newRow.atUri = $in.atUri
            if ($in.publishedAt) {
                $newRow.publishedAt = $in.publishedAt
            }            
            $newRow.tags = $in.tags
            $ssd.Rows.Add($newRow)
        }


    $ssp = $global:site.AtData.Tables.Add("site.standard.publication")
    $ssp.Columns.AddRange(@(
        [Data.DataColumn]::new('name', [string], '', 'Attribute')
        [Data.DataColumn]::new('atUri', [string], '', 'Attribute')
        [Data.DataColumn]::new('description', [string], '', 'Attribute')
        [Data.DataColumn]::new('url', [string], '', 'Attribute')        
        $optOut = [Data.DataColumn]::new('optout', [bool], '', 'Attribute')
        $optOut.DefaultValue = $false
        $optOut
    ))

    Get-ChildItem -Path ./publication -Recurse -File |
        Get-Content -Raw |
        ConvertFrom-Json |
        Foreach-Object {
            $in = $_
            $newRow = $ssp.NewRow()
            $newRow.name = $in.name
            $newRow.url = $in.url
            $newRow.description = $in.description
            $newRow.atUri = $in.atUri
            if ($in.optout) {
                $newRow.optout = $true
            }            
            $ssp.Rows.Add($newRow)
        }

    $ssi = $global:site.AtData.Tables.Add("site.standard.index")
    $ssi.Columns.AddRange(@(
        [Data.DataColumn]::new('title', [string], '', 'Attribute')        
        [Data.DataColumn]::new('url', [string], '', 'Attribute')
        [Data.DataColumn]::new('publishedAt', [DateTime], '', 'Attribute')
        [Data.DataColumn]::new('atUri', [string], '', 'Attribute')
        [Data.DataColumn]::new('site', [string], '', 'Attribute')
        [Data.DataColumn]::new('name', [string], '', 'Attribute')
        [Data.DataColumn]::new('tags', [string], '', 'Attribute')
        [Data.DataColumn]::new('description', [string], '', 'Attribute')
    ))

    foreach ($pub in $ssp.Select("optout = false")) {
        foreach ($doc in $ssd.Select("site = '$($pub.aturi)'")) {
            $finalUrl = ($pub.url -replace '/$'), ($doc.path -replace '^/') -join '/'
            $newRow = $ssi.NewRow()
            $newRow.title = $doc.title
            $newRow.name = $pub.name
            $newRow.atUri = $doc.atUri
            $newRow.url = $finalUrl
            $newRow.site = $doc.site 
            $newRow.description = $pub.description
            $newRow.tags = $doc.tags
            if ($doc.publishedAt) {
                $newRow.publishedAt = $doc.publishedAt
            }            
            $ssi.Rows.add($newRow)
        }
    }    
}
#endregion Populate At Protocol Data

Write-Host -ForegroundColor Cyan "Organizing index of $($global:site.AtData.tables['site.standard.index'].Rows.Count) rows"

$organized = $global:site.AtData.tables['site.standard.index'].Select('
    PublishedAt IS NOT NULL','PublishedAt DESC'
) | 
    organize 'PublishedAt.Year/Month/Day'

Write-Host -ForegroundColor Cyan "Organized index into $($organized.Output.Count) buckets"

$indexHtmlTemplate = (Get-Command ./index.html.ps1 -CommandType ExternalScript).ScriptBlock

foreach ($year in $organized.Output.Keys) {
    Write-Host -ForegroundColor Cyan "Year: $year"
    $yearPath = Join-Path -Path $PSScriptRoot $year
    $yearIndex = @()
    foreach ($month in $organized.Output[$year].Keys) {
        $monthPath = Join-Path -Path $yearPath $(
            "{0:d2}" -f ($month -as [int])
        )
        $monthIndex = @()        
        foreach ($day in $organized.Output[$year][$month].Keys) {
            if (-not $day) { continue }
            $dayPath = Join-Path $monthPath $(
                "{0:d2}" -f ($day -as [int])
            )
            
            $dayIndex = $organized.Output[$year][$month][$day] |
                Select-Object $site.AtData.tables['site.standard.index'].Columns.ColumnName
            
            $monthIndex += $dayIndex
            
            New-Item -ItemType File -Path (
                Join-Path $dayPath 'index.json'
            ) -Value (
                $dayIndex | ConvertTo-Json -Depth 2
            ) -Force
            New-Item -ItemType File -Path (
                Join-Path $dayPath 'index.html.ps1'
            ) -Value "$indexHtmlTemplate" -Force
        }
        New-Item -ItemType File -Path (
            Join-Path $monthPath 'index.json'
        ) -Value (
            $monthIndex | ConvertTo-Json -Depth 2
        ) -Force

        New-Item -ItemType File -Path (
            Join-Path $monthPath 'index.html.ps1'
        ) -Value "$indexHtmlTemplate" -Force
        
        $yearIndex += $monthIndex
    }
    New-Item -ItemType File -Path (
        Join-Path $yearPath 'index.json'
    ) -Value (
        $yearIndex | ConvertTo-Json -Depth 2
    ) -Force
    New-Item -ItemType File -Path (
        Join-Path $yearPath 'index.html.ps1'
    ) -Value "$indexHtmlTemplate" -Force
}

