# ============================================================
#  ExecutarRelatorios.ps1
#  - Menu interativo na primeira execucao
#  - Agenda a si mesmo no Agendador de Tarefas (horario configuravel)
#  - Executa os scripts Python de relatorio com log de erros
#  - Verifica pastas e arquivos gerados
#  - Permite cancelar ou alterar o agendamento
# ============================================================

param([switch]$Automatico)

# --- Configuracoes -----------------------------------------------------------
$PythonExe   = $PythonExe = "C:\Users\USERNAME\AppData\Local\Programs\Python\Python311\python.exe"  # ou caminho completo ex: "C:\Python311\python.exe"
$ScriptXMRig = "C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\XMRig\XMRig.py"
$ScriptHW    = "C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\Hardware\Hardware.py"
$BaseXMRig   = "C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\XMRig"
$BaseHW      = "C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\Hardware"
$LogDir      = "C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\Logs"
$NomeTarefa  = "RelatoriosBackup_Diario"
#$EsteScript  = $MyInvocation.MyCommand.Definition
# -----------------------------------------------------------------------------

function Write-Log {
    param([string]$Mensagem, [string]$Cor = "White")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $linha = "[$timestamp] $Mensagem"
    Write-Host $linha -ForegroundColor $Cor

    # Salva no arquivo de log do dia
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $arquivoLog = Join-Path $LogDir ("execucao_" + (Get-Date).ToString("dd-MM-yy") + ".log")
    Add-Content -Path $arquivoLog -Value $linha
}

