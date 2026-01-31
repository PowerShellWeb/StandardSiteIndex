<#
.SYNOPSIS
    index.html.ps1
.DESCRIPTION
    index.html.ps1 generates index.html
#>
param()

#region Initialization

# First, let's get our local index of posts, if one exists.
$indexFile = Get-ChildItem -Path $PSScriptRoot -Filter index.json 
$indexOfPosts = $indexFile |
    Get-Content -Raw | 
    ConvertFrom-Json 

# Next find any subdirectories whose names are entirely digits
# (this lets us treat root, years, months, and days the same)
$digitSubdirectories = Get-ChildItem -Path $PSScriptRoot -Directory |
    Where-Object Name -match '^\d+$'    

# Make sure year/month/day are null
$year, $month, $day = $null, $null, $null
# Then figure out how many digits are in the current path
$digitsInPath = @($PSScriptRoot -split '[\\/]' -match '^\d+$' -as [int[]])
# Assign year/month/day 
$year, $month, $day = $digitsInPath

# Make the title include the year/month/day
$title = @(
    "Standard Site Index"
    if ($year) {
        "($($year, $month, $day -ne $null -join '-'))"
    }
) -join ' '

if ($page -is [Collections.IDictionary]) {
    $page.title = $title    
}

#endregion Initialization

#region Content

# Declare any styles
$style = @"
h1, h2, h3 { text-align: center }
"@

# and emit a style tag.
"<style>
$style
</style>"


# If there were digit subdirectories, put them in a bullet point list.
if ($digitSubdirectories) {
    "<ul>"
    foreach ($digitSubdirectory in $digitSubdirectories) {
        "<li><a href='$($digitSubdirectory.Name)'>$($digitSubdirectory.Name)</a></li>"
    }
    "</ul>"
}

$time = ''
if ($year -and $month -and $day) {
    $time = "{0:d4}-{1:d2}-{2:d2}" -f $year, $month, $day
    "<h3><time datetime='$time'>$time</time></h3>"
} elseif ($year -and $month) {    
    $time = "{0:d4}-{1:d2}" -f $year, $month
    "<h3><time datetime='$time'>$time</time></h3>"
} elseif ($year) {
    $time = "{0:d4}" -f $year
    "<h3><time datetime='$time'>$time</time></h3>"
}

if ($time) {
    $description = "Standard Site Index for $Time"
} else {
    $description = "Standard Site Index"
}

if ($page -is [Collections.IDictionary]) {
    $page.description = $description
}


if (-not $digitsInPath -or -not $indexOfPosts) {    
    return
}

$postsByDomain = $indexOfPosts | Group-Object { ($_.url -as [uri]).DnsSafeHost }

foreach ($domain in $postsByDomain) {
    "<details open>"
    "<summary>$([Web.HttpUtility]::HtmlEncode($domain.Name))</summary>"
    "<ul>"    
    foreach ($post in $domain.Group) {
        "<li><a href='$($post.url)'>$([Web.HttpUtility]::HtmlEncode($post.title))</a></li>"
    }
    "</ul>"
    "</details>"
}
