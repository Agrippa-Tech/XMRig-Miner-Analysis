# ============================================================
# Script Principal - Orquestrador de Monitoramento
# ============================================================

#Requires -Version 7.0

# ── Auto-elevação para Administrador ────────────────────────
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Reiniciando como Administrador..." -ForegroundColor Yellow
    $elevArgs = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    Start-Process pwsh -ArgumentList $elevArgs -Verb RunAs
    exit
}

# ── Configuração ─────────────────────────────────────────────
$script:Config = @{
    # Caminhos dos executáveis
    LibreHardwareMonitorPath = "C:\Users\USERNAME\LibreHardwareMonitor\LibreHardwareMonitor.exe"
    XMRigPath                = "C:\Users\USERNAME\Documents\xmrig-6.24.0\xmrig.exe"

    # Caminhos dos scripts de monitoramento
    MonitorHardwarePath      = "$PSScriptRoot\MonitorHardware.ps1"
    MonitorXMRigPath         = "$PSScriptRoot\MonitorXMRig.ps1"

    # Configurações do LibreHardwareMonitor
    LhmPort                  = 8085
    LhmStartupDelay          = 3  # segundos para aguardar inicialização

    # Configurações do XMRig
    XmrigApiPort             = 8080
    XmrigStartupDelay        = 2  # segundos para aguardar inicialização

    # Configurações de posicionamento de janelas
    WindowHandleTimeoutSec   = 20  # tempo máximo aguardando handle válido
}

# ── Código C# para posicionamento de janelas ─────────────────
$positionCode = @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public class WindowPosition {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    private const int  SW_RESTORE      = 9;
    private const int  SM_CXSCREEN     = 0;
    private const int  SM_CYSCREEN     = 1;
    private const uint SWP_SHOWWINDOW  = 0x0040;
    private const uint SWP_NOZORDER    = 0x0004;

    private static void SnapWindow(IntPtr hWnd, bool left) {
        if (hWnd == IntPtr.Zero) return;

        int screenWidth  = GetSystemMetrics(SM_CXSCREEN);
        int screenHeight = GetSystemMetrics(SM_CYSCREEN);

        // Restaura antes de mover (sai de maximizado/minimizado)
        ShowWindow(hWnd, SW_RESTORE);
        Thread.Sleep(300);

        int x = left ? 0 : screenWidth / 2;
        SetWindowPos(hWnd, IntPtr.Zero, x, 0,
            screenWidth / 2, screenHeight,
            SWP_SHOWWINDOW | SWP_NOZORDER);
    }

    public static void SnapLeft(IntPtr hWnd)  { SnapWindow(hWnd, true);  }
    public static void SnapRight(IntPtr hWnd) { SnapWindow(hWnd, false); }
}
"@

# Compilar código C# uma única vez na inicialização
$windowPositionAvailable = $false
if (-not ([System.Management.Automation.PSTypeName]'WindowPosition').Type) {
    try {
        Add-Type -TypeDefinition $positionCode -ErrorAction Stop
        $windowPositionAvailable = $true
    }
    catch {
        Write-Warning "Não foi possível compilar código de posicionamento: $($_.Exception.Message)"
    }
}
else {
    $windowPositionAvailable = $true
}

# ── Funções auxiliares ───────────────────────────────────────

function Write-Status {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )

    $color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        default   { "Cyan" }
    }

    $icon = switch ($Type) {
        "Success" { "✓" }
        "Warning" { "⚠" }
        "Error"   { "✗" }
        default   { "ℹ" }
    }

    Write-Host "$icon $Message" -ForegroundColor $color
}

function Test-ProcessRunning {
    param([string]$ProcessName)
    $process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    return $null -ne $process
}

function Test-HttpEndpoint {
    param(
        [string]$Url,
        [int]$TimeoutSec = 2
    )
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

# ── Aguarda handle de janela válido com timeout real ─────────
function Wait-WindowHandle {
    param(
        [int]$ProcessId,
        [int]$TimeoutSec = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
            return $proc.MainWindowHandle
        }
        Start-Sleep -Milliseconds 300
    }

    return [IntPtr]::Zero
}

