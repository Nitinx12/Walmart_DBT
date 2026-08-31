<#
.SYNOPSIS
    Master runner for the Walmart medallion pipeline.

.DESCRIPTION
    Runs the fixed eight-stage pipeline in strict order and stops immediately
    when any command fails:
        0. Preflight
        1. MongoDB to Bronze extraction
        2. Bronze SQL tests
        3. Silver dbt build and tests
        4. Silver SQL tests
        5. Gold dbt build and tests
        6. Gold SQL tests
        7. Great Expectations tests

    The script resolves the project root itself, loads .env for all child
    commands, logs stage results, and returns 0 only after every stage passes.

.EXAMPLE
    .\pipeline\run_pipeline.ps1
#>

[CmdletBinding()]
param(
    [switch]$NoClear
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:DbtProjectRoot = Join-Path $script:ProjectRoot "walmart_dbt"
$script:LogDir = Join-Path $script:ProjectRoot "logs"
$script:LogFile = Join-Path $script:LogDir ("pipeline_" + (Get-Date -Format "yyyy-MM-dd") + ".log")
$script:Divider = "-" * 60
$script:StageResults = [ordered]@{}
$script:RequiredPysparkPrefix = "3.5"
$script:TotalStages = 7

function Write-PipelineLog {
    param(
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG")]
        [string]$Level = "INFO",
        [Parameter(Mandatory)]
        [string]$Message
    )

    try {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "{0} | {1,-8} | pipeline | {2}" -f $timestamp, $Level, $Message |
            Out-File -FilePath $script:LogFile -Append -Encoding utf8
    }
    catch {
        Write-Warning "Could not write pipeline log: $($_.Exception.Message)"
    }
}

function Write-StageHeader {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ""
    Write-Host $script:Divider -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host $script:Divider -ForegroundColor DarkGray
    Write-PipelineLog -Message $Title
}

function Write-StagePass {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host " [PASS] $Message" -ForegroundColor Green
    Write-PipelineLog -Message "PASS - $Message"
}

function Write-StageFail {
    param([Parameter(Mandatory)][string]$Message)

    Write-Host " [FAIL] $Message" -ForegroundColor Red
    Write-PipelineLog -Level "ERROR" -Message "FAIL - $Message"
}

function Write-Summary {
    Write-Host ""
    Write-Host $script:Divider -ForegroundColor DarkGray
    Write-Host " PIPELINE SUMMARY" -ForegroundColor Cyan
    Write-Host $script:Divider -ForegroundColor DarkGray

    foreach ($stageName in $script:StageResults.Keys) {
        $status = $script:StageResults[$stageName]
        $color = if ($status -eq "PASS") { "Green" } else { "Red" }
        Write-Host (" {0,-20} {1}" -f $stageName, $status) -ForegroundColor $color
    }

    Write-Host $script:Divider -ForegroundColor DarkGray
}

function Stop-Pipeline {
    param(
        [Parameter(Mandatory)][string]$FailedStage,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $script:StageResults[$FailedStage] = "FAIL"
    $reason = $ErrorRecord.Exception.Message
    Write-PipelineLog -Level "ERROR" -Message "$FailedStage failed: $reason"
    Write-StageFail "$FailedStage failed. Stopping pipeline. See logs/ for detail."
    Write-Summary
    exit 1
}

function Import-DotEnv {
    param([string]$Path = (Join-Path $script:ProjectRoot ".env"))

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warning ".env was not found; using environment variables already set in this shell."
        return
    }

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) {
            continue
        }

        $key, $value = $line -split "=", 2
        [Environment]::SetEnvironmentVariable($key.Trim(), $value.Trim(), "Process")
    }
}

function Assert-Prerequisites {
    $requiredPaths = @(
        "pyproject.toml",
        "scripts/extract.py",
        "scripts/sql_test.py",
        "tests/bronze",
        "tests/silver",
        "tests/gold",
        "walmart_dbt/dbt_project.yml"
    )

    foreach ($relativePath in $requiredPaths) {
        $path = Join-Path $script:ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required pipeline path is missing: $relativePath"
        }
    }

    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        throw "uv is not available on PATH. Install uv, then run 'uv sync'."
    }
}

function Invoke-PipelineCommand {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Command,
        [string]$WorkingDirectory = $script:ProjectRoot
    )

    Write-PipelineLog -Message "${Description}: $($Command -join ' ')"
    Push-Location $WorkingDirectory
    try {
        $executable = $Command[0]
        $arguments = if ($Command.Count -gt 1) { $Command[1..($Command.Count - 1)] } else { @() }
        & $executable @arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        throw "$Description exited with code $exitCode."
    }
}

