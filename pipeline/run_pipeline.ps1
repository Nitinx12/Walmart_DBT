<#
.SYNOPSIS
    Runs the walmart medallion pipeline end-to-end, one stage at a time:
        0. Preflight        (pyspark <-> mongo-spark-connector version check)
        1. Extract          (scripts/extract.py)
        2. Bronze SQL tests (tests/bronze/*.sql)
        3. dbt silver build + test (walmart_dbt, models/silver)
        4. Silver SQL tests (tests/silver/*.sql)
        5. dbt gold build + test (walmart_dbt, models/gold)
        6. Gold SQL tests (tests/gold/*.sql)

    Stops immediately on the first failed stage.

    Terminal stays clean: only a short header + PASS/FAIL line per stage.
    Full detail (including failing rows, query output, tracebacks) goes to
    the rotating log files under logs/, via utils/logger.py.

.NOTES
    File location: this script lives in a `ps1/` folder directly under the
    project root, e.g.:

        walmart/
        ├─ ps1/
        │  └─ run_pipeline.ps1   <- this file
        ├─ scripts/
        ├─ tests/
        ├─ walmart_dbt/
        └─ .env

    Requires:
      - uv installed and on PATH
      - `sqlalchemy` + `psycopg2-binary` available in the project env
        (uv add sqlalchemy psycopg2-binary)
      - dbt-postgres available in the project env if not already
      - A `.env` file at project root with
        POSTGRES_HOST / POSTGRES_PORT / POSTGRES_DATABASE / POSTGRES_USERNAME / POSTGRES_PASSWORD
      - utils/__init__.py must exist at the project root so that
        `from utils.logger import get_logger` resolves correctly
#>

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
# Clear only an interactive console; redirected runners have no cursor handle.
if (-not [Console]::IsOutputRedirected) {
    Clear-Host
}

# This script lives in a ps1/ subfolder one level below the actual project
# root (where scripts/, tests/, walmart_dbt/, _env, etc. all live).
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

# scripts/*.py are run as `python scripts/xxx.py`, not `python -m`, so Python
# only puts scripts/ on sys.path by default -- utils/ at the project root
# would be unimportable without this. Mirrors ENV PYTHONPATH=/app in the Dockerfile.
$env:PYTHONPATH = $ProjectRoot
# Rich report output includes Unicode symbols; avoid legacy Windows code pages.
$env:PYTHONIOENCODING = "utf-8"

$LogDir = Join-Path $ProjectRoot "logs"
$LogFile = Join-Path $LogDir ("pipeline_" + (Get-Date -Format "yyyy-MM-dd") + ".log")
$Divider = "-" * 60
$StageResults = [ordered]@{}

function Write-PipelineLog {
    param(
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG")]
        [string]$Level = "INFO",
        [string]$Message
    )

    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0} | {1,-8} | pipeline | {2}" -f $timestamp, $Level, $Message
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Write-StageHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host $Divider -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host $Divider -ForegroundColor DarkGray
    Write-PipelineLog -Level "INFO" -Message $Title
}

function Write-StagePass {
    param([string]$Message)
    Write-Host " [PASS] $Message" -ForegroundColor Green
    Write-PipelineLog -Level "INFO" -Message "PASS - $Message"
}

function Write-StageFail {
    param([string]$Message)
    Write-Host " [FAIL] $Message" -ForegroundColor Red
    Write-PipelineLog -Level "ERROR" -Message "FAIL - $Message"
}

function Write-Summary {
    Write-Host ""
    Write-Host $Divider -ForegroundColor DarkGray
    Write-Host " PIPELINE SUMMARY" -ForegroundColor Cyan
    Write-Host $Divider -ForegroundColor DarkGray
    foreach ($key in $StageResults.Keys) {
        $status = $StageResults[$key]
        $color = if ($status -eq "PASS") { "Green" } elseif ($status -eq "FAIL") { "Red" } else { "Yellow" }
        Write-Host (" {0,-20} {1}" -f $key, $status) -ForegroundColor $color
    }
    Write-Host $Divider -ForegroundColor DarkGray
}

function Stop-Pipeline {
    param([string]$FailedStageKey)
    $StageResults[$FailedStageKey] = "FAIL"
    Write-PipelineLog -Level "ERROR" -Message "$FailedStageKey failed - stopping pipeline. See logs/ for detail."
    Write-StageFail "$FailedStageKey failed - stopping pipeline. See logs/ for detail."
    Write-Summary
    exit 1
}

# Load env vars into the current process environment so child python/dbt calls see it
function Import-DotEnv {
    param([string]$Path = ".env")
    if (-not (Test-Path $Path)) {
        Write-Host "WARNING: $Path not found at project root." -ForegroundColor Yellow
        return
    }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $key, $value = $line -split "=", 2
            [System.Environment]::SetEnvironmentVariable($key.Trim(), $value.Trim())
        }
    }
}

Import-DotEnv
Write-PipelineLog -Level "INFO" -Message "Pipeline started from $ProjectRoot"

# The mongo-spark-connector jar in jars/ is pinned to 10.4.0, which only
# supports Spark 3.x. If this pin ever changes (new connector jar), update
# this version to match.
$RequiredPysparkPrefix = "3.5"
$RequiredPysparkVersion = "3.5.5"

# ---------------------------------------------------------------------------
# Stage 0: Preflight - pyspark / mongo-spark-connector version check
# ---------------------------------------------------------------------------
Write-StageHeader "STEP 0 / 6  -  PREFLIGHT (dependency check)"

$installedPyspark = ((uv run python -c "import pyspark; print(pyspark.__version__)" 2>$null) -join "").Trim()

if ([string]::IsNullOrWhiteSpace($installedPyspark)) {
    Write-Host " pyspark not found or failed to import - attempting to install $RequiredPysparkVersion..." -ForegroundColor Yellow
    Write-PipelineLog -Level "WARNING" -Message "pyspark not found or failed to import; attempting install $RequiredPysparkVersion"
    uv add "pyspark==$RequiredPysparkVersion"
    if ($LASTEXITCODE -ne 0) { Stop-Pipeline "Preflight" }
}
elseif ($installedPyspark -notlike "$RequiredPysparkPrefix*") {
    Write-Host " pyspark $installedPyspark detected, but mongo-spark-connector needs $RequiredPysparkPrefix.x" -ForegroundColor Yellow
    Write-Host " Pinning pyspark to $RequiredPysparkVersion ..." -ForegroundColor Yellow
    Write-PipelineLog -Level "WARNING" -Message "pyspark $installedPyspark detected; pinning to $RequiredPysparkVersion"
    uv add "pyspark==$RequiredPysparkVersion"
    if ($LASTEXITCODE -ne 0) { Stop-Pipeline "Preflight" }
}

$StageResults["Preflight"] = "PASS"
Write-PipelineLog -Level "INFO" -Message "Preflight passed: pyspark version OK ($RequiredPysparkPrefix.x)"
Write-StagePass "pyspark version OK ($RequiredPysparkPrefix.x)"

# ---------------------------------------------------------------------------
# Stage 1: Extract
# ---------------------------------------------------------------------------
Write-StageHeader "STEP 1 / 6  -  EXTRACT (scripts/extract.py)"
Write-PipelineLog -Level "INFO" -Message "Running Extract stage"

uv run python scripts/extract.py
if ($LASTEXITCODE -ne 0) { Stop-Pipeline "Extract" }
$StageResults["Extract"] = "PASS"
Write-PipelineLog -Level "INFO" -Message "Extract stage completed successfully"
Write-StagePass "Extract completed"

# ---------------------------------------------------------------------------
# Stage 2: Bronze SQL tests
# ---------------------------------------------------------------------------
Write-StageHeader "STEP 2 / 6  -  BRONZE SQL TESTS (tests/bronze)"
Write-PipelineLog -Level "INFO" -Message "Running Bronze SQL tests"

uv run python scripts/sql_test.py tests/bronze
if ($LASTEXITCODE -ne 0) { Stop-Pipeline "Bronze Tests" }
$StageResults["Bronze Tests"] = "PASS"
Write-PipelineLog -Level "INFO" -Message "Bronze SQL tests passed"
Write-StagePass "Bronze SQL tests passed"

# ---------------------------------------------------------------------------
# Stage 3: dbt silver build + test
# ---------------------------------------------------------------------------
Write-StageHeader "STEP 3 / 6  -  DBT SILVER (walmart_dbt)"
Write-PipelineLog -Level "INFO" -Message "Running dbt Silver build and tests"

Set-Location "$ProjectRoot/walmart_dbt"

uv run dbt run --select silver
$dbtRunExit = $LASTEXITCODE

if ($dbtRunExit -eq 0) {
    uv run dbt test --select silver
    $dbtTestExit = $LASTEXITCODE
} else {
    $dbtTestExit = 1
}

Set-Location $ProjectRoot

if ($dbtRunExit -ne 0 -or $dbtTestExit -ne 0) { Stop-Pipeline "Silver dbt" }
$StageResults["Silver dbt"] = "PASS"
Write-PipelineLog -Level "INFO" -Message "dbt Silver build and tests passed"
Write-StagePass "dbt silver build + tests passed"

# ---------------------------------------------------------------------------
# Stage 4: Silver SQL tests
# ---------------------------------------------------------------------------
Write-StageHeader "STEP 4 / 6  -  SILVER SQL TESTS (tests/silver)"
Write-PipelineLog -Level "INFO" -Message "Running Silver SQL tests"

uv run python scripts/sql_test.py tests/silver
if ($LASTEXITCODE -ne 0) { Stop-Pipeline "Silver Tests" }
$StageResults["Silver Tests"] = "PASS"
Write-PipelineLog -Level "INFO" -Message "Silver SQL tests passed"
Write-StagePass "Silver SQL tests passed"

# ---------------------------------------------------------------------------
# Stage 5: dbt gold build + test
# ---------------------------------------------------------------------------
Write-StageHeader "STEP 5 / 6  -  DBT GOLD (walmart_dbt)"
Write-PipelineLog -Level "INFO" -Message "Running dbt Gold build and tests"

Set-Location "$ProjectRoot/walmart_dbt"

uv run dbt run --select gold
$dbtGoldRunExit = $LASTEXITCODE

if ($dbtGoldRunExit -eq 0) {
    uv run dbt test --select gold
    $dbtGoldTestExit = $LASTEXITCODE
} else {
    $dbtGoldTestExit = 1
}

Set-Location $ProjectRoot

if ($dbtGoldRunExit -ne 0 -or $dbtGoldTestExit -ne 0) { Stop-Pipeline "Gold dbt" }
$StageResults["Gold dbt"] = "PASS"
Write-PipelineLog -Level "INFO" -Message "dbt Gold build and tests passed"
Write-StagePass "dbt gold build + tests passed"

# ---------------------------------------------------------------------------
# Stage 6: Gold SQL tests
# ---------------------------------------------------------------------------
Write-StageHeader "STEP 6 / 6  -  GOLD SQL TESTS (tests/gold)"
Write-PipelineLog -Level "INFO" -Message "Running Gold SQL tests"

uv run python scripts/sql_test.py tests/gold
if ($LASTEXITCODE -ne 0) { Stop-Pipeline "Gold Tests" }
$StageResults["Gold Tests"] = "PASS"
Write-PipelineLog -Level "INFO" -Message "Gold SQL tests passed"
Write-StagePass "Gold SQL tests passed"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-PipelineLog -Level "INFO" -Message "Pipeline completed successfully"
Write-Summary
