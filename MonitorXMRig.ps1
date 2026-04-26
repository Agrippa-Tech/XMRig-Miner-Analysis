# ============================================================
# Monitor XMRig em Tempo Real com Interface Gráfica
# ============================================================

#Requires -Version 7.0

# ── Auto-elevação para Administrador  ─────────────
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Reiniciando como Administrador..." -ForegroundColor Yellow
    $elevArgs = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    Start-Process pwsh -ArgumentList $elevArgs -Verb RunAs
    exit
}

# ── Configuração global ──────────────────────────────────────
$script:Config = @{
    XmrigApiUrl      = "http://127.0.0.1:8080/2/summary"
    CsvPath          = "$env:USERPROFILE\XMRig-Miner-Analysis\RelatoriosXMRig\RelatorioXMRig_$(Get-Date -Format 'yyyyMMdd').csv"
    RefreshSeconds   = 2
    BarWidth         = 22
    CharFilled       = [char]0x2588   # █
    CharEmpty        = [char]0x2591   # ░
    WarnThreshold    = 75
    CritThreshold    = 90
    KeepHistoryCount = 100            # ✅ CORRIGIDO: Aumentado para 100 leituras
    TableMaxRows     = 10             # Altura FIXA da tabela de histórico
}

# ── Histórico de métricas ────────────────────────────────────
$script:History = @{
    Hashrates    = [System.Collections.Generic.Queue[double]]::new()
    Timestamps   = [System.Collections.Generic.Queue[datetime]]::new()
    SharesAccepted = 0
    SharesTotal    = 0
    StartTime    = Get-Date
    TotalReadings = 0  # ✅ NOVO: Contador total de leituras (não limitado)
}

# ── Funções auxiliares (visuais) ─────────────────────────────

function Show-Bar {
    param(
        [double]$Percent,
        [int]$Width         = $script:Config.BarWidth,
        [string]$CharFilled = $script:Config.CharFilled,
        [string]$CharEmpty  = $script:Config.CharEmpty
    )
    # Validar e sanitizar o valor de Percent
    if ([double]::IsNaN($Percent) -or [double]::IsInfinity($Percent)) {
        $Percent = 0
    }
    $Percent = [math]::Clamp($Percent, 0, 100)
    $filled  = [math]::Round($Percent / 100 * $Width)
    $empty   = $Width - $filled
    return ($CharFilled * $filled) + ($CharEmpty * $empty)
}

function Get-ThresholdColor {
    param([double]$Percent)
    # Validar entrada
    if ([double]::IsNaN($Percent) -or [double]::IsInfinity($Percent)) {
        $Percent = 0
    }
    if ($Percent -ge $script:Config.CritThreshold) { return 'Red' }
    if ($Percent -ge $script:Config.WarnThreshold)  { return 'DarkYellow' }
    return 'Green'
}

function Write-Section {
    param([string]$Label)
    try {
        Write-Host $Label -ForegroundColor White
    }
    catch {
        Write-Host $Label
    }
}

function Write-MetricLine {
    param(
        [string]$Label,
        [double]$Percent,
        [string]$Detail
    )
    try {
        # Validar e sanitizar o valor de Percent
        if ([double]::IsNaN($Percent) -or [double]::IsInfinity($Percent)) {
            $Percent = 0
        }
        $Percent = [math]::Clamp($Percent, 0, 100)
        
        $bar   = Show-Bar $Percent
        $color = Get-ThresholdColor $Percent
        
        # Formatar com proteção extra
        $percentStr = [string]::Format("{0,5:F2}", $Percent)
        $line = "$Label`: [$bar] $percentStr%  $Detail"
        
        Write-Host $line -ForegroundColor $color
    }
    catch {
        Write-Host "$Label`: [Erro formatação] $Detail"
    }
}

