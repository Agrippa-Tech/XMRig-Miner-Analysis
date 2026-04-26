# ============================================================
#  BackupOneDrive.ps1
#  - Aguarda a execucao dos relatorios (agendada pelo AgendamentoRelatorios.ps1)
#  - Copia os arquivos gerados para as pastas do OneDrive
#  - Gera log de cada operacao de backup
# ============================================================

param([switch]$Automatico)

# --- Configuracoes -----------------------------------------------------------
$BaseXMRig      = "C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\XMRig"
$BaseHW         = "C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\Hardware"
$OneDriveXMRig  = "C:\Users\USERNAME\OneDrive\Relatorios\XMRig"
$OneDriveHW     = "C:\Users\USERNAME\OneDrive\Relatorios\Hardware"
$LogDir         = "C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\Logs"
$NomeTarefaRel  = "RelatoriosBackup_Diario"
$NomeTarefaBkp  = "RelatoriosBackup_OneDrive"
$TimeoutEspera  = 600
$IntervaloCheck = 15
# -----------------------------------------------------------------------------

function Write-Log {
    param([string]$Mensagem, [string]$Cor = "White")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $linha = "[$timestamp] $Mensagem"
    Write-Host $linha -ForegroundColor $Cor

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $arquivoLog = Join-Path $LogDir ("backup_onedrive_" + (Get-Date).ToString("dd-MM-yyyy") + ".log")
    Add-Content -Path $arquivoLog -Value $linha
}

