# Bambu Studio Leak Diagnostic
# Samples every 10 seconds: process memory, handles, threads, VRAM, system RAM, page file.
# Run as: powershell -ExecutionPolicy Bypass -File bambu_diag.ps1

$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$OutputFile = Join-Path $ScriptDir "bambu_diag.csv"
$SampleSecs = 10
$ProcessNames = @("bambu-studio", "BambuStudio", "bambu_studio")

# Write CSV header
"Timestamp,WorkingSet_MB,PrivateBytes_MB,HandleCount,ThreadCount,VRAM_TotalUsed_MB,VRAM_Total_MB,GPU_Util_Pct,VRAM_BambuProcess_MB,SysRAM_Used_MB,SysRAM_Total_MB,SysRAM_Used_Pct,PageFile_Used_MB,PageFile_Total_MB" |
    Out-File -FilePath $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "  Bambu Studio Leak Diagnostic" -ForegroundColor Cyan
Write-Host "  Output  : $OutputFile"        -ForegroundColor Cyan
Write-Host "  Interval: ${SampleSecs}s -- press Ctrl+C to stop."
Write-Host ""

# Non-blocking popup via a background job so the sampling loop never stalls
function Show-Popup([string]$Message) {
    $escaped = $Message -replace [char]39, ([char]39 + [char]39)
    Start-Process mshta.exe -ArgumentList "vbscript:MsgBox(""$escaped"",48,""Bambu Studio Warning"")(window.close)"
}

# Per-process VRAM via PDH GPU Process Memory counter (WDDM 2.x, Windows 10+)
function Get-BambuVRAM([int]$ProcId) {
    try {
        $allInstances = (Get-Counter -ListSet "GPU Process Memory" -ErrorAction Stop).PathsWithInstances
        $instances = $allInstances | Where-Object { $_ -match "pid_${ProcId}_" }
        if (-not $instances) { return "" }
        $paths = $instances | Where-Object { $_ -like "*\Dedicated Usage" }
        if (-not $paths) { return "" }
        $samples = (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples
        return [math]::Round(($samples | Measure-Object CookedValue -Sum).Sum / 1MB, 1)
    } catch { return "" }
}

$lastPopup = [datetime]::MinValue   # cooldown: max one popup per 60s

while ($true) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # --- Bambu Studio process metrics ---
    $ws = ""; $priv = ""; $handles = ""; $threads = ""; $bambuPid = $null
    foreach ($name in $ProcessNames) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $ws       = [math]::Round($proc.WorkingSet64        / 1MB, 1)
            $priv     = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
            $handles  = $proc.HandleCount
            $threads  = $proc.Threads.Count
            $bambuPid = $proc.Id
            break
        }
    }

    # --- Total GPU stats via nvidia-smi ---
    $vramUsed = ""; $vramTotal = ""; $gpuUtil = ""
    try {
        $smi = & nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>$null
        if ($smi) {
            $p = ($smi -split ',').Trim()
            if ($p.Count -ge 3) {
                $vramUsed  = $p[0]
                $vramTotal = $p[1]
                $gpuUtil   = $p[2]
            }
        }
    } catch {}

    # --- Per-process VRAM via PDH ---
    $vramBambu = ""
    if ($bambuPid) { $vramBambu = Get-BambuVRAM $bambuPid }

    # --- System RAM (Win32_OperatingSystem reports in KB) ---
    $ramUsed = ""; $ramTotal = ""; $ramPct = ""
    try {
        $os       = Get-CimInstance Win32_OperatingSystem
        $ramTotal = [math]::Round($os.TotalVisibleMemorySize / 1KB)
        $ramFree  = [math]::Round($os.FreePhysicalMemory      / 1KB)
        $ramUsed  = $ramTotal - $ramFree
        $ramPct   = [math]::Round($ramUsed / $ramTotal * 100, 1)
    } catch {}

    # --- Page file (Win32_PageFileUsage reports in MB) ---
    $pfUsed = ""; $pfTotal = ""
    try {
        $pf = @(Get-CimInstance Win32_PageFileUsage)
        if ($pf) {
            $pfUsed  = ($pf | Measure-Object CurrentUsage      -Sum).Sum
            $pfTotal = ($pf | Measure-Object AllocatedBaseSize  -Sum).Sum
        }
    } catch {}

    # --- Write CSV row ---
    "$ts,$ws,$priv,$handles,$threads,$vramUsed,$vramTotal,$gpuUtil,$vramBambu,$ramUsed,$ramTotal,$ramPct,$pfUsed,$pfTotal" |
        Out-File -FilePath $OutputFile -Append -Encoding UTF8

    # --- Console status ---
    if ($bambuPid) {
        $color   = "Green"
        $procStr = "WS:${ws}MB Priv:${priv}MB H:$handles T:$threads VRAMproc:${vramBambu}MB"
    } else {
        $color   = "Yellow"
        $procStr = "[Bambu not detected]"
    }
    Write-Host "$ts | $procStr | VRAM:${vramUsed}/${vramTotal}MB GPU:${gpuUtil}% | RAM:${ramUsed}/${ramTotal}MB (${ramPct}%) | PF:${pfUsed}MB" -ForegroundColor $color

    # Warn when handles are high enough that a restart is advisable
    if ($bambuPid -and $handles -ge 1250 -and ([datetime]::Now - $lastPopup).TotalSeconds -ge 60) {
        Write-Host "  *** HANDLE WARNING: $handles handles -- consider restarting Bambu Studio now ***" -ForegroundColor Red
        Show-Popup "Handle count is $handles (threshold: 1250).`n`nRestart Bambu Studio now to avoid the system freeze."
        $lastPopup = [datetime]::Now
    }

    Start-Sleep -Seconds $SampleSecs
}

