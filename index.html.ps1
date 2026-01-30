$indexOfPosts = Get-ChildItem -Path $PSScriptRoot -Filter index.json |
    Get-Content -Raw | 
    ConvertFrom-Json 

$digitSubdirectories = Get-ChildItem -Path $PSScriptRoot -Directory |
        Where-Object Name -match '\d+'    

$title = "Standard Site Index"
if ($page -is [Collections.IDictionary]) {
    $page.title = $title    
}

$style = @"
h1, h2, h3 { text-align: center }
"@

"<style>
$style
</style>"

$digitsInPath = @($PSScriptRoot -split '[\\/]' -match '^\d+$' -as [int[]])
if (-not $digitsInPath -or -not $indexOfPosts) {
    "<ul>"
    foreach ($digitSubdirectory in $digitSubdirectories) {
        "<li><a href='$($digitSubdirectory.Name)'>$($digitSubdirectory.Name)</a></li>"
    }
    "</ul>"
    return
}

$year, $month, $day = $digitsInPath


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

$description = "Standard Site Index for $time"



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