function Test-Admin {
    $atual     = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($atual)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HorarioAgendamento {
    param([string]$NomeTarefa)
    $tarefa = Get-ScheduledTask -TaskName $NomeTarefa -ErrorAction SilentlyContinue
    if ($null -eq $tarefa) { return $null }
    try {
        return ([datetime]$tarefa.Triggers[0].StartBoundary).ToString("HH:mm")
    } catch {
        return "desconhecido"
    }
}

# =============================================================================
#  FUNCAO: Criar agendamento
# =============================================================================
function Register-AgendamentoBackup {
    param([string]$HorarioRelatorios = "22:00", [int]$MinutosApos = 30)

    if (-not (Test-Admin)) {
        Write-Host "`n[ERRO] Execute como Administrador para criar o agendamento." -ForegroundColor Red
        return
    }

    try {
        $base       = [datetime]::ParseExact($HorarioRelatorios, "HH:mm", $null)
        $horarioBkp = $base.AddMinutes($MinutosApos).ToString("HH:mm")
    } catch {
        Write-Host "`n[ERRO] Horario invalido: $HorarioRelatorios" -ForegroundColor Red
        return
    }

    $action = New-ScheduledTaskAction `
    -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"C:\Users\USERNAME\XMRig-Miner-Analysis\Backup.ps1`" -Automatico" `
    -WorkingDirectory "C:\Users\USERNAME\XMRig-Miner-Analysis"

    $trigger  = New-ScheduledTaskTrigger -Daily -At $HorarioRelatorios
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    $principal = New-ScheduledTaskPrincipal `
        -UserId "USERNAME\USERNAME" `
        -LogonType Interactive `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName "RelatoriosBackup_OneDrive" `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Force

    Write-Host "`n[OK] Agendamento de backup criado!" -ForegroundColor Green
    Write-Host "     Tarefa : $NomeTarefaBkp" -ForegroundColor White
    Write-Host "     Horario: todos os dias as $horarioBkp ($MinutosApos min apos os relatorios)" -ForegroundColor White
}

# =============================================================================
#  FUNCAO: Cancelar agendamento
# =============================================================================
function Remove-AgendamentoBackup {
    if (-not (Test-Admin)) {
        Write-Host "`n[ERRO] Execute como Administrador para remover o agendamento." -ForegroundColor Red
        return
    }

    $tarefa = Get-ScheduledTask -TaskName $NomeTarefaBkp -ErrorAction SilentlyContinue
    if ($null -eq $tarefa) {
        Write-Host "`n[AVISO] Agendamento '$NomeTarefaBkp' nao encontrado." -ForegroundColor Yellow
    } else {
        Unregister-ScheduledTask -TaskName $NomeTarefaBkp -Confirm:$false
        Write-Host "`n[OK] Agendamento '$NomeTarefaBkp' removido!" -ForegroundColor Green
    }
}

# =============================================================================
#  FUNCAO: Aguardar a tarefa de relatorios terminar
# =============================================================================
function Wait-TarefaRelatorios {
    Write-Log "Verificando status da tarefa '$NomeTarefaRel'..." "Cyan"

    $tarefa = Get-ScheduledTask -TaskName $NomeTarefaRel -ErrorAction SilentlyContinue
    if ($null -eq $tarefa) {
        Write-Log "Tarefa '$NomeTarefaRel' nao encontrada. Prosseguindo sem esperar." "Yellow"
        return
    }

    $decorrido = 0
    while ($decorrido -lt $TimeoutEspera) {
        $info = $tarefa | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        if ($info -and $info.LastTaskResult -ne 267009) {
            Write-Log "Tarefa de relatorios concluida (resultado: $($info.LastTaskResult))." "Green"
            return
        }
        Write-Log "Aguardando tarefa de relatorios... ($decorrido/$TimeoutEspera s)" "Yellow"
        Start-Sleep -Seconds $IntervaloCheck
        $decorrido += $IntervaloCheck
        $tarefa = Get-ScheduledTask -TaskName $NomeTarefaRel -ErrorAction SilentlyContinue
    }

    Write-Log "AVISO: Timeout atingido. Prosseguindo assim mesmo." "Yellow"
}

# =============================================================================
#  FUNCAO: Copiar pasta para OneDrive
# =============================================================================
function Copy-PastaOneDrive {
    param(
        [string]$NomeRelatorio,
        [string]$PastaOrigem,
        [string]$PastaDestino
    )

    $DataPasta = (Get-Date).ToString("dd-MM-yyyy")
    $Origem    = Join-Path $PastaOrigem $DataPasta
    $Destino   = Join-Path $PastaDestino $DataPasta

    Write-Log "--- Backup: $NomeRelatorio ---" "Cyan"
    Write-Log "Origem : $Origem" "White"
    Write-Log "Destino: $Destino" "White"

    if (-not (Test-Path -Path $Origem -PathType Container)) {
        Write-Log "ERRO: Pasta de origem nao encontrada: $Origem" "Red"
        return $false
    }

    $arquivos = Get-ChildItem -Path $Origem -File
    if ($arquivos.Count -eq 0) {
        Write-Log "AVISO: Pasta de origem vazia: $Origem" "Yellow"
        return $false
    }

    if (-not (Test-Path -Path $PastaDestino)) {
        New-Item -ItemType Directory -Path $PastaDestino -Force | Out-Null
        Write-Log "Pasta raiz criada no OneDrive: $PastaDestino" "Green"
    }

    if (-not (Test-Path -Path $Destino)) {
        New-Item -ItemType Directory -Path $Destino -Force | Out-Null
        Write-Log "Pasta de destino criada: $Destino" "Green"
    }

    $copiados = 0
    $erros    = 0
    foreach ($arquivo in $arquivos) {
        $arquivoDestino = Join-Path $Destino $arquivo.Name
        try {
            Copy-Item -Path $arquivo.FullName -Destination $arquivoDestino -Force
            Write-Log "  OK  -> $($arquivo.Name)  ($([math]::Round($arquivo.Length / 1KB, 2)) KB)" "Green"
            $copiados++
        } catch {
            Write-Log "  ERRO ao copiar $($arquivo.Name): $_" "Red"
            $erros++
        }
    }

    Write-Log "$copiados arquivo(s) copiado(s), $erros erro(s)." $(if ($erros -eq 0) { "Green" } else { "Yellow" })
    return ($erros -eq 0)
}

# =============================================================================
#  FUNCAO PRINCIPAL: Executar backup
# =============================================================================
function Invoke-BackupOneDrive {
    Write-Log "========== INICIO DO BACKUP ONEDRIVE ==========" "Cyan"

    if ($Automatico) {
        Wait-TarefaRelatorios
    }

    $okXMRig = Copy-PastaOneDrive -NomeRelatorio "XMRig"   -PastaOrigem $BaseXMRig -PastaDestino $OneDriveXMRig
    $okHW    = Copy-PastaOneDrive -NomeRelatorio "Hardware" -PastaOrigem $BaseHW    -PastaDestino $OneDriveHW

    Write-Log "========== RESULTADO FINAL ==========" "Cyan"
    $problemas = 0
    if (-not $okXMRig) { $problemas++ }
    if (-not $okHW)    { $problemas++ }

    if ($problemas -eq 0) {
        Write-Log "Backup concluido com sucesso!" "Green"
    } else {
        Write-Log "$problemas problema(s) encontrado(s). Verifique os logs em: $LogDir" "Red"
    }
    Write-Log "========== FIM ==========" "Cyan"
}

# =============================================================================
#  PONTO DE ENTRADA
# =============================================================================
if ($Automatico) {
    Invoke-BackupOneDrive
    exit
}

# --- Menu interativo ---------------------------------------------------------
Clear-Host
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     BACKUP ONEDRIVE - MENU PRINCIPAL         ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  1  - Criar agendamento de backup            ║" -ForegroundColor White
Write-Host "║  2  - Cancelar agendamento de backup         ║" -ForegroundColor White
Write-Host "║  3  - Executar backup agora                  ║" -ForegroundColor White
Write-Host "║  4  - Sair                                   ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

$horarioRel = Get-HorarioAgendamento -NomeTarefa $NomeTarefaRel
$horarioBkp = Get-HorarioAgendamento -NomeTarefa $NomeTarefaBkp

Write-Host "`nRelatorios : " -NoNewline
if ($horarioRel) {
    Write-Host "AGENDADO as $horarioRel" -ForegroundColor Green
} else {
    Write-Host "NAO AGENDADO (configure no AgendamentoRelatorios.ps1)" -ForegroundColor Yellow
}

Write-Host "Backup     : " -NoNewline
if ($horarioBkp) {
    Write-Host "AGENDADO as $horarioBkp" -ForegroundColor Green
} else {
    Write-Host "NAO AGENDADO" -ForegroundColor Red
}

Write-Host ""
$opcao = Read-Host "Escolha uma opcao [1-4]"

switch ($opcao) {
    "1" {
        $horarioBase = $horarioRel
        if (-not $horarioBase) {
            $horarioBase = Read-Host "Horario dos relatorios (formato HH:mm, ENTER para 22:00)"
            if ([string]::IsNullOrWhiteSpace($horarioBase)) { $horarioBase = "22:00" }
        } else {
            Write-Host "Horario dos relatorios detectado: $horarioBase" -ForegroundColor Cyan
        }

        $minStr = Read-Host "Quantos minutos apos os relatorios executar o backup? (ENTER para 30)"
        if ([string]::IsNullOrWhiteSpace($minStr)) { $minStr = "30" }
        $min = [int]$minStr

        Register-AgendamentoBackup -HorarioRelatorios $horarioBase -MinutosApos $min
    }
    "2" { Remove-AgendamentoBackup }
    "3" { Invoke-BackupOneDrive }
    "4" { Write-Host "`nSaindo..." -ForegroundColor Gray; exit }
    default { Write-Host "`n[AVISO] Opcao invalida. Escolha entre 1 e 4." -ForegroundColor Yellow }
}

Write-Host "`nPressione qualquer tecla para fechar..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")