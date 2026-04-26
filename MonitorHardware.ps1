# ============================================================
# Monitor de Hardware em Tempo Real 
# ============================================================

#Requires -Version 7.0

# ── Auto-elevação para Administrador ────────────────────────
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Reiniciando como Administrador..." -ForegroundColor Yellow
    $elevArgs = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    Start-Process pwsh -ArgumentList $elevArgs -Verb RunAs
    exit
}

# ── Configuração global ──────────────────────────────────────
$script:Config = @{
    RefreshSeconds = 2
    BarWidth       = 22
    CharFilled     = [char]0x2588   # █
    CharEmpty      = [char]0x2591   # ░
    WarnThreshold  = 75
    CritThreshold  = 90
    LhmPort        = 8085           # Porta do LibreHardwareMonitor
    CsvPath        = "$env:USERPROFILE\XMRig-Miner-Analysis\RelatoriosHardware\RelatorioHardware_$(Get-Date -Format 'dd-MM-yyyy').csv"
}

# ── Funções auxiliares ───────────────────────────────────────

function Show-Bar {
    param(
        [double]$Percent,
        [int]$Width         = $script:Config.BarWidth,
        [string]$CharFilled = $script:Config.CharFilled,
        [string]$CharEmpty  = $script:Config.CharEmpty
    )
    $Percent = [math]::Clamp($Percent, 0, 100)
    $filled  = [math]::Round($Percent / 100 * $Width)
    $empty   = $Width - $filled
    return ($CharFilled * $filled) + ($CharEmpty * $empty)
}

function Get-ThresholdColor {
    param([double]$Percent)
    if ($Percent -ge $script:Config.CritThreshold) { return 'Red' }
    if ($Percent -ge $script:Config.WarnThreshold)  { return 'DarkYellow' }
    return 'Green'
}

function Write-Section {
    param([string]$Label)
    Write-Host $Label -ForegroundColor White
}

function Write-MetricLine {
    param(
        [string]$Label,
        [double]$Percent,
        [string]$Detail
    )
    $bar   = Show-Bar $Percent
    $color = Get-ThresholdColor $Percent
    $line  = "{0,-9}: [{1}] {2,5}%  {3}" -f $Label, $bar, $Percent, $Detail
    Write-Host $line -ForegroundColor $color
}

# ── Funções de coleta de dados ───────────────────────────────

function Get-CpuUsage {
    $cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
    return [math]::Round($cpu.Average, 1)
}

function Get-CpuName {
    return (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name).Trim()
}

function Get-MemoryInfo {
    $os    = Get-CimInstance Win32_OperatingSystem
    $total = [math]::Round($os.TotalVisibleMemorySize * 1KB / 1GB, 2)
    $free  = [math]::Round($os.FreePhysicalMemory     * 1KB / 1GB, 2)
    $used  = [math]::Round($total - $free, 2)
    return [PSCustomObject]@{
        TotalGB     = $total
        UsedGB      = $used
        FreeGB      = $free
        PercentUsed = [math]::Round(($used / $total) * 100, 1)
    }
}

function Get-DiskInfo {
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Where-Object Size -gt 0 |
        ForEach-Object {
            $total = [math]::Round($_.Size      / 1GB, 2)
            $free  = [math]::Round($_.FreeSpace / 1GB, 2)
            $used  = [math]::Round($total - $free, 2)
            [PSCustomObject]@{
                Drive       = $_.DeviceID
                Label       = if ($_.VolumeName) { $_.VolumeName } else { '—' }
                TotalGB     = $total
                UsedGB      = $used
                FreeGB      = $free
                PercentUsed = [math]::Round(($used / $total) * 100, 1)
            }
        }
}

function Get-NetworkRate {
    param([int]$SampleSeconds = 1)

    $before = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface |
              Group-Object Name -AsHashTable -AsString

    Start-Sleep -Seconds $SampleSeconds

    $after = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface

    foreach ($a in $after) {
        $b = $before[$a.Name]
        if (-not $b) { continue }

        $recvDelta = [math]::Max($a.BytesReceivedPersec - $b.BytesReceivedPersec, 0)
        $sentDelta = [math]::Max($a.BytesSentPersec     - $b.BytesSentPersec,     0)

        $iface = ($a.Name -replace '[()#/\\]', ' ').Trim()
        if (-not $iface) { continue }

        [PSCustomObject]@{
            Interface = $iface
            TotalMbps = [math]::Round(($recvDelta + $sentDelta) * 8 / 1MB / $SampleSeconds, 2)
            RecvMbps  = [math]::Round($recvDelta * 8 / 1MB / $SampleSeconds, 2)
            SentMbps  = [math]::Round($sentDelta * 8 / 1MB / $SampleSeconds, 2)
        }
    }
}

