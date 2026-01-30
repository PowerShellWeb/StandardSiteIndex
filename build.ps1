<#
.SYNOPSIS
    Builds the website.
.DESCRIPTION
    Builds a static site using PowerShell.
.EXAMPLE
    ./build.ps1
#>param(
[string[]]$FilePath,

[string]$Root = $PSScriptRoot,

[ValidateScript({
    $isValid = $_ -is [Management.Automation.CommandInfo] -or 
               $_ -is [ScriptBlock]
    if ($isValid) { return $true }
    throw "Must be a Command or ScriptBlock"
})]
[PSObject]
$Layout = $(
    if (Test-Path (Join-Path $PSScriptRoot 'layout.ps1')) {
        Get-Command (Join-Path $PSScriptRoot 'layout.ps1')
    } else {
        {"<html><head></head><body>"                        
        @($input; $args) -join [Environment]::NewLine
        "</body></html>"}
    }
),

[string[]]
$excludeTerms = @("Color-Schemes", ".tests.ps1", ".turtle.ps1", ".websocket.ps1")
)

#region Common Filters
filter Require {
    # What do we require?    
    $require = $_
    # If it is a script
    if ($require -is [Management.Automation.ExternalScriptInfo]) {
        # get its required modules
        $require.ScriptBlock.Ast.ScriptRequirements.RequiredModules.Name |
            . $MyInvocation.MyCommand # and pipe to ourself and return
        return
    }    
    if ($require -isnot [string]) { return }
    $importSplat = @{PassThru=$true;ErrorAction='Ignore';Global=$true}
    $isInstalled = Import-Module -Name $require @importSplat
    # If they're not installed
    if (-not $isInstalled) {
        # install them.
        Write-Host -ForegroundColor Cyan "Installing $require"
        Install-Module -AllowClobber -Force -Name $require -Scope CurrentUser        
        $isInstalled = Import-Module -Name $require @importSplat
    }
}
filter GetScriptParameters {
    $in = $_
    if ($in -is [ScriptBlock]) {
        $function:tempFunction = $in
        $invokeCommand = $ExecutionContext.SessionState.InvokeCommand
        $in = $invokeCommand.GetCommand('tempFunction', 'Function')
    }
    if ($in -isnot [Management.Automation.CommandInfo]) { return }
    if (-not $args) { return $in.Parameters }
    $splat = [Ordered]@{}
    :nextParameter foreach ($parameterName in $in.Parameters.Keys) {
        $parameter = $in.Parameters[$parameterName]
        $potentialType = $parameter.ParameterType
        # PowerShell parameters can have aliases, so find all potential names.
        $parameterNames = @($parameter.Name;$parameter.Aliases) -ne ''
        foreach ($PotentialName in $parameterNames) {
            foreach ($arg in $args) {
                if ($arg -isnot [Collections.IDictionary]) { continue }
                if ($arg[$potentialName] -and 
                    $arg[$potentialName] -as $potentialType) {
                    if ($potentialType -eq [Collections.IDictionary]) {
                        if (-not $splat[$parameterName]) {
                            $splat[$parameterName] = [Ordered]@{}
                        }
                        foreach ($key in $arg[$potentialName].Keys) {
                            $splat[$parameterName][$key] =
                                $arg[$potentialName][$key]
                        }
                    } else {
                        $splat[$parameterName] = $arg[$potentialName]
                    }
                }
            }
        }
    }
    return $splat
}
filter GetScriptMetadata {
    $in = $_    
    $meta = [Ordered]@{}        
    $help = 
        if ($in.Source -and $in.ScriptContents -match '\.synopsis') {
            Get-Help $in.Source
        }
        elseif ($in -is [Management.Automation.FunctionInfo]) {
            Get-Help $in.Name
        }
    if ($help -isnot [string]) {
        $meta.title = $help.synopsis
        $meta.description = $help.description.text -join [Environment]::NewLine
        $meta.notes = $help.alertset.alert.text -join [Environment]::NewLine
        $meta.help = $help
        $meta.examples = @(
            foreach ($example in $scriptHelp.examples.example) {
                @(
                    $example.Code
                    @($example.Remarks.text) -ne ''
                ) -join ([Environment]::NewLine)
            }
        )
    }

    foreach ($attribute in $in.ScriptBlock.Attributes) {
        if ($attribute -is [Reflection.AssemblyMetaDataAttribute]) {
            $meta[$attribute.Key] = $attribute.Value
        }
    }
 
    return $meta
}

$mdPipelineBuilder = [Markdig.MarkdownPipelineBuilder]::new()
$mdPipeline = [Markdig.MarkdownExtensions]::UsePipeTables($mdPipelineBuilder).Build()

filter GetMarkdownHTML {
    $in = $_
    if ($in -is [IO.FileInfo]) {
        $in = Get-Content -Raw -LiteralPath $in.FullName
    }
    $metadata = [Ordered]@{}
    if ($in -match '^---') {
        $null, $yamlheader, $markdown = $in -split '---', 3
        if ($yamlheader) {
            require YaYaml
            $metadata += ConvertFrom-Yaml $yamlheader -ErrorAction Ignore
        }
    } else {
        $markdown = $in
    }

    [Markdig.Markdown]::ToHtml("$markdown", $mdPipeline) -replace 
        'disabled="disabled"' |
            Add-Member NoteProperty Metadata $metadata -Force -PassThru
}


#endregion Common Filters
# Push into the script root directory
if ($PSScriptRoot) { Push-Location $PSScriptRoot }
#region Prepare Build