function Format-Hashrate {
    param([double]$Hashrate)
    
    try {
        # Validar entrada
        if ([double]::IsNaN($Hashrate) -or [double]::IsInfinity($Hashrate) -or $Hashrate -lt 0) {
            return "0.00 H/s"
        }
        
        if ($Hashrate -ge 1000000) {
            $value = $Hashrate / 1000000
            return [string]::Format("{0:N2} MH/s", $value)
        } elseif ($Hashrate -ge 1000) {
            $value = $Hashrate / 1000
            return [string]::Format("{0:N2} KH/s", $value)
        } else {
            return [string]::Format("{0:N2} H/s", $Hashrate)
        }
    }
    catch {
        return "0.00 H/s"
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

function Get-HashratePercent {
    param([double]$Current, [double]$Expected)
    
    # Validar entradas
    if ([double]::IsNaN($Current) -or [double]::IsInfinity($Current)) {
        $Current = 0
    }
    if ([double]::IsNaN($Expected) -or [double]::IsInfinity($Expected)) {
        $Expected = 0
    }
    
    if ($Expected -le 0) { return 0 }
    $percent = ($Current / $Expected) * 100
    
    # Validar resultado
    if ([double]::IsNaN($percent) -or [double]::IsInfinity($percent)) {
        return 0
    }
    
    return [math]::Clamp($percent, 0, 100)
}

function Format-SafeDateTime {
    param([datetime]$DateTime, [string]$Format = "yyyy-MM-dd HH:mm:ss")
    
    try {
        return $DateTime.ToString($Format)
    }
    catch {
        # Fallback seguro
        return "$($DateTime.Year)-$($DateTime.Month.ToString('D2'))-$($DateTime.Day.ToString('D2')) $($DateTime.Hour.ToString('D2')):$($DateTime.Minute.ToString('D2')):$($DateTime.Second.ToString('D2'))"
    }
}

# ── Funções de coleta de dados (XMRig) ──────────────────────

function Get-XmrigData {
    try {
        $response = Invoke-RestMethod -Uri $script:Config.XmrigApiUrl -Method Get -TimeoutSec 2 -ErrorAction Stop
        
        # Função auxiliar para converter valores com validação
        function Get-SafeDouble {
            param($Value)
            $result = [double]($Value ?? 0)
            if ([double]::IsNaN($result) -or [double]::IsInfinity($result)) {
                return 0.0
            }
            return $result
        }
        
        function Get-SafeInt {
            param($Value)
            $result = [int]($Value ?? 0)
            if ($result -lt 0) { return 0 }
            return $result
        }
        
        $data = [PSCustomObject]@{
            Timestamp       = Get-Date
            Hashrate_60s    = Get-SafeDouble $response.hashrate.total[0]
            Hashrate_15m    = Get-SafeDouble $response.hashrate.total[1]
            Hashrate_Max    = Get-SafeDouble $response.hashrate.highest
            Shares_Accepted = Get-SafeInt $response.results.shares_good
            Shares_Total    = Get-SafeInt $response.results.shares_total
            Shares_Rejected = Get-SafeInt (($response.results.shares_total ?? 0) - ($response.results.shares_good ?? 0))
            Difficulty      = Get-SafeDouble $response.connection.diff
            Uptime          = Get-SafeInt $response.uptime
            CpuBrand        = $response.cpu.brand
            CpuAES          = $response.cpu.aes
            CpuAvx2         = $response.cpu.avx2
            Threads         = Get-SafeInt $response.hashrate.threads.Count
            Pool            = $response.connection.pool
            Algo            = $response.algo
            Version         = $response.version
            Connected       = $true
        }
        
        return $data
    }
    catch {
        return [PSCustomObject]@{
            Connected = $false
            Error     = $_.Exception.Message
        }
    }
}

function Update-History {
    param($Data)
    
    if (-not $Data.Connected) { return }
    
    # Validar hashrate antes de adicionar
    $hashrate = $Data.Hashrate_60s
    if ([double]::IsNaN($hashrate) -or [double]::IsInfinity($hashrate) -or $hashrate -lt 0) {
        $hashrate = 0
    }
    
    # Adicionar hashrate ao histórico
    $script:History.Hashrates.Enqueue($hashrate)
    $script:History.Timestamps.Enqueue($Data.Timestamp)
    
    # ✅ CORRIGIDO: Incrementar contador total (nunca reseta)
    $script:History.TotalReadings++
    
    # Manter apenas as últimas N leituras no histórico de visualização
    while ($script:History.Hashrates.Count -gt $script:Config.KeepHistoryCount) {
        $script:History.Hashrates.Dequeue() | Out-Null
        $script:History.Timestamps.Dequeue() | Out-Null
    }
    
    # Atualizar shares totais
    $script:History.SharesAccepted = $Data.Shares_Accepted
    $script:History.SharesTotal = $Data.Shares_Total
}

function Get-HashrateStats {
    if ($script:History.Hashrates.Count -eq 0) {
        return [PSCustomObject]@{
            Current = 0
            Avg     = 0
            Min     = 0
            Max     = 0
        }
    }
    
    $rates = $script:History.Hashrates.ToArray()
    
    # Filtrar valores inválidos
    $validRates = $rates | Where-Object { 
        -not [double]::IsNaN($_) -and 
        -not [double]::IsInfinity($_) -and 
        $_ -ge 0 
    }
    
    if ($validRates.Count -eq 0) {
        return [PSCustomObject]@{
            Current = 0
            Avg     = 0
            Min     = 0
            Max     = 0
        }
    }
    
    return [PSCustomObject]@{
        Current = $validRates[-1]
        Avg     = ($validRates | Measure-Object -Average).Average
        Min     = ($validRates | Measure-Object -Minimum).Minimum
        Max     = ($validRates | Measure-Object -Maximum).Maximum
    }
}

function Write-XmrigStatsToCsv {
    param($Data)
    
    if (-not $Data.Connected) { return }
    
    try {
        # ── Recalcular CsvPath dinamicamente  ──
        $dateStr = Get-Date -Format 'dd-MM-yyyy'
        $currentCsvPath = "$env:USERPROFILE\XMRig-Miner-Analysis\RelatoriosXMRig\RelatorioXMRig_$dateStr.csv"

        $directory = Split-Path -Path $currentCsvPath -Parent
        if (-not (Test-Path $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
        
        $stat = [PSCustomObject]@{
            Timestamp       = Format-SafeDateTime $Data.Timestamp
            Hashrate_60s    = $Data.Hashrate_60s
            Hashrate_15m    = $Data.Hashrate_15m
            Shares_Accepted = $Data.Shares_Accepted
            Shares_Total    = $Data.Shares_Total
            Uptime_Seconds  = $Data.Uptime
        }
        
        if (-not (Test-Path $currentCsvPath)) {
            $stat | Export-Csv -Path $currentCsvPath -NoTypeInformation -Encoding UTF8
        } else {
            $stat | Export-Csv -Path $currentCsvPath -Append -NoTypeInformation -Encoding UTF8
        }

        # Atualizar o CsvPath no Config para refletir na tela corretamente
        $script:Config.CsvPath = $currentCsvPath
    }
    catch {
        # Silenciar erros de CSV para não poluir a interface
    }
}

function Show-HashrateTable {
    param([int]$MaxRows = $script:Config.TableMaxRows)
    
    if ($script:History.Hashrates.Count -eq 0) {
        # Cabeçalho
        Write-Host "  Timestamp            Hashrate        Variação     Status  " -ForegroundColor White
        Write-Host ("  " + ("-" * 58)) -ForegroundColor DarkGray
        
        # Preencher com linhas vazias para manter altura fixa
        Write-Host "  [Coletando dados...]" -ForegroundColor DarkGray
        for ($i = 1; $i -lt $MaxRows; $i++) {
            Write-Host ("  " + (" " * 58))
        }
        
        # Rodapé
        Write-Host ("  " + ("-" * 58)) -ForegroundColor DarkGray
        Write-Host "  Média: ---  |  Min: ---  |  Max: ---  |  " -ForegroundColor Cyan
        return
    }
    
    $rates = $script:History.Hashrates.ToArray()
    $times = $script:History.Timestamps.ToArray()
    
    # Pegar as últimas N leituras
    $startIdx = [math]::Max(0, $rates.Count - $MaxRows)
    
    # Cabeçalho da tabela
    Write-Host "  Timestamp            Hashrate        Variação     Status  " -ForegroundColor White
    Write-Host ("  " + ("-" * 58)) -ForegroundColor DarkGray
    
    # Linhas de dados (exatamente MaxRows linhas)
    $rowsRendered = 0
    for ($i = $startIdx; $i -lt $rates.Count; $i++) {
        try {
            $timestamp = Format-SafeDateTime $times[$i] "HH:mm:ss"
            $hashrate = Format-Hashrate $rates[$i]
            
            # Calcular variação em relação à leitura anterior
            $variation = ""
            $statusIcon = "●"
            $color = "Gray"
            
            if ($i -gt 0) {
                $diff = $rates[$i] - $rates[$i - 1]
                
                # Validar diff
                if ([double]::IsNaN($diff) -or [double]::IsInfinity($diff)) {
                    $diff = 0
                }
                
                $diffPercent = if ($rates[$i - 1] -gt 0) { 
                    ($diff / $rates[$i - 1]) * 100 
                } else { 
                    0 
                }
                
                # Validar diffPercent
                if ([double]::IsNaN($diffPercent) -or [double]::IsInfinity($diffPercent)) {
                    $diffPercent = 0
                }
                
                if ([math]::Abs($diffPercent) -lt 0.5) {
                    $variation = "≈ 0%"
                    $statusIcon = "●"
                    $color = "Green"
                } elseif ($diff -gt 0) {
                    $variation = [string]::Format("+{0:N2}%", $diffPercent)
                    $statusIcon = "▲"
                    $color = "Green"
                } else {
                    $variation = [string]::Format("{0:N2}%", $diffPercent)
                    $statusIcon = "▼"
                    $color = "Red"
                }
            } else {
                $variation = "---"
                $statusIcon = "●"
                $color = "Gray"
            }
            
            # Construir linha com padding manual para evitar erros de formatação
            $line = "  " + $timestamp.PadRight(20) + " " + $hashrate.PadRight(15) + " " + $variation.PadRight(12) + " " + $statusIcon
            Write-Host $line -ForegroundColor $color
            $rowsRendered++
        }
        catch {
            Write-Host ("  " + (" " * 58)) -ForegroundColor DarkGray
            $rowsRendered++
        }
    }
    
    # Preencher linhas vazias se necessário para manter altura fixa
    $emptyRows = $MaxRows - $rowsRendered
    for ($i = 0; $i -lt $emptyRows; $i++) {
        Write-Host ("  " + (" " * 58))
    }
    
    # Rodapé com estatísticas (sempre na mesma posição)
    Write-Host ("  " + ("-" * 58)) -ForegroundColor DarkGray
    
    $recentRates = $rates[$startIdx..($rates.Count - 1)]
    
    # Filtrar valores válidos para cálculos estatísticos
    $validRecentRates = $recentRates | Where-Object { 
        -not [double]::IsNaN($_) -and 
        -not [double]::IsInfinity($_) -and 
        $_ -ge 0 
    }
    
    if ($validRecentRates.Count -gt 0) {
        $avg = ($validRecentRates | Measure-Object -Average).Average
        $min = ($validRecentRates | Measure-Object -Minimum).Minimum
        $max = ($validRecentRates | Measure-Object -Maximum).Maximum
        
        $avgStr = Format-Hashrate $avg
        $minStr = Format-Hashrate $min
        $maxStr = Format-Hashrate $max
        
        Write-Host "  Média: $avgStr  |  Min: $minStr  |  Max: $maxStr  |  " -ForegroundColor Cyan
    } else {
        Write-Host "  Média: ---  |  Min: ---  |  Max: ---  |  " -ForegroundColor Cyan
    }
}

# ── Helpers de layout ────────────────────────────────────────

function Get-PanelHeight {
    param($Data)
    
    # Altura base do painel
    $height = 0
    
    # Cabeçalho de informações (3-4 linhas dependendo da conexão)
    $height += 5  # Título, Status/Pool, Versão/Algo, Uptime, linha vazia
    
    # Hardware (3 linhas)
    $height += 4  # Título, CPU, Features, linha vazia
    
    # Hashrate (depende se tem estatísticas ou não)
    if ($script:History.Hashrates.Count -gt 0) {
        $height += 6  # Título, Atual, Média 15m, Estatísticas locais, linha vazia
    } else {
        $height += 5  # Título, Atual, Média 15m, linha vazia
    }
    
    # Histórico de Hashrate (altura fixa)
    $height += 2  # Título, linha vazia
    $height += 1  # Cabeçalho
    $height += 1  # Linha separadora
    $height += $script:Config.TableMaxRows  # Linhas de dados (fixo)
    $height += 1  # Linha separadora inferior
    $height += 1  # Rodapé com estatísticas
    $height += 1  # Linha vazia
    
    # Shares (7 linhas)
    $height += 8  # Título, Aceitas, Rejeitadas, Total, Barra de aceitação, linha vazia
    
    # Pool (condicional - 3 linhas se houver dificuldade)
    if ($Data.Connected -and $Data.Difficulty) {
        $height += 3  # Título, Dificuldade, linha vazia
    }
    
    # Sessão de Monitoramento (6 linhas)
    $height += 6  # Título, Início, Duração, Leituras, Arquivo CSV, linha vazia final
    
    return $height
}

# ── Renderização da interface ────────────────────────────────

function Show-XmrigMonitor {
    param($Data, $Stats)
    
    try {
        # Cabeçalho
        Write-Section "[ XMRig - Informações do Minerador ]"
        
        if (-not $Data.Connected) {
            Write-Host "  ✗ Não foi possível conectar à API do XMRig" -ForegroundColor Red
            Write-Host "  ✗ Erro: $($Data.Error)" -ForegroundColor Red
            Write-Host "  ℹ Verifique se o XMRig está rodando em $($script:Config.XmrigApiUrl)" -ForegroundColor Yellow
            
            # Preencher espaço vazio para manter altura consistente
            for ($i = 0; $i -lt 30; $i++) {
                Write-Host ""
            }
            return
        }
        
        # Status da conexão
        $poolStatus = if ($Data.Pool) { "✓ Conectado" } else { "✗ Desconectado" }
        $poolColor = if ($Data.Pool) { "Green" } else { "Red" }
        Write-Host "  Status     : $poolStatus  |  Pool: $($Data.Pool)" -ForegroundColor $poolColor
        
        # Informações básicas
        Write-Host "  Versão     : $($Data.Version)  |  Algoritmo: $($Data.Algo)" -ForegroundColor Gray
        Write-Host "  Uptime     : $(Format-Uptime $Data.Uptime)" -ForegroundColor Gray
        Write-Host ""
        
        # CPU Info
        Write-Section "[ Hardware ]"
        Write-Host "  CPU        : $($Data.CpuBrand)" -ForegroundColor Gray
        $features = @()
        if ($Data.CpuAES) { $features += "AES" }
        if ($Data.CpuAvx2) { $features += "AVX2" }
        Write-Host "  Features   : $($features -join ', ')  |  Threads: $($Data.Threads)" -ForegroundColor Gray
        Write-Host ""
        
        # Hashrate atual (barra de progresso baseada no hashrate máximo)
        Write-Section "[ Hashrate ]"
        $currentHashStr = Format-Hashrate $Data.Hashrate_60s
        $maxHashStr = Format-Hashrate $Data.Hashrate_Max
        
        $percentOfMax = Get-HashratePercent -Current $Data.Hashrate_60s -Expected $Data.Hashrate_Max
        Write-MetricLine -Label "  Atual (60s)" -Percent $percentOfMax -Detail "$currentHashStr (max: $maxHashStr)"
        
        # Hashrate 15 min
        $hash15mStr = Format-Hashrate $Data.Hashrate_15m
        $percentOf15m = Get-HashratePercent -Current $Data.Hashrate_15m -Expected $Data.Hashrate_Max
        Write-MetricLine -Label "  Média (15m)" -Percent $percentOf15m -Detail $hash15mStr
        
        # Estatísticas do histórico local
        if ($Stats.Avg -gt 0) {
            $avgHashStr = Format-Hashrate $Stats.Avg
            $minHashStr = Format-Hashrate $Stats.Min
            $maxHashStrLocal = Format-Hashrate $Stats.Max
            Write-Host "  Estatísticas (últimas $($script:Config.KeepHistoryCount)): Média: $avgHashStr  |  Min: $minHashStr  |  Max: $maxHashStrLocal" -ForegroundColor DarkGray
        }
        
        # Tabela (ALTURA FIXA)
        Write-Host ""
        Write-Section "[ Histórico de Hashrate ]"
        Show-HashrateTable -MaxRows $script:Config.TableMaxRows
        Write-Host ""
        
        # Shares
        Write-Section "[ Shares ]"
        $sharesAccepted = [int]($Data.Shares_Accepted ?? 0)
        $sharesRejected = [int]($Data.Shares_Rejected ?? 0)
        $sharesTotal    = [int]($Data.Shares_Total    ?? 0)

        $acceptRate = if ($sharesTotal -gt 0) { 
            $rate = ($sharesAccepted / $sharesTotal) * 100
            if ([double]::IsNaN($rate) -or [double]::IsInfinity($rate)) {
                100.0
            } else {
                [math]::Round($rate, 2)
            }
        } else { 
            100.0 
        }
        $rejectRate = 100 - $acceptRate

        Write-Host "  Aceitas    : $($sharesAccepted.ToString().PadLeft(6))  ($([string]::Format('{0:N2}', $acceptRate))%)" -ForegroundColor Green
        Write-Host "  Rejeitadas : $($sharesRejected.ToString().PadLeft(6))  ($([string]::Format('{0:N2}', $rejectRate))%)" -ForegroundColor $(if ($sharesRejected -gt 0) { 'Red' } else { 'DarkGray' })
        Write-Host "  Total      : $($sharesTotal.ToString().PadLeft(6))" -ForegroundColor White

        $bar   = Show-Bar $acceptRate
        $color = Get-ThresholdColor $acceptRate
        Write-Host "  Taxa Aceit.: [$bar] $([string]::Format('{0:N2}', $acceptRate))%" -ForegroundColor $color
        Write-Host ""

        # Pool
        if ($Data.Difficulty) {
            $difficulty = [double]($Data.Difficulty ?? 0)
            Write-Section "[ Pool ]"
            Write-Host "  Dificuldade: $([string]::Format('{0:N0}', $difficulty))" -ForegroundColor Cyan
            Write-Host ""
        }
        
        $sessionTime    = (Get-Date) - $script:History.StartTime
        $sessionSeconds = [long][math]::Floor($sessionTime.TotalSeconds) 

        # Informações de sessão
        Write-Section "[ Sessão de Monitoramento ]"
        Write-Host "  Início     : $(Format-SafeDateTime $script:History.StartTime 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
        Write-Host "  Duração    : $(Format-Uptime $sessionSeconds)" -ForegroundColor Gray
        Write-Host "  Leituras   : $($script:History.TotalReadings)" -ForegroundColor Gray  # ✅ Mostra contador total
        Write-Host "  Arquivo CSV: $($script:Config.CsvPath)" -ForegroundColor Gray
    }
    catch {
        Write-Host "  ✗ Erro na renderização: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Inicialização ────────────────────────────────────────────
Clear-Host
$host.UI.RawUI.WindowTitle = "Monitor XMRig em Tempo Real"

Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor White
Write-Host "║    MONITOR XMRIG EM TEMPO REAL           ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor White
Write-Host " Pressione Ctrl+C para sair  |  Atualiza a cada $($script:Config.RefreshSeconds)s" -ForegroundColor DarkGray
Write-Host ""

$panelStartRow = 5
$lastPanelHeight = 0

# ── Loop principal ───────────────────────────────────────────
while ($true) {
    try {
        # Salvar posição original da janela
        $originalWindowTop = [Console]::WindowTop
        
        # Coletar dados
        $xmrigData = Get-XmrigData
        
        # Atualizar histórico
        Update-History -Data $xmrigData
        
        # Obter estatísticas
        $stats = Get-HashrateStats
        
        # Salvar em CSV
        Write-XmrigStatsToCsv -Data $xmrigData
        
        # Calcular altura atual do painel
        $currentHeight = Get-PanelHeight -Data $xmrigData

        # Limpar toda a área do painel antes de redesenhar ──
        $blank = ' ' * $host.UI.RawUI.WindowSize.Width
        $clearHeight = [math]::Max($currentHeight, $lastPanelHeight)
        for ($row = 0; $row -lt $clearHeight; $row++) {
            [Console]::SetCursorPosition(0, $panelStartRow + $row)
            Write-Host $blank -NoNewline
        }
        $lastPanelHeight = $currentHeight
        
        # Posicionar cursor no início do painel para renderizar
        [Console]::SetCursorPosition(0, $panelStartRow)
        
        # Renderizar interface (sempre com altura fixa)
        Show-XmrigMonitor -Data $xmrigData -Stats $stats
        
        # Restaurar posição da janela
        [Console]::WindowTop = $originalWindowTop
        
        # Aguardar próximo ciclo
        Start-Sleep -Seconds $script:Config.RefreshSeconds
    }
    catch {
        try {
            [Console]::SetCursorPosition(0, $panelStartRow)
            Write-Host "  ✗ Erro no loop principal: $($_.Exception.Message)" -ForegroundColor Red
        }
        catch {
            # Fallback se até o tratamento de erro falhar
            Write-Host "Erro crítico no loop" -ForegroundColor Red
        }
        Start-Sleep -Seconds 5
    }
}