# ── Posiciona janela desativando Snap do Windows 11 ──────────
function Set-WindowSnap {
    param(
        [IntPtr]$Handle,
        [ValidateSet("Left", "Right")]
        [string]$Side,
        [string]$WindowLabel = "Janela"
    )

    if (-not $windowPositionAvailable) {
        Write-Status "Posicione manualmente: Windows + Seta $(if ($Side -eq 'Left') { 'Esquerda' } else { 'Direita' })" -Type "Warning"
        return
    }

    if ($Handle -eq [IntPtr]::Zero) {
        Write-Status "Handle inválido para $WindowLabel — posicione manualmente." -Type "Warning"
        return
    }

    # Desativa temporariamente o Snap Assist do Windows 11
    $snapKeyPath = "HKCU:\Control Panel\Desktop"
    $snapPreviousValue = (Get-ItemProperty -Path $snapKeyPath -Name "WindowArrangementActive" -ErrorAction SilentlyContinue).WindowArrangementActive

    try {
        Set-ItemProperty -Path $snapKeyPath -Name "WindowArrangementActive" -Value 0 -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 150

        if ($Side -eq "Left") {
            [WindowPosition]::SnapLeft($Handle)
        }
        else {
            [WindowPosition]::SnapRight($Handle)
        }

        Write-Status "$WindowLabel posicionado à $($Side -eq 'Left' ? 'esquerda' : 'direita')" -Type "Success"
    }
    catch {
        Write-Status "Erro ao posicionar $WindowLabel`: $($_.Exception.Message)" -Type "Warning"
    }
    finally {
        # Restaura configuração original do Snap
        if ($null -ne $snapPreviousValue) {
            Set-ItemProperty -Path $snapKeyPath -Name "WindowArrangementActive" -Value $snapPreviousValue -ErrorAction SilentlyContinue
        }
        else {
            Remove-ItemProperty -Path $snapKeyPath -Name "WindowArrangementActive" -ErrorAction SilentlyContinue
        }
    }
}

# ── Etapa 1: LibreHardwareMonitor ────────────────────────────