# `$site` holds sitewide information
$Site = [Ordered]@{}    

if ($FilePath) {$Site.Path = $FilePath }        
elseif ($root){ $Site.Path = $root}

$Site.PSScriptRoot = $Site.Root = if ($Root) { $Root } else { $PSScriptRoot }
$Site.Layout = $Layout

#region Configuration
$excludePattern = @(    
    @(
        foreach ($exclude in $excludeTerms) { [regex]::Escape($exclude) }
        '[\\/]_[^\\/]+[\\/]' # always exclude _ directories
    ) -join '|'    
)

$configPs1Path = Join-Path $site.PSScriptRoot config.ps1
if (Test-Path $configPs1Path) { 
    $configPs1 = Get-command $configPs1Path -CommandType ExternalScript
    if ($configPs1.ScriptBlock.Ast.ScriptRequirements) {
        $configPs1.ScriptBlock.Ast.ScriptRequirements.RequiredModules | Require
    }
    . $configPs1Path
}

$Site.Files = Get-ChildItem -Recurse -File -Path $site.Path

#endregion Configuration

#region Build
$buildStart = [DateTime]::Now
Write-Host "Started Building Pages @ $buildStart" -ForegroundColor Cyan
$defaultLayoutParameters = # Get the default layout parameters for the site.
    $layoutParameters = $Layout | GetScriptParameters $site
$fileQueue = [Collections.Queue]::new()
foreach ($included in @($site.Files) -notmatch $excludePattern) {
    $fileQueue.Enqueue($included)
}
$invokeCommand = $ExecutionContext.SessionState.InvokeCommand
$site.BuildProgress = $buildProgress = [Ordered]@{
    Status = 'Building'
    Id = Get-Random
}
$originalTotal = $fileQueue.Count
$buildFileCounter = 0
while ($fileQueue.Count) {
    $buildFile = $fileQueue.Dequeue()
    $output = $null # nullify output (just in case)
    $buildProgress.Activity = "$($buildFile.Directory.Name)/$($buildFile.Name) "
    $buildProgress.PercentComplete = [Math]::Min(100, (
        ++$buildFileCounter * 100 / $originalTotal))
    :nextFile switch -regex ($buildFile) {
        '^' { <# Start of each file name, should always match #> } 
        {
            $_ -match '\.[^\.\\/]+\.ps1$' -or 
            (
                $_.Extension -eq '.ps1' -and (
                    $_.Name -replace '\.ps1$' -eq $_.Directory.Name
                )
            )
        } { # *.*.ps1 files get run
            # after we push into the location and map parameters. 
            Push-Location $buildFile.Directory.FullName
            $scriptFile =
                $invokeCommand.Getcommand($buildFile.FullName, 'ExternalScript')
            $page = $scriptFile | GetScriptMetadata
            $parameters = $scriptFile | GetScriptParameters $site $page
            $layoutParameters = $layout | GetScriptParameters $site $page
            Write-Progress @buildProgress
            # Make sure to `dot` the script, so we run in the current context.
            $output = . $buildFile.FullName @parameters
            # If there is no output, pop out and continue
            if (-not $output) {
                Pop-Location; continue nextFile
            }
            
            $outputPath = 
            if ($buildFile.Name -replace '(?:\.html)?\.ps1$' -eq 
                $buildFile.Directory.Name) {
                $buildFile.FullName -replace "$([Regex]::Escape($buildFile.Name))$",
                    'index.html'
            } else {
                $buildFile.FullName -replace '\.ps1$'
            }                         
            
            # If the output is html, and we are not
            if ($outputPath -match '\.html?$' -and 
                -not ($output -match '<html')
            ) {
                $output = $output | # layout the output
                    . $Layout @layoutParameters
            }

            # If the output is markdown
            if ($outputPath -match '\.(markdown|md)$') {
                $output > $outputPath # save it and
                $html = $output -join [Environment]::NewLine |
                    GetMarkdownHTML # get the html,
                if ($html.Metadata.Count) {
                    $layoutParameters = $layout | # and layout the markdown
                        GetScriptParameters $site $page $html.Metadata
                }
                $output = $html | . $Layout @layoutParameters
                $outputPath = $outputPath -replace '\.(markdown|md)$', '.html'
            }
            # Write the output and emit the file
            if ($output -and $outputPath -ne $buildFile.FullName) {
                $output > $outputPath ; Get-Item $outputPath
            }            
            Pop-Location # pop back to where we were
        }
        '\.(md|markdown)$' {
            $html = $buildFile | GetMarkdownHTML # Make our markdown HTML
            $page = $html.Metadata # and get any page metadata.       
            $layoutParameters = $layout | # Get the layout parameters 
                GetScriptParameters $site $page # from the site and page.
            Write-Progress @buildProgress
            $output = $html | . $Layout @layoutParameters
            $outputPath = ($buildFile.FullName -replace '\.(md|markdown)$', '.html')
            if ($output -and $outputPath -ne $buildFile.FullName) {
                $output > $outputPath; Get-Item $outputPath
            }
        }
    }

    $layoutParameters = $defaultLayoutParameters
}

$buildEnd = [DateTime]::Now
$buildProgress.Status = "Finished Building @ $buildEnd"
$buildProgress.Activity = "in $($buildEnd - $buildStart)"
$buildProgress.Remove('PercentComplete')
Write-Progress @buildProgress -Completed
Write-Host "$($buildProgress.Status) $($buildProgress.Activity)" -ForegroundColor Cyan
#endregion Build
if ($PSScriptRoot) { Pop-Location } # Pop back out.