function Invoke-Preflight {
    $versionOutput = & uv run python -c "import pyspark; print(pyspark.__version__)" 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "PySpark could not be imported. Run 'uv sync' to install the locked project dependencies."
    }

    $installedVersion = ($versionOutput | Select-Object -Last 1).ToString().Trim()
    if ($installedVersion -notlike "$script:RequiredPysparkPrefix*") {
        throw "PySpark $installedVersion is incompatible; this project requires $script:RequiredPysparkPrefix.x. Run 'uv sync' to restore the locked version."
    }

    Write-PipelineLog -Message "Preflight passed: PySpark $installedVersion"
}

function Invoke-PipelineStage {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-StageHeader "STEP $Number / $script:TotalStages  -  $Title"
    try {
        & $Action
    }
    catch {
        Stop-Pipeline -FailedStage $Name -ErrorRecord $_
    }

    $script:StageResults[$Name] = "PASS"
    Write-StagePass "$Name completed"
}

if (-not $NoClear -and -not [Console]::IsOutputRedirected) {
    Clear-Host
}

try {
    Set-Location $script:ProjectRoot
    $env:PYTHONPATH = $script:ProjectRoot
    $env:PYTHONIOENCODING = "utf-8"

    Assert-Prerequisites
    Import-DotEnv
    Write-PipelineLog -Message "Pipeline started from $script:ProjectRoot"

    Invoke-PipelineStage -Number 0 -Name "Preflight" -Title "PREFLIGHT (dependency check)" -Action {
        Invoke-Preflight
    }

    Invoke-PipelineStage -Number 1 -Name "Extract" -Title "EXTRACT (MongoDB to Bronze)" -Action {
        Invoke-PipelineCommand -Description "Extract" -Command @("uv", "run", "python", "scripts/extract.py")
    }

    Invoke-PipelineStage -Number 2 -Name "Bronze Tests" -Title "BRONZE SQL TESTS" -Action {
        Invoke-PipelineCommand -Description "Bronze SQL tests" -Command @("uv", "run", "python", "scripts/sql_test.py", "tests/bronze")
    }

    Invoke-PipelineStage -Number 3 -Name "Silver dbt" -Title "DBT SILVER (build and test)" -Action {
        Invoke-PipelineCommand -Description "dbt silver build" -Command @("uv", "run", "dbt", "run", "--select", "silver") -WorkingDirectory $script:DbtProjectRoot
        Invoke-PipelineCommand -Description "dbt silver tests" -Command @("uv", "run", "dbt", "test", "--select", "silver") -WorkingDirectory $script:DbtProjectRoot
    }

    Invoke-PipelineStage -Number 4 -Name "Silver Tests" -Title "SILVER SQL TESTS" -Action {
        Invoke-PipelineCommand -Description "Silver SQL tests" -Command @("uv", "run", "python", "scripts/sql_test.py", "tests/silver")
    }

    Invoke-PipelineStage -Number 5 -Name "Gold dbt" -Title "DBT GOLD (build and test)" -Action {
        Invoke-PipelineCommand -Description "dbt gold build" -Command @("uv", "run", "dbt", "run", "--select", "gold") -WorkingDirectory $script:DbtProjectRoot
        Invoke-PipelineCommand -Description "dbt gold tests" -Command @("uv", "run", "dbt", "test", "--select", "gold") -WorkingDirectory $script:DbtProjectRoot
    }

    Invoke-PipelineStage -Number 6 -Name "Gold Tests" -Title "GOLD SQL TESTS" -Action {
        Invoke-PipelineCommand -Description "Gold SQL tests" -Command @("uv", "run", "python", "scripts/sql_test.py", "tests/gold")
    }

    Invoke-PipelineStage -Number 7 -Name "Great Expectations" -Title "GREAT EXPECTATIONS TESTS (Bronze, Silver, Gold)" -Action {
        Invoke-PipelineCommand -Description "Great Expectations tests" -Command @("uv", "run", "python", "-m", "pipeline.data_quality.run", "--layer", "all")
    }
}
catch {
    Write-StageFail "Pipeline setup failed. $($_.Exception.Message)"
    Write-PipelineLog -Level "ERROR" -Message "Pipeline setup failed: $($_.Exception.Message)"
    exit 1
}

Write-PipelineLog -Message "Pipeline completed successfully"
Write-Summary
exit 0