function Start-LibreHardwareMonitor {
    Write-Status "Verificando LibreHardwareMonitor..." -Type "Info"

    if (Test-ProcessRunning -ProcessName "LibreHardwareMonitor") {
        Write-Status "LibreHardwareMonitor já está em execução" -Type "Success"

        Start-Sleep -Seconds 1
        $webServerActive = Test-HttpEndpoint -Url "http://localhost:$($script:Config.LhmPort)/data.json"

        if ($webServerActive) {
            Write-Status "Servidor web do LHM ativo na porta $($script:Config.LhmPort)" -Type "Success"
            return $true
        }
        else {
            Write-Status "Servidor web NÃO está ativo. Reiniciando LibreHardwareMonitor..." -Type "Warning"
            Stop-Process -Name "LibreHardwareMonitor" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    if (-not (Test-Path $script:Config.LibreHardwareMonitorPath)) {
        Write-Status "LibreHardwareMonitor não encontrado em: $($script:Config.LibreHardwareMonitorPath)" -Type "Error"
        Write-Status "Ajuste o caminho em `$script:Config.LibreHardwareMonitorPath" -Type "Warning"
        return $false
    }

    Write-Status "Iniciando LibreHardwareMonitor..." -Type "Info"

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName    = $script:Config.LibreHardwareMonitorPath
        $startInfo.Verb        = "runas"
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized

        $process = [System.Diagnostics.Process]::Start($startInfo)

        if ($null -eq $process) {
            Write-Status "Falha ao iniciar LibreHardwareMonitor" -Type "Error"
            return $false
        }

        Write-Status "Aguardando inicialização do LibreHardwareMonitor..." -Type "Info"
        Start-Sleep -Seconds $script:Config.LhmStartupDelay

        $attempts       = 0
        $maxAttempts    = 10
        $webServerActive = $false

        while ($attempts -lt $maxAttempts -and -not $webServerActive) {
            $attempts++
            Write-Status "Verificando servidor web (tentativa $attempts/$maxAttempts)..." -Type "Info"
            $webServerActive = Test-HttpEndpoint -Url "http://localhost:$($script:Config.LhmPort)/data.json"
            if (-not $webServerActive) { Start-Sleep -Seconds 2 }
        }

        if ($webServerActive) {
            Write-Status "LibreHardwareMonitor iniciado com sucesso!" -Type "Success"
            Write-Status "Servidor web ativo na porta $($script:Config.LhmPort)" -Type "Success"
            return $true
        }
        else {
            Write-Status "AVISO: LHM rodando, mas servidor web NÃO está ativo" -Type "Warning"
            Write-Host "  1. Abra o LibreHardwareMonitor" -ForegroundColor Yellow
            Write-Host "  2. Vá em Options > Remote Web Server" -ForegroundColor Yellow
            Write-Host "  3. Marque 'Run' e defina a porta como $($script:Config.LhmPort)" -ForegroundColor Yellow
            Write-Host "  4. Clique em OK e reinicie este script" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Pressione qualquer tecla para continuar mesmo assim..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return $false
        }
    }
    catch {
        Write-Status "Erro ao iniciar LibreHardwareMonitor: $($_.Exception.Message)" -Type "Error"
        return $false
    }
}

# ── Etapa 2: XMRig ───────────────────────────────────────────

function Start-XMRig {
    Write-Status "Verificando XMRig..." -Type "Info"

    if (Test-ProcessRunning -ProcessName "xmrig") {
        Write-Status "XMRig já está em execução" -Type "Success"
        return $true
    }

    if (-not (Test-Path $script:Config.XMRigPath)) {
        Write-Status "XMRig não encontrado em: $($script:Config.XMRigPath)" -Type "Error"
        Write-Status "Ajuste o caminho em `$script:Config.XMRigPath" -Type "Warning"
        return $false
    }

    Write-Status "Iniciando XMRig em janela própria (minimizada)..." -Type "Info"

    try {
        $xmrigDir     = [System.IO.Path]::GetDirectoryName($script:Config.XMRigPath)
        $xmrigCommand = "cd '$xmrigDir'; Start-Process -FilePath '$($script:Config.XMRigPath)' -WindowStyle Minimized -WorkingDirectory '$xmrigDir'"

        Start-Process pwsh -ArgumentList '-NoProfile', '-Command', $xmrigCommand -WindowStyle Hidden -Verb RunAs

        Write-Status "Aguardando inicialização do XMRig..." -Type "Info"
        Start-Sleep -Seconds $script:Config.XmrigStartupDelay

        if (-not (Test-ProcessRunning -ProcessName "xmrig")) {
            Write-Status "Falha ao iniciar XMRig" -Type "Error"
            return $false
        }

        Start-Sleep -Seconds 2
        $apiActive = Test-HttpEndpoint -Url "http://127.0.0.1:$($script:Config.XmrigApiPort)/2/summary"

        if ($apiActive) {
            Write-Status "XMRig iniciado com sucesso!" -Type "Success"
            Write-Status "Janela minimizada na barra de tarefas" -Type "Success"
            Write-Status "API ativa na porta $($script:Config.XmrigApiPort)" -Type "Success"
            return $true
        }
        else {
            Write-Status "AVISO: XMRig rodando, mas API não respondeu" -Type "Warning"
            Write-Status "Verifique se a API está habilitada no config.json do XMRig" -Type "Warning"
            return $false
        }
    }
    catch {
        Write-Status "Erro ao iniciar XMRig: $($_.Exception.Message)" -Type "Error"
        return $false
    }
}

# ── Etapa 3: Janelas de monitoramento ────────────────────────

function Start-MonitorWindows {
    Write-Status "Iniciando janelas de monitoramento..." -Type "Info"

    if (-not (Test-Path $script:Config.MonitorHardwarePath)) {
        Write-Status "Script MonitorHardware.ps1 não encontrado em: $($script:Config.MonitorHardwarePath)" -Type "Error"
        return $false
    }

    if (-not (Test-Path $script:Config.MonitorXMRigPath)) {
        Write-Status "Script MonitorXMRig.ps1 não encontrado em: $($script:Config.MonitorXMRigPath)" -Type "Error"
        return $false
    }

    # ── Monitor Hardware (esquerda) ──────────────────────────
    Write-Status "Abrindo Monitor de Hardware (metade esquerda)..." -Type "Info"

    $hwArgs = @(
        '-NoExit',
        '-ExecutionPolicy', 'Bypass',
        '-Command',
        "& '$($script:Config.MonitorHardwarePath)'"
    )

    try {
        $hwProcess = Start-Process pwsh -ArgumentList $hwArgs -PassThru
        Write-Status "Monitor de Hardware iniciado (PID $($hwProcess.Id))" -Type "Info"

        Write-Status "Aguardando handle da janela Hardware..." -Type "Info"
        $hwHandle = Wait-WindowHandle -ProcessId $hwProcess.Id -TimeoutSec $script:Config.WindowHandleTimeoutSec

        if ($hwHandle -ne [IntPtr]::Zero) {
            Set-WindowSnap -Handle $hwHandle -Side "Left" -WindowLabel "Monitor Hardware"
        }
        else {
            Write-Status "Timeout aguardando janela Hardware — posicione manualmente (Win + ←)" -Type "Warning"
        }
    }
    catch {
        Write-Status "Erro ao iniciar Monitor de Hardware: $($_.Exception.Message)" -Type "Error"
    }

    # Pequena pausa para o Windows processar o primeiro snap antes do segundo
    Start-Sleep -Seconds 1

    # ── Monitor XMRig (direita) ──────────────────────────────
    Write-Status "Abrindo Monitor XMRig (metade direita)..." -Type "Info"

    $xmrigArgs = @(
        '-NoExit',
        '-ExecutionPolicy', 'Bypass',
        '-Command',
        "& '$($script:Config.MonitorXMRigPath)'"
    )

    try {
        $xmrigProcess = Start-Process pwsh -ArgumentList $xmrigArgs -PassThru
        Write-Status "Monitor XMRig iniciado (PID $($xmrigProcess.Id))" -Type "Info"

        Write-Status "Aguardando handle da janela XMRig..." -Type "Info"
        $xmrigHandle = Wait-WindowHandle -ProcessId $xmrigProcess.Id -TimeoutSec $script:Config.WindowHandleTimeoutSec

        if ($xmrigHandle -ne [IntPtr]::Zero) {
            Set-WindowSnap -Handle $xmrigHandle -Side "Right" -WindowLabel "Monitor XMRig"
        }
        else {
            Write-Status "Timeout aguardando janela XMRig — posicione manualmente (Win + →)" -Type "Warning"
        }
    }
    catch {
        Write-Status "Erro ao iniciar Monitor XMRig: $($_.Exception.Message)" -Type "Error"
    }

    return $true
}

# ── Inicialização ────────────────────────────────────────────

Clear-Host

Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor White
Write-Host "║   ORQUESTRADOR DE MONITORAMENTO DE HARDWARE E MINERAÇÃO  ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor White
Write-Host ""

# Etapa 1: LibreHardwareMonitor
Write-Host "═══ Etapa 1: LibreHardwareMonitor ═══" -ForegroundColor Cyan
$lhmSuccess = Start-LibreHardwareMonitor
Write-Host ""

if (-not $lhmSuccess) {
    Write-Status "Algumas funcionalidades podem não funcionar sem o LibreHardwareMonitor" -Type "Warning"
    Write-Host ""
}

# Etapa 2: XMRig
Write-Host "═══ Etapa 2: XMRig ═══" -ForegroundColor Cyan
$xmrigSuccess = Start-XMRig
Write-Host ""

if (-not $xmrigSuccess) {
    Write-Status "O Monitor XMRig não terá dados sem o minerador rodando" -Type "Warning"
    Write-Host ""
}

# Etapa 3: Janelas de monitoramento
Write-Host "═══ Etapa 3: Janelas de Monitoramento ═══" -ForegroundColor Cyan
$monitorsSuccess = Start-MonitorWindows
Write-Host ""

# Resumo final
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor White
Write-Host ""

if ($lhmSuccess -and $xmrigSuccess -and $monitorsSuccess) {
    Write-Status "Sistema iniciado com sucesso!" -Type "Success"
    Write-Host ""
    Write-Host "  ✓ LibreHardwareMonitor: Rodando (porta $($script:Config.LhmPort))" -ForegroundColor Green
    Write-Host "  ✓ XMRig: Minerando — janela minimizada (API porta $($script:Config.XmrigApiPort))" -ForegroundColor Green
    Write-Host "  ✓ Monitor Hardware: Metade esquerda da tela" -ForegroundColor Green
    Write-Host "  ✓ Monitor XMRig: Metade direita da tela" -ForegroundColor Green
}
else {
    Write-Status "Sistema iniciado com avisos" -Type "Warning"
    Write-Host ""
    Write-Host "  LibreHardwareMonitor: $(if ($lhmSuccess) { '✓' } else { '✗' })" -ForegroundColor $(if ($lhmSuccess) { 'Green' } else { 'Red' })
    Write-Host "  XMRig:                $(if ($xmrigSuccess) { '✓' } else { '✗' })" -ForegroundColor $(if ($xmrigSuccess) { 'Green' } else { 'Red' })
    Write-Host "  Janelas de Monitor:   $(if ($monitorsSuccess) { '✓' } else { '✗' })" -ForegroundColor $(if ($monitorsSuccess) { 'Green' } else { 'Red' })
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor White
Write-Host ""
Write-Status "Pressione qualquer tecla para fechar esta janela..." -Type "Info"
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")