function Test-Admin {
    $atual     = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($atual)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =============================================================================
#  FUNCAO: Obter horario atual do agendamento (retorna string "HH:mm" ou $null)
# =============================================================================
function Get-HorarioAgendamento {
    $tarefa = Get-ScheduledTask -TaskName $NomeTarefa -ErrorAction SilentlyContinue
    if ($null -eq $tarefa) { return $null }
    try {
        $inicio = ([datetime]$tarefa.Triggers[0].StartBoundary).ToString("HH:mm")
        return $inicio
    } catch {
        return "desconhecido"
    }
}

# =============================================================================
#  FUNCAO: Criar agendamento
# =============================================================================
function Register-Agendamento {
    param([string]$Horario = "22:00")

    if (-not (Test-Admin)) {
        Write-Host "`n[ERRO] Execute o script como Administrador para criar o agendamento." -ForegroundColor Red
        return
    }

    if ($Horario -notmatch '^\d{2}:\d{2}$') {
        Write-Host "`n[ERRO] Horario invalido. Use o formato HH:mm (ex: 22:00)" -ForegroundColor Red
        return
    }

    $action = New-ScheduledTaskAction `
    -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"C:\Users\USERNAME\XMRig-Miner-Analysis\AgendamentoRelatorios.ps1`" -Automatico" `
    -WorkingDirectory "C:\Users\USERNAME\XMRig-Miner-Analysis"

    $trigger  = New-ScheduledTaskTrigger -Daily -At $Horario
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $principal = New-ScheduledTaskPrincipal `
        -UserId "USERNAME\USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask `
        -TaskName "RelatoriosBackup_Diario" `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Force

    Write-Host "`n[OK] Agendamento criado com sucesso!" -ForegroundColor Green
    Write-Host "     Tarefa : $NomeTarefa" -ForegroundColor White
    Write-Host "     Horario: todos os dias as $Horario" -ForegroundColor White
}

# =============================================================================
#  FUNCAO: Cancelar agendamento
# =============================================================================
function Remove-Agendamento {
    if (-not (Test-Admin)) {
        Write-Host "`n[ERRO] Execute o script como Administrador para remover o agendamento." -ForegroundColor Red
        return
    }

    $tarefa = Get-ScheduledTask -TaskName $NomeTarefa -ErrorAction SilentlyContinue
    if ($null -eq $tarefa) {
        Write-Host "`n[AVISO] Nenhum agendamento com o nome '$NomeTarefa' foi encontrado." -ForegroundColor Yellow
    } else {
        Unregister-ScheduledTask -TaskName $NomeTarefa -Confirm:$false
        Write-Host "`n[OK] Agendamento '$NomeTarefa' removido com sucesso!" -ForegroundColor Green
    }
}

# =============================================================================
#  FUNCAO: Alterar horario do agendamento
# =============================================================================
function Set-HorarioAgendamento {
    if (-not (Test-Admin)) {
        Write-Host "`n[ERRO] Execute o script como Administrador para alterar o agendamento." -ForegroundColor Red
        return
    }

    $horarioAtual = Get-HorarioAgendamento
    if ($null -eq $horarioAtual) {
        Write-Host "`n[AVISO] Nenhum agendamento ativo encontrado. Crie um primeiro (opcao 1)." -ForegroundColor Yellow
        return
    }

    Write-Host "`nHorario atual: $horarioAtual" -ForegroundColor Cyan
    $novoHorario = Read-Host "Digite o novo horario (formato HH:mm, ex: 08:30)"

    if ($novoHorario -notmatch '^\d{2}:\d{2}$') {
        Write-Host "`n[ERRO] Formato invalido. Use HH:mm (ex: 08:30)" -ForegroundColor Red
        return
    }

    # Register-ScheduledTask com -Force substitui o agendamento existente
    Register-Agendamento -Horario $novoHorario
}

# =============================================================================
#  FUNCAO: Executar um script Python e capturar saida/erros em log
# =============================================================================
function Invoke-PythonScript {
    param(
        [string]$NomeScript,
        [string]$CaminhoScript
    )

    Write-Log "Executando $NomeScript ..." "Yellow"

    if (-not (Test-Path $CaminhoScript)) {
        Write-Log "ERRO: Arquivo nao encontrado: $CaminhoScript" "Red"
        return $false
    }

    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $logSaida = Join-Path $LogDir ("${NomeScript}_stdout_" + (Get-Date).ToString("dd-MM-yy") + ".log")

    $pythonResolvido = (Get-Command $PythonExe -ErrorAction SilentlyContinue).Source

    if (-not $pythonResolvido) {
        Write-Log "ERRO: Python nao encontrado." "Red"
        return $false
    }

    Write-Log "Python: $pythonResolvido" "White"

    try {
        # Captura stdout e stderr separadamente sem Start-Process
        $saida = & $pythonResolvido $CaminhoScript 2>&1
        $codigo = $LASTEXITCODE

        # Separa stdout de stderr e salva nos logs
        $saida | Out-File -FilePath $logSaida -Encoding UTF8

        # Exibe no console
        $saida | ForEach-Object { Write-Log "  $_" "White" }

    } catch {
        Write-Log "ERRO ao executar: $_" "Red"
        return $false
    }

    if ($codigo -ne 0) {
        Write-Log "ERRO: $NomeScript terminou com codigo $codigo" "Red"
        Write-Log "      Log: $logSaida" "Red"
        return $false
    }

    Write-Log "$NomeScript finalizado com sucesso. Log: $logSaida" "Green"
    return $true
}

# =============================================================================
#  FUNCAO: Executar relatorios + verificacao
# =============================================================================
function Invoke-Relatorios {
    $DataPasta  = (Get-Date).ToString("dd-MM-yyyy")
    $PastaXMRig = Join-Path $BaseXMRig $DataPasta
    $PastaHW    = Join-Path $BaseHW    $DataPasta

    Write-Log "========== INICIO DA EXECUCAO ==========" "Cyan"

    $okXMRig = Invoke-PythonScript -NomeScript "XMRig"    -CaminhoScript $ScriptXMRig
    $okHW    = Invoke-PythonScript -NomeScript "Hardware"  -CaminhoScript $ScriptHW

    # --- Verificacao de pastas e arquivos ---
    Write-Log "========== VERIFICACAO DE SAIDA ==========" "Cyan"
    Write-Log "Data esperada nas pastas: $DataPasta" "White"

    $erros = 0
    foreach ($Pasta in @($PastaXMRig, $PastaHW)) {
        if (Test-Path -Path $Pasta -PathType Container) {
            Write-Log "OK  - Pasta encontrada: $Pasta" "Green"
            $arquivos = Get-ChildItem -Path $Pasta -File
            if ($arquivos.Count -gt 0) {
                Write-Log "     $($arquivos.Count) arquivo(s) encontrado(s):" "Green"
                foreach ($arq in $arquivos) {
                    Write-Log "       -> $($arq.Name)  ($([math]::Round($arq.Length / 1KB, 2)) KB)" "White"
                }
            } else {
                Write-Log "AVISO: Pasta existe mas esta VAZIA: $Pasta" "Red"
                $erros++
            }
        } else {
            Write-Log "ERRO  - Pasta NAO encontrada: $Pasta" "Red"
            $erros++
        }
    }

    Write-Log "========== RESULTADO FINAL ==========" "Cyan"
    if (-not $okXMRig) { $erros++ }
    if (-not $okHW)    { $erros++ }

    if ($erros -eq 0) {
        Write-Log "Tudo certo! Pastas e arquivos verificados com sucesso." "Green"
    } else {
        Write-Log "$erros problema(s) encontrado(s). Verifique os logs em: $LogDir" "Red"
    }
    Write-Log "========== FIM ==========" "Cyan"
}

# =============================================================================
#  PONTO DE ENTRADA
#  Se chamado com -Automatico (pelo agendador), executa direto sem menu
# =============================================================================
if ($Automatico) {
    Invoke-Relatorios
    exit
}

# --- Menu interativo ---------------------------------------------------------
Clear-Host
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║      RELATORIOS BACKUP - MENU PRINCIPAL      ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  1  - Criar agendamento diario               ║" -ForegroundColor White
Write-Host "║  2  - Cancelar agendamento                   ║" -ForegroundColor White
Write-Host "║  3  - Executar relatorios agora              ║" -ForegroundColor White
Write-Host "║  4  - Alterar horario do agendamento         ║" -ForegroundColor White
Write-Host "║  5  - Sair                                   ║" -ForegroundColor White
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

$horarioAtivo = Get-HorarioAgendamento
if ($horarioAtivo) {
    Write-Host "`nStatus do agendamento: " -NoNewline
    Write-Host "ATIVO (todos os dias as $horarioAtivo)" -ForegroundColor Green
} else {
    Write-Host "`nStatus do agendamento: " -NoNewline
    Write-Host "NAO AGENDADO" -ForegroundColor Red
}

Write-Host ""
$opcao = Read-Host "Escolha uma opcao [1-5]"

switch ($opcao) {
    "1" {
        $h = Read-Host "Digite o horario desejado (formato HH:mm, ENTER para usar 22:00)"
        if ([string]::IsNullOrWhiteSpace($h)) { $h = "22:00" }
        Register-Agendamento -Horario $h
    }
    "2" { Remove-Agendamento }
    "3" { Invoke-Relatorios }
    "4" { Set-HorarioAgendamento }
    "5" { Write-Host "`nSaindo..." -ForegroundColor Gray; exit }
    default { Write-Host "`n[AVISO] Opcao invalida. Execute novamente e escolha entre 1 e 5." -ForegroundColor Yellow }
}

Write-Host "`nPressione qualquer tecla para fechar..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
