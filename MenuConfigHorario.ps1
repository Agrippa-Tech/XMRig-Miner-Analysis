# ============================================================
#  AgendadorSuspensao.ps1
#  Agenda suspensão automática e retomada do computador.
#  Requer execução como Administrador.
# ============================================================

#Requires -RunAsAdministrator

# ---------- Funções utilitárias -----------------------------

function Show-Menu {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "   Agendador de Suspensão Automática" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " 1. Usar horários padrão (Dormir 23:00 / Acordar 07:00)"
    Write-Host " 2. Definir horários personalizados"
    Write-Host " 3. Ver tarefas agendadas atuais"
    Write-Host " 4. Remover agendamentos"
    Write-Host " 5. Sair"
    Write-Host ""
}

function Test-TimeInput {
    param([string]$entrada)
    if ($entrada -match '^\d{1,2}:\d{2}$') {
        $partes = $entrada -split ':'
        $h = [int]$partes[0]
        $m = [int]$partes[1]
        return ($h -ge 0 -and $h -le 23 -and $m -ge 0 -and $m -le 59)
    }
    return $false
}

function Get-TimeInput {
    param([string]$mensagem, [string]$padrao)
    do {
        $entrada = Read-Host "$mensagem (padrão: $padrao, formato HH:mm)"
        if ([string]::IsNullOrWhiteSpace($entrada)) { $entrada = $padrao }
        $valido = Test-TimeInput $entrada
        if (-not $valido) { Write-Host "  Hora inválida. Use o formato HH:mm (ex: 23:00)" -ForegroundColor Red }
    } while (-not $valido)
    return $entrada
}

function New-SuspendTask {
    param([string]$hora)   # formato "HH:mm"

    $partes  = $hora -split ':'
    $hh      = $partes[0]
    $mm      = $partes[1]
    $nome    = "AgendadorSuspensao_Dormir"

    # Remove tarefa anterior se existir
    Unregister-ScheduledTask -TaskName $nome -Confirm:$false -ErrorAction SilentlyContinue

    # Ação: suspender sem encerrar processos (equivalente a fechar a tampa)
    $acao = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument '-NonInteractive -WindowStyle Hidden -Command "Add-Type -Assembly System.Windows.Forms; [System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)"'

    $gatilho = New-ScheduledTaskTrigger -Daily -At "$hh`:$mm"

    $config = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $nome -Action $acao `
        -Trigger $gatilho -Settings $config -Principal $principal `
        -Description "Coloca o PC em suspensão todos os dias às $hora" | Out-Null

    Write-Host "  ✔ Tarefa de suspensão criada para $hora todos os dias." -ForegroundColor Green
}

function New-WakeTask {
    param([string]$hora)   # formato "HH:mm"

    $partes  = $hora -split ':'
    $hh      = [int]$partes[0]
    $mm      = [int]$partes[1]
    $nome    = "AgendadorSuspensao_Acordar"

    # Remove tarefa anterior se existir
    Unregister-ScheduledTask -TaskName $nome -Confirm:$false -ErrorAction SilentlyContinue

    # Para acordar o PC, usamos um timer de despertar via powercfg + tarefa agendada com Wake
    $acao = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c echo Acordando..."

    $gatilho = New-ScheduledTaskTrigger -Daily -At "$hh`:$mm"

    # WakeToRun faz o Windows acordar o PC para executar a tarefa
    $config = New-ScheduledTaskSettingsSet `
        -WakeToRun `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $nome -Action $acao `
        -Trigger $gatilho -Settings $config -Principal $principal `
        -Description "Acorda o PC da suspensão todos os dias às $hora" | Out-Null

    Write-Host "  ✔ Tarefa de despertar criada para $hora todos os dias." -ForegroundColor Green
    Write-Host ""
    Write-Host "  IMPORTANTE: Para o despertar funcionar, certifique-se de que" -ForegroundColor Yellow
    Write-Host "  'Permitir que temporizadores de ativação acordem este PC'" -ForegroundColor Yellow
    Write-Host "  está HABILITADO nas Opções de Energia do Windows." -ForegroundColor Yellow
}

function Get-ScheduledTasks {
    Write-Host ""
    Write-Host "--- Tarefas Agendadas Atuais ---" -ForegroundColor Cyan
    $tarefas = Get-ScheduledTask | Where-Object { $_.TaskName -like "AgendadorSuspensao*" }
    if ($tarefas.Count -eq 0) {
        Write-Host "  Nenhuma tarefa encontrada." -ForegroundColor Gray
    } else {
        foreach ($t in $tarefas) {
            $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction SilentlyContinue
            Write-Host ""
            Write-Host "  Nome   : $($t.TaskName)" -ForegroundColor White
            Write-Host "  Status : $($t.State)"
            Write-Host "  Próxima: $($info.NextRunTime)"
        }
    }
    Write-Host ""
}

function Remove-ScheduledTasks {
    $nomes = @("AgendadorSuspensao_Dormir", "AgendadorSuspensao_Acordar")
    foreach ($n in $nomes) {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host ""
    Write-Host "  ✔ Agendamentos removidos com sucesso." -ForegroundColor Green
    Write-Host ""
}

# ---------- Loop principal ----------------------------------

$sair = $false
while (-not $sair) {
    Show-Menu
    $opcao = Read-Host "Escolha uma opção"

    switch ($opcao) {
        '1' {
            Write-Host ""
            New-SuspendTask "23:00"
            New-WakeTask    "07:00"
            Write-Host ""
            Read-Host "Pressione ENTER para continuar"
        }
        '2' {
            Write-Host ""
            $horaDormir  = Get-TimeInput "Hora para SUSPENDER o PC" "23:00"
            $horaAcordar = Get-TimeInput "Hora para ACORDAR o PC  " "07:00"
            Write-Host ""
            New-SuspendTask $horaDormir
            New-WakeTask    $horaAcordar
            Write-Host ""
            Read-Host "Pressione ENTER para continuar"
        }
        '3' {
            Get-ScheduledTasks
            Read-Host "Pressione ENTER para continuar"
        }
        '4' {
            Write-Host ""
            $confirmar = Read-Host "Tem certeza que deseja remover todos os agendamentos? (S/N)"
            if ($confirmar -eq 'S' -or $confirmar -eq 's') {
                Remove-ScheduledTasks
            }
            Read-Host "Pressione ENTER para continuar"
        }
        '5' {
            $sair = $true
        }
        default {
            Write-Host "  Opção inválida." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

Write-Host "Encerrando o Agendador de Suspensão. Até logo!" -ForegroundColor Cyan