function Get-SystemInfo {
    $os     = Get-CimInstance Win32_OperatingSystem
    $uptime = (Get-Date) - $os.LastBootUpTime
    [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        OS           = "$($os.Caption) $($os.OSArchitecture)"
        Uptime       = "{0}d {1:D2}h {2:D2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
        LastBoot     = $os.LastBootUpTime.ToString('dd/MM/yyyy HH:mm')
    }
}

function Get-CpuTemperature {
    try {
        $port = $script:Config.LhmPort
        $response = Invoke-RestMethod -Uri "http://localhost:$port/data.json" -TimeoutSec 1 -ErrorAction Stop

        $temps = [System.Collections.Generic.List[double]]::new()

        function Search-Nodes {
            param($node)
            if ($node.PSObject.Properties['Type'] -and $node.Type -eq 'Temperature' -and
                $node.PSObject.Properties['SensorId'] -and
                ($node.SensorId -like '/intelcpu/*' -or $node.SensorId -like '/cpu/*') -and
                $node.PSObject.Properties['RawValue'] -and $node.RawValue -ne '') {
                $val = $node.RawValue -replace '[^\d,\.]', '' -replace ',', '.'
                $parsed = 0.0
                if ([double]::TryParse($val, [System.Globalization.NumberStyles]::Any,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {
                    $temps.Add($parsed)
                }
            }
            if ($node.PSObject.Properties['Children']) {
                foreach ($child in $node.Children) {
                    Search-Nodes $child
                }
            }
        }

        foreach ($child in $response.Children) {
            Search-Nodes $child
        }

        if ($temps.Count -gt 0) {
            $avg = ($temps | Measure-Object -Average).Average
            return [math]::Round($avg, 1)
        }
    } catch { }

    $namespaces = @('root/LibreHardwareMonitor', 'root/OpenHardwareMonitor')
    foreach ($ns in $namespaces) {
        try {
            $t = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop |
                 Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -like '*CPU*' }
            if ($t) {
                return [math]::Round(($t | Measure-Object -Property Value -Average).Average, 1)
            }
        } catch { continue }
    }

    return $null
}

function Get-PowerConsumption {
    try {
        $port = $script:Config.LhmPort
        $response = Invoke-RestMethod -Uri "http://localhost:$port/data.json" -TimeoutSec 1 -ErrorAction Stop

        $powers = @{
            CPU   = $null
            GPU   = $null
            RAM   = $null
            Total = 0.0
        }

        function Search-PowerNodes {
            param($node)

            if ($node.PSObject.Properties['Type'] -and $node.Type -eq 'Power' -and
                $node.PSObject.Properties['SensorId'] -and
                $node.PSObject.Properties['RawValue'] -and $node.RawValue -ne '') {

                $val = $node.RawValue -replace '[^\d,\.]', '' -replace ',', '.'
                $parsed = 0.0
                if ([double]::TryParse($val, [System.Globalization.NumberStyles]::Any,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {

                    $sensorId = $node.SensorId.ToLower()

                    if ($sensorId -match '/cpu/|/intelcpu/|/amdcpu/') {
                        $powers.CPU = ($powers.CPU, $parsed | Measure-Object -Sum).Sum
                    } elseif ($sensorId -match '/gpu/|/nvidia/|/amdgpu/|/intelgpu/') {
                        $powers.GPU = ($powers.GPU, $parsed | Measure-Object -Sum).Sum
                    } elseif ($sensorId -match '/ram/|/dram/') {
                        $powers.RAM = ($powers.RAM, $parsed | Measure-Object -Sum).Sum
                    }
                    $powers.Total += $parsed
                }
            }

            if ($node.PSObject.Properties['Children']) {
                foreach ($child in $node.Children) {
                    Search-PowerNodes $child
                }
            }
        }

        foreach ($child in $response.Children) {
            Search-PowerNodes $child
        }

        $powers.CPU   = if ($powers.CPU)   { [math]::Round($powers.CPU, 1) } else { $null }
        $powers.GPU   = if ($powers.GPU)   { [math]::Round($powers.GPU, 1) } else { $null }
        $powers.RAM   = if ($powers.RAM)   { [math]::Round($powers.RAM, 1) } else { $null }
        $powers.Total = [math]::Round($powers.Total, 1)

        return $powers
    } catch {
        return $null
    }
}

function Get-GpuInfo {
    try {
        $port = $script:Config.LhmPort
        $response = Invoke-RestMethod -Uri "http://localhost:$port/data.json" -TimeoutSec 2 -ErrorAction Stop

        $gpuData = @{
            Name            = $null
            CoreLoad        = $null
            CoreTemp        = $null
            MemUsed         = $null
            MemTotal        = $null
            MemLoad         = $null
            CoreClock       = $null
            MemClock        = $null
            Power           = $null
            FanSpeed        = $null
        }

        function Search-GpuNodes {
            param($node, $depth = 0)

            $isGpuHardware = $false
            if ($node.PSObject.Properties['Text']) {
                $text = $node.Text
                if ($text -match 'NVIDIA|GeForce|GTX|RTX|Quadro|Titan|AMD|Radeon|RX|Intel.*Graphics|Intel.*UHD|Intel.*Iris|Intel.*Arc') {
                    $isGpuHardware = $true
                    if (-not $gpuData.Name) {
                        $gpuData.Name = $text.Trim()
                    }
                }
            }

            if ($isGpuHardware -and $node.PSObject.Properties['Children']) {
                foreach ($child in $node.Children) {
                    if ($child.PSObject.Properties['Text'] -and $child.PSObject.Properties['Children']) {
                        $groupName = $child.Text
                        foreach ($sensor in $child.Children) {
                            Invoke-SensorData $sensor $groupName
                        }
                    }
                }
            }

            if ($node.PSObject.Properties['Children']) {
                foreach ($child in $node.Children) {
                    Search-GpuNodes $child ($depth + 1)
                }
            }
        }

        function Invoke-SensorData {
            param($sensor, $groupName)
            
            if (-not $sensor.PSObject.Properties['Text'] -or -not $sensor.PSObject.Properties['Value']) {
                return
            }

            $sensorName = $sensor.Text
            $rawValue = $sensor.Value
            
            $valueStr = $rawValue -replace '[^\d,\.-]', '' -replace ',', '.'
            $value = 0.0
            if (-not [double]::TryParse($valueStr, [System.Globalization.NumberStyles]::Any,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                return
            }

            if ($groupName -match 'Temperature' -or $sensorName -match 'Temperature|Temp') {
                if ($sensorName -match 'GPU Core|GPU Temperature|^Core$|GPU Hotspot') {
                    if ($null -eq $gpuData.CoreTemp) { $gpuData.CoreTemp = $value }
                }
            }

            if ($groupName -match 'Load' -or $sensorName -match 'Load|Usage') {
                if ($sensorName -match 'GPU Core|^Core$|D3D 3D|GPU Usage') {
                    if ($null -eq $gpuData.CoreLoad) { $gpuData.CoreLoad = $value }
                }
                if ($sensorName -match 'GPU Memory Controller|Memory Controller|GPU Memory|Memory Usage') {
                    if ($null -eq $gpuData.MemLoad) { $gpuData.MemLoad = $value }
                }
            }

            if ($groupName -match 'Clock' -or $sensorName -match 'Clock') {
                if ($sensorName -match 'GPU Core|^Core$|GPU Clock') {
                    if ($null -eq $gpuData.CoreClock) { $gpuData.CoreClock = $value }
                }
                if ($sensorName -match 'GPU Memory|^Memory$|Memory Clock') {
                    if ($null -eq $gpuData.MemClock) { $gpuData.MemClock = $value }
                }
            }

            if ($groupName -match 'Power' -or $sensorName -match 'Power|Watt') {
                if ($sensorName -match 'GPU|Power|Package') {
                    if ($null -eq $gpuData.Power) { $gpuData.Power = $value }
                }
            }

            if ($groupName -match 'Fan|Control' -or $sensorName -match 'Fan') {
                if ($sensorName -match 'Fan' -and $value -le 100) {
                    if ($null -eq $gpuData.FanSpeed) { $gpuData.FanSpeed = $value }
                }
            }

            if ($groupName -match 'Data|Memory|SmallData' -or $sensorName -match 'Memory') {
                if ($sensorName -match 'GPU Memory Used|D3D Dedicated Memory Used|Memory Used|Used Dedicated') {
                    if ($null -eq $gpuData.MemUsed) { $gpuData.MemUsed = $value }
                }
                if ($sensorName -match 'GPU Memory Total|Memory Total|Total') {
                    if ($null -eq $gpuData.MemTotal) { $gpuData.MemTotal = $value }
                }
            }
        }

        foreach ($child in $response.Children) {
            Search-GpuNodes $child
        }

        if (-not $gpuData.Name) {
            return $null
        }

        if ($gpuData.MemUsed -and $gpuData.MemTotal -and $gpuData.MemTotal -gt 0) {
            $gpuData.MemLoad = [math]::Round(($gpuData.MemUsed / $gpuData.MemTotal) * 100, 1)
        }

        $gpuData.CoreLoad = if ($gpuData.CoreLoad) { [math]::Round($gpuData.CoreLoad, 1) } else { $null }
        $gpuData.CoreTemp = if ($gpuData.CoreTemp) { [math]::Round($gpuData.CoreTemp, 1) } else { $null }
        $gpuData.MemUsed  = if ($gpuData.MemUsed)  { [math]::Round($gpuData.MemUsed / 1024, 1) } else { $null }
        $gpuData.MemTotal = if ($gpuData.MemTotal) { [math]::Round($gpuData.MemTotal / 1024, 1) } else { $null }
        $gpuData.MemLoad  = if ($gpuData.MemLoad)  { [math]::Round($gpuData.MemLoad, 1) } else { $null }
        $gpuData.CoreClock= if ($gpuData.CoreClock){ [math]::Round($gpuData.CoreClock, 0) } else { $null }
        $gpuData.MemClock = if ($gpuData.MemClock) { [math]::Round($gpuData.MemClock, 0) } else { $null }
        $gpuData.Power    = if ($gpuData.Power)    { [math]::Round($gpuData.Power, 1) } else { $null }
        $gpuData.FanSpeed = if ($gpuData.FanSpeed) { [math]::Round($gpuData.FanSpeed, 0) } else { $null }

        return $gpuData
    }
    catch {
        return $null
    }
}

function Get-TopProcesses {
    param([int]$Top = 5)
    Get-Process |
        Sort-Object CPU -Descending |
        Select-Object -First $Top -Property Name,
            @{N='CPU_s'; E={ [math]::Round($_.CPU, 1) }},
            @{N='MemMB'; E={ [math]::Round($_.WorkingSet64 / 1MB, 1) }}
}

function Get-ProcessStats {
    $procs = Get-Process
    [PSCustomObject]@{
        ProcessCount = $procs.Count
        ThreadCount  = ($procs | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
    }
}

function Format-Uptime {
    param([long]$Seconds)
    
    try {
        if ($Seconds -lt 0) { $Seconds = 0 }
        
        $days    = [long][math]::Floor($Seconds / 86400)
        $hours   = [long][math]::Floor(($Seconds % 86400) / 3600)
        $minutes = [long][math]::Floor(($Seconds % 3600) / 60)
        $secs    = [long]($Seconds % 60)
        
        if ($days -gt 0) {
            return "{0}d {1:D2}h {2:D2}m {3:D2}s" -f $days, $hours, $minutes, $secs
        } elseif ($hours -gt 0) {
            return "{0}h {1:D2}m {2:D2}s" -f $hours, $minutes, $secs
        } else {
            return "{0}m {1:D2}s" -f $minutes, $secs
        }
    }
    catch {
        return "0m 00s"
    }
}

# ── Histórico de sessão ──────────────────────────────────────
$script:Session = @{
    StartTime    = Get-Date
    ReadingCount = [long]0  # ✅ CORRIGIDO: Usar [long] para evitar overflow
}

# ── Exportação de dados para CSV ─────────────────────────────

function Write-HardwareStatsToCsv {
    param(
        $Cpu,
        $CpuTemp,
        $Mem,
        $Disks,
        $Net,
        $Gpu,
        $Power,
        $ProcStats
    )

    try {
        # ── Recalcular CsvPath dinamicamente para suportar viradas de meia-noite ──
        $currentCsvPath = "$env:USERPROFILE\XMRig-Miner-Analysis\RelatoriosHardware\RelatorioHardware_$(Get-Date -Format 'dd-MM-yyyy').csv"

        $directory = Split-Path -Path $currentCsvPath -Parent
        if (-not (Test-Path $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }

        # Montar linha de discos como colunas dinâmicas (até 4 discos)
        $diskCols = [ordered]@{}
        $i = 1
        foreach ($d in $Disks) {
            $diskCols["Disk${i}_Drive"]      = $d.Drive
            $diskCols["Disk${i}_UsedGB"]     = $d.UsedGB
            $diskCols["Disk${i}_TotalGB"]    = $d.TotalGB
            $diskCols["Disk${i}_PctUsed"]    = $d.PercentUsed
            if ($i -ge 4) { break }
            $i++
        }

        # Rede: somar todos os adaptadores ativos
        $totalRecvMbps = ($Net | Measure-Object -Property RecvMbps -Sum).Sum
        $totalSentMbps = ($Net | Measure-Object -Property SentMbps -Sum).Sum

        $stat = [ordered]@{
            Timestamp          = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            # CPU
            CPU_Pct            = $Cpu
            CPU_Temp_C         = $CpuTemp

            # Memória
            RAM_UsedGB         = $Mem.UsedGB
            RAM_TotalGB        = $Mem.TotalGB
            RAM_Pct            = $Mem.PercentUsed

            # GPU (pode ser $null quando LHM não disponível)
            GPU_Load_Pct       = $Gpu.CoreLoad
            GPU_Temp_C         = $Gpu.CoreTemp
            GPU_MemUsed_GB     = $Gpu.MemUsed
            GPU_MemTotal_GB    = $Gpu.MemTotal
            GPU_MemLoad_Pct    = $Gpu.MemLoad
            GPU_CoreClock_MHz  = $Gpu.CoreClock
            GPU_MemClock_MHz   = $Gpu.MemClock
            GPU_Power_W        = $Gpu.Power
            GPU_Fan_Pct        = $Gpu.FanSpeed

            # Energia
            Power_CPU_W        = $Power.CPU
            Power_GPU_W        = $Power.GPU
            Power_RAM_W        = $Power.RAM
            Power_Total_W      = $Power.Total

            # Rede (soma de adaptadores)
            Net_Recv_Mbps      = [math]::Round($totalRecvMbps, 2)
            Net_Sent_Mbps      = [math]::Round($totalSentMbps, 2)

            # Processos
            Process_Count      = $ProcStats.ProcessCount
            Thread_Count       = $ProcStats.ThreadCount
        }

        # Adicionar colunas de disco dinamicamente
        foreach ($key in $diskCols.Keys) {
            $stat[$key] = $diskCols[$key]
        }

        $row = [PSCustomObject]$stat

        if (-not (Test-Path $currentCsvPath)) {
            $row | Export-Csv -Path $currentCsvPath -NoTypeInformation -Encoding UTF8
        } else {
            $row | Export-Csv -Path $currentCsvPath -Append -NoTypeInformation -Encoding UTF8
        }

        # Atualizar o CsvPath no Config para refletir na tela corretamente
        $script:Config.CsvPath = $currentCsvPath
    }
    catch {
        # Silenciar erros de CSV para não poluir a interface
    }
}

# ── Helpers de layout ────────────────────────────────────────

function Get-GpuSectionHeight {
    param($gpu)
    if (-not $gpu) { return 0 }
    
    $lines = 2
    if ($gpu.Name) { $lines++ }
    $lines++
    if ($gpu.MemUsed -or $gpu.MemTotal) { $lines++ }
    if ($gpu.CoreClock -or $gpu.MemClock) { $lines++ }
    if ($gpu.Power -or $gpu.FanSpeed) { $lines++ }
    
    return $lines
}

function Get-PanelHeight {
    param(
        [int]$DiskCount,
        [int]$NetCount,
        [int]$TopProcCount,
        [bool]$ShowPower,
        [int]$GpuHeight
    )
    
    $height = 0
    $height += 5   # [ Sistema ]
    $height += 4   # [ CPU ]
    $height += $GpuHeight
    if ($ShowPower) { $height += 3 }
    $height += 3   # [ Memória ]
    $height += 2 + $DiskCount + 1  # [ Discos ]
    $height += 2 + [math]::Max($NetCount, 1) + 1  # [ Rede ]
    $height += 2 + 1 + $TopProcCount  # [ Top Processos ]
    $height += 6   # [ Sessão ] - ✅ CORRIGIDO: 6 linhas (incluindo Duração)
    
    return $height
}

# ── Inicialização ────────────────────────────────────────────
Clear-Host
$host.UI.RawUI.WindowTitle = "Monitor de Hardware em Tempo Real  "

Write-Host "╔══════════════════════════════════════╗" -ForegroundColor White
Write-Host "║    MONITOR DE HARDWARE EM TEMPO REAL ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor White
Write-Host " Pressione Ctrl+C para sair  |  Atualiza a cada $($script:Config.RefreshSeconds)s" -ForegroundColor DarkGray

$panelStartRow   = 4
$lastPanelHeight = 0
$cpuName         = Get-CpuName

# ── Loop principal ───────────────────────────────────────────
while ($true) {
    try {
        $originalWindowTop = [Console]::WindowTop
        
        $sysInfo   = Get-SystemInfo
        $cpu       = Get-CpuUsage
        $mem       = Get-MemoryInfo
        $disks     = @(Get-DiskInfo)
        $net       = @(Get-NetworkRate)   
        $topProcs  = @(Get-TopProcesses -Top 5)
        $procStats = Get-ProcessStats
        $cpuTemp   = Get-CpuTemperature
        $power     = Get-PowerConsumption
        $gpu       = Get-GpuInfo

        # ✅ CORRIGIDO: Incrementar contador com [long] para evitar overflow
        $script:Session.ReadingCount = [long]$script:Session.ReadingCount + 1

        Write-HardwareStatsToCsv `
            -Cpu       $cpu `
            -CpuTemp   $cpuTemp `
            -Mem       $mem `
            -Disks     $disks `
            -Net       $net `
            -Gpu       $gpu `
            -Power     $power `
            -ProcStats $procStats

        $showPower     = ($null -ne $power)
        $gpuHeight     = Get-GpuSectionHeight $gpu
        $currentHeight = Get-PanelHeight `
            -DiskCount    $disks.Count `
            -NetCount     $net.Count `
            -TopProcCount $topProcs.Count `
            -ShowPower    $showPower `
            -GpuHeight    $gpuHeight
        
        [Console]::SetCursorPosition(0, $panelStartRow)

        if ($lastPanelHeight -gt $currentHeight) {
            $blank = ' ' * $host.UI.RawUI.WindowSize.Width
            ($currentHeight)..($lastPanelHeight - 1) | ForEach-Object {
                [Console]::SetCursorPosition(0, $panelStartRow + $_)
                Write-Host $blank
            }
            [Console]::SetCursorPosition(0, $panelStartRow)
        }
        $lastPanelHeight = $currentHeight

        # ── Renderizar interface ─────────────────────────────
        Write-Section "[ Sistema ]"
        Write-Host ("  Host   : {0}  |  {1}" -f $sysInfo.ComputerName, $sysInfo.OS)
        Write-Host ("  Uptime : {0}  (boot: {1})" -f $sysInfo.Uptime, $sysInfo.LastBoot)
        Write-Host ("  Procs  : {0}  |  Threads: {1}" -f $procStats.ProcessCount, $procStats.ThreadCount)
        Write-Host ""

        Write-Section "[ CPU ]"
        $tempStr = if ($null -ne $cpuTemp) { "|  Temp: ${cpuTemp}°C" } else { '  Temp: N/D' }
        Write-Host ("  Modelo : {0}" -f $cpuName) -ForegroundColor Gray
        Write-MetricLine -Label "  Uso" -Percent $cpu -Detail $tempStr
        Write-Host ""

        if ($gpu) {
            Write-Section "[ GPU ]"
            
            if ($gpu.Name) {
                Write-Host ("  Modelo : {0}" -f $gpu.Name) -ForegroundColor Gray
            }

            $tempStr = if ($gpu.CoreTemp) { "$($gpu.CoreTemp)°C" } else { "N/D" }
            $loadStr = if ($gpu.CoreLoad) { "$($gpu.CoreLoad)%" } else { "N/D" }
            Write-Host ("  Temp: {0}  |  Uso: {1}" -f $tempStr, $loadStr) -ForegroundColor Green

            if ($gpu.MemUsed -and $gpu.MemTotal) {
                $memStr = "Mem: {0} GB / {1} GB" -f $gpu.MemUsed, $gpu.MemTotal
                if ($gpu.MemLoad) { $memStr += " ({0}%)" -f $gpu.MemLoad }
                Write-Host ("  " + $memStr) -ForegroundColor Green
            } elseif ($gpu.MemUsed) {
                Write-Host ("  Mem usada: {0} GB" -f $gpu.MemUsed) -ForegroundColor Green
            }

            $clocks = @()
            if ($gpu.CoreClock) { $clocks += "Core: $($gpu.CoreClock) MHz" }
            if ($gpu.MemClock)  { $clocks += "Mem: $($gpu.MemClock) MHz" }
            if ($clocks.Count -gt 0) {
                Write-Host ("  " + ($clocks -join " | ")) -ForegroundColor Green
            }

            $extra = @()
            if ($gpu.Power)     { $extra += "Potência: $($gpu.Power) W" }
            if ($gpu.FanSpeed)  { $extra += "Fan: $($gpu.FanSpeed)%" }
            if ($extra.Count -gt 0) {
                Write-Host ("  " + ($extra -join " | ")) -ForegroundColor Gray
            }

            Write-Host ""
        }

        if ($showPower) {
            Write-Section "[ Energia ]"
            $line = "  CPU: "
            $line += if ($power.CPU) { "$($power.CPU) W" } else { "—" }
            $line += "  | GPU: "
            $line += if ($power.GPU) { "$($power.GPU) W" } else { "—" }
            $line += "  | RAM: "
            $line += if ($power.RAM) { "$($power.RAM) W" } else { "—" }
            $line += "  | Total: $($power.Total) W"
            Write-Host $line -ForegroundColor Green
            Write-Host ""
        }

        Write-Section "[ Memória ]"
        Write-MetricLine -Label "  RAM" -Percent $mem.PercentUsed `
            -Detail ("Usada: {0} GB  /  Total: {1} GB  (Livre: {2} GB)" -f $mem.UsedGB, $mem.TotalGB, $mem.FreeGB)
        Write-Host ""

        Write-Section "[ Discos ]"
        foreach ($d in $disks) {
            Write-MetricLine -Label ("  {0}" -f $d.Drive) -Percent $d.PercentUsed `
                -Detail ("Livre: {0} GB / {1} GB  [{2}]" -f $d.FreeGB, $d.TotalGB, $d.Label)
        }
        Write-Host ""

        Write-Section "[ Rede ]"
        if ($net.Count -gt 0) {
            foreach ($iface in $net) {
                Write-Host ("  {0,-35} Total: {1,6} Mbps  ↓ {2,6}  ↑ {3,6}" `
                    -f ($iface.Interface.Substring(0, [math]::Min($iface.Interface.Length, 35))),
                       $iface.TotalMbps, $iface.RecvMbps, $iface.SentMbps) -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Nenhuma atividade detectada." -ForegroundColor DarkGray
        }
        Write-Host ""

        Write-Section "[ Top 5 Processos por CPU ]"
        Write-Host ("  {0,-25} {1,8}  {2,8}" -f "Nome", "CPU (s)", "Mem (MB)") -ForegroundColor DarkGray
        foreach ($p in $topProcs) {
            Write-Host ("  {0,-25} {1,8}  {2,8}" -f $p.Name, $p.CPU_s, $p.MemMB) -ForegroundColor Yellow
        }

        Write-Host ""
        
        $sessionTime    = (Get-Date) - $script:Session.StartTime
        $sessionSeconds = [long][math]::Floor($sessionTime.TotalSeconds)

        Write-Section "[ Sessão de Monitoramento ]"
        Write-Host ("  Início     : {0}" -f $script:Session.StartTime.ToString("dd/MM/yyyy HH:mm:ss")) -ForegroundColor Gray
        Write-Host ("  Duração    : {0}" -f (Format-Uptime $sessionSeconds)) -ForegroundColor Gray  # ✅ Linha que estava faltando!
        Write-Host ("  Leituras   : {0}" -f $script:Session.ReadingCount) -ForegroundColor Gray
        Write-Host ("  Arquivo CSV: {0}" -f $script:Config.CsvPath) -ForegroundColor Gray
        
        [Console]::WindowTop = $originalWindowTop

        $remainingSleep = $script:Config.RefreshSeconds - 1
        if ($remainingSleep -gt 0) {
            Start-Sleep -Seconds $remainingSleep
        }
    }
    catch {
        [Console]::SetCursorPosition(0, $panelStartRow)
        Write-Host ("  Erro: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Start-Sleep -Seconds 5
    }
}