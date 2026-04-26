# XMRig-Miner-Analysis

[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue)](https://github.com/PowerShell/PowerShell)
[![Python](https://img.shields.io/badge/Python-3.8+-blue)](https://www.python.org/)
[![Plataforma](https://img.shields.io/badge/Plataforma-Windows-lightgrey)](https://www.microsoft.com/windows)

Sistema completo de monitoramento de hardware e mineração XMRig em tempo real, com dashboards no terminal, exportação de dados para CSV, geração automática de relatórios e backup para OneDrive.

---

## Início Rápido

```powershell
# Clone o repositório
git clone https://github.com/Agrippa-Tech/XMRig-Miner-Analysis.git
cd monitor-hardware-xmrig

# Execute o orquestrador principal como Administrador
pwsh -ExecutionPolicy Bypass -File MenuPrincipal.ps1
```

O script cuida do resto: inicia o LibreHardwareMonitor, o XMRig e abre os dois monitores lado a lado na tela.

---

## Sumário

- [Visão Geral](#visão-geral)
- [Funcionalidades](#funcionalidades)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Requisitos](#requisitos)
- [Instalação e Configuração](#instalação-e-configuração)
- [Como Usar](#como-usar)
- [Scripts em Detalhe](#scripts-em-detalhe)
- [Relatórios](#relatórios)
- [Agendamentos](#agendamentos)
- [Solução de Problemas](#solução-de-problemas)
- [Contribuindo](#contribuindo)
- [Licença](#licença)

---

## Visão Geral

Este projeto oferece um pipeline completo de monitoramento para sistemas que rodam mineração de criptomoedas com XMRig. Ele combina dashboards visuais no terminal com coleta contínua de dados, geração de relatórios estatísticos e backup automático na nuvem.

```
      Orquestrador (MenuPrincipal.ps1)
             │
    ┌────────┴────────┐
    │                 │
MonitorHardware   MonitorXMRig
(metade esquerda) (metade direita)
    │                 │
    └────────┬────────┘
             │
         CSV por dia
             │
    ┌────────┴────────┐
    │                 │
Hardware.py       XMRig.py
(relatórios)   (relatórios)
    │                 │
    └────────┬────────┘
             │
        OneDrive (backup)
```

---

## Funcionalidades

### Monitor de Hardware
- Uso e temperatura de CPU em tempo real
- Uso, temperatura, VRAM e clock de GPU
- Uso e consumo de RAM
- Ocupação de discos
- Taxa de transferência de rede por adaptador
- Consumo de energia (CPU, GPU, RAM, total)
- Top 5 processos por uso de CPU
- Exportação automática para CSV por dia

### Monitor XMRig
- Hashrate em tempo real (60s e 15m)
- Histórico de hashrate com variação percentual
- Taxa de aceitação/rejeição de shares
- Uptime do minerador
- Tabela de histórico com altura fixa (sem flickering)
- Exportação automática para CSV por dia

### Orquestrador
- Inicia LibreHardwareMonitor automaticamente
- Inicia XMRig minimizado
- Posiciona as janelas lado a lado (metade esquerda / direita)
- Verifica APIs antes de abrir os monitores
- Relatório de status ao final

### Geração de Relatórios (Python)
- Relatórios diário, semanal, mensal, semestral e anual
- Estatísticas descritivas completas (média, mediana, desvio padrão, percentis, curtose, assimetria)
- Análise de correlação de Pearson
- Análise temporal por hora e por dia
- Detecção de alertas e anomalias (limites configuráveis)
- Histogramas ASCII e gráficos de barras inline
- Detecção de outliers via método IQR

### Automação
- Agendamento de relatórios via Windows Task Scheduler
- Backup automático para OneDrive após geração dos relatórios
- Agendamento de suspensão e retomada automática do PC
- Logs de execução com timestamp

---

## Estrutura do Projeto

```
monitor-hardware-xmrig/
│
├── MenuPrincipal.ps1                   # Orquestrador principal
├── MonitorHardware.ps1           # Dashboard de hardware em tempo real
├── MonitorXMRig.ps1              # Dashboard do minerador em tempo real
├── MenuConfigRelatorio.ps1       # Agendamento e execução dos relatórios
├── MenuConfigHorario.ps1         # Agendamento de suspensão do PC
├── MenuConfigBackup.ps1          # Cópia dos relatórios para OneDrive
│
├── RelatoriosBackup/
│   ├──XMRig
│   │ └── XMRig.py                # Gerador de relatórios de mineração
│   └── Hardware
│        └── Hardware.py              # Gerador de relatórios de hardware
│
├── README.md
```

> As pastas de dados (`RelatoriosXMRig/`, `RelatoriosHardware/`, `RelatoriosBackup/`, `Logs/`) são criadas automaticamente pelos scripts. Não é necessário criá-las manualmente.

---

## Requisitos

### Sistema
- Windows 10/11
- PowerShell 7.0 ou superior
- Python 3.8 ou superior
- LibreHardwareMonitor (com servidor web ativo)
- XMRig com API HTTP habilitada

### Python (relatórios)
```bash
pip install pandas numpy
```

### Configuração do LibreHardwareMonitor
1. Abra o LibreHardwareMonitor
2. Vá em **Options → Remote Web Server**
3. Marque **Run** e defina a porta como `8085`
4. Clique em OK

### Configuração do XMRig
No `config.json` do XMRig, habilite a API HTTP:
```json
"http": {
    "enabled": true,
    "host": "127.0.0.1",
    "port": 8080,
    "access-token": null,
    "restricted": true
}
```

---

## Instalação e Configuração

### 1. Clone o repositório

```bash
git clone https://github.com/Agrippa-Tech/XMRig-Miner-Analysis.git
cd XMRig-Miner-Analysis
```

### 2. Ajuste os caminhos em `MenuPrincipal.ps1`

Edite a seção `$script:Config` com os caminhos corretos para seu sistema:

```powershell
$script:Config = @{
    LibreHardwareMonitorPath = "C:\caminho\para\LibreHardwareMonitor.exe"
    XMRigPath                = "C:\caminho\para\xmrig.exe"
    MonitorHardwarePath      = "$PSScriptRoot\MonitorHardware.ps1"
    MonitorXMRigPath         = "$PSScriptRoot\MonitorXMRig.ps1"
    LhmPort                  = 8085
    XmrigApiPort             = 8080
}
```

### 3. Ajuste os caminhos nos scripts Python

Em `relatorios/XMRig.py` e `relatorios/Hardware.py`, edite as variáveis de configuração:

```python
CSV_FOLDER  = r"C:\caminho\para\seus\CSVs"
OUTPUT_BASE = r"C:\caminho\para\saida\relatorios"
```

### 4. Ajuste os caminhos em `MenuConfigRelatorios.ps1` e `MenuConfigBackup.ps1`

```powershell
$PythonExe   = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
$ScriptXMRig = "C:\caminho\para\Relatorios\XMRig.py"
$ScriptHW    = "C:\caminho\para\Relatorios\Hardware.py"
```

> **Dica:** Use `$env:USERPROFILE` para referenciar seu diretório home sem hardcodar o nome de usuário.

---

## Como Usar

### Iniciar tudo de uma vez

```powershell
# Execute como Administrador
pwsh -ExecutionPolicy Bypass -File Iniciar.ps1
```

O orquestrador irá:
1. Verificar e iniciar o LibreHardwareMonitor
2. Verificar e iniciar o XMRig
3. Abrir o Monitor de Hardware na metade esquerda da tela
4. Abrir o Monitor XMRig na metade direita da tela

### Iniciar monitores individualmente

```powershell
# Monitor de Hardware
pwsh -ExecutionPolicy Bypass -File MonitorHardware.ps1

# Monitor XMRig
pwsh -ExecutionPolicy Bypass -File MonitorXMRig.ps1
```

### Gerar relatórios manualmente

```powershell
# Abre o menu interativo
pwsh -ExecutionPolicy Bypass -File MenuConfigRelatorio.ps1
```

### Executar backup manualmente

```powershell
pwsh -ExecutionPolicy Bypass -File MenuConfigBackup.ps1
```

### Configurar suspensão automática

```powershell
# Abre o menu interativo
pwsh -ExecutionPolicy Bypass -File MenuConfigHorario.ps1
```

---

## Scripts em Detalhe

### `MenuPrincipal.ps1` — Orquestrador Principal

Gerencia o ciclo de vida completo do sistema. Verifica se os processos já estão rodando antes de iniciá-los, e posiciona as janelas automaticamente usando a API do Windows.

**Configurações disponíveis:**

| Parâmetro | Padrão | Descrição |
|-----------|--------|-----------|
| `LhmPort` | `8085` | Porta do LibreHardwareMonitor |
| `XmrigApiPort` | `8080` | Porta da API do XMRig |
| `LhmStartupDelay` | `3s` | Aguarda inicialização do LHM |
| `XmrigStartupDelay` | `2s` | Aguarda inicialização do XMRig |
| `WindowHandleTimeoutSec` | `20s` | Timeout para posicionar janelas |

---

### `MonitorHardware.ps1` — Dashboard de Hardware

Atualiza a cada 2 segundos e exibe:

```
[ Sistema ]       Host, OS, Uptime, processos e threads
[ CPU ]           Uso percentual, temperatura, modelo
[ GPU ]           Temperatura, uso, VRAM, clocks, potência, fan
[ Energia ]       Consumo CPU / GPU / RAM / Total em Watts
[ Memória ]       Uso em GB e percentual
[ Discos ]        Uso por partição com barra de progresso
[ Rede ]          Taxa de download/upload por adaptador
[ Top Processos ] Top 5 por tempo de CPU
[ Sessão ]        Início, duração, total de leituras, arquivo CSV
```

Barras de progresso mudam de cor automaticamente:
- 🟢 Verde: abaixo de 75%
- 🟡 Amarelo: entre 75% e 90%
- 🔴 Vermelho: acima de 90%

---

### `MonitorXMRig.ps1` — Dashboard do Minerador

Conecta-se à API HTTP do XMRig (`http://127.0.0.1:8080/2/summary`) e exibe:

```
[ Informações ]        Status, pool, versão, algoritmo, uptime
[ Hardware ]           CPU, features (AES/AVX2), threads
[ Hashrate ]           Atual (60s) e média (15m) com barra de progresso
[ Histórico ]          Tabela com timestamp, hashrate e variação percentual
[ Shares ]             Aceitos, rejeitados, taxa de aceitação
[ Pool ]               Dificuldade atual
[ Sessão ]             Início, duração, leituras, arquivo CSV
```

---

### `MenuConfigRelatorio.ps1` — Gerenciador de Relatórios

Menu interativo com opções:

| Opção | Ação |
|-------|------|
| 1 | Criar agendamento diário |
| 2 | Cancelar agendamento |
| 3 | Executar relatórios agora |
| 4 | Alterar horário do agendamento |
| 5 | Sair |

Os relatórios Python são executados, com stdout e stderr capturados em arquivos de log separados por dia.

---

### `MenuConfigHorario.ps1` — Controle de Energia

Agenda suspensão e retomada automática do computador via Windows Task Scheduler. Útil para pausar a mineração em horários de pico de energia.

```powershell
# Horários padrão
Suspender : 23:00
Acordar   : 07:00
```

> Para que o despertar funcione, certifique-se de que **"Permitir que temporizadores de ativação acordem este PC"** está habilitado nas Opções de Energia do Windows.

---

### `MenuConfigBackup.ps1` — Backup Automático

Copia as pastas de relatórios do dia para o OneDrive, organizando por data:

```
OneDrive/
└── Relatorios/
    ├── XMRig/
    │   └── 26-04-2026/
    │       └── relatorio_xmrig_diario_26-04-2026.txt
    └── Hardware/
        └── 26-04-2026/
            └── relatorio_hardware_diario_26-04-2026.txt
```

---

## Relatórios

Os scripts Python geram relatórios em `.txt` para cinco períodos, conforme o histórico de dados disponível:

| Período | Mínimo de dados |
|---------|-----------------|
| Diário | 1 dia |
| Semanal | 7 dias |
| Mensal | 30 dias |
| Semestral | 180 dias |
| Anual | 365 dias |

### Estrutura de cada relatório

```
Seção 1 — Visão Geral e Métricas
Seção 2 — Estatísticas Descritivas (por variável)
Seção 3 — Análise de Correlação (Pearson)
Seção 4 — Análise Temporal (por hora e por dia)
Seção 5 — Alertas e Anomalias
Seção 6 — Sumário Executivo
```

### Exemplo de alerta gerado automaticamente

```
[!] Temperatura CPU      12 leituras acima do limite (1,4%)
     Limite: 85 C  |  Máximo registrado: 91,20 C
```

---

## Agendamentos

O projeto usa o **Windows Task Scheduler** para automação. Todas as tarefas são gerenciadas pelos próprios scripts — sem necessidade de configuração manual.

| Tarefa | Script | Descrição |
|--------|--------|-----------|
| `RelatoriosBackup_Diario` | `MenuConfigRelatorio.ps1` | Executa relatórios Python |
| `RelatoriosBackup_OneDrive` | `MenuConfigBackup.ps1` | Copia relatórios para OneDrive |
| `AgendadorSuspensao_Dormir` | `MenuConfigHorario.ps1` | Suspende o PC |
| `AgendadorSuspensao_Acordar` | `MenuConfigHorario.ps1` | Retoma o PC |

---

## Dados Gerados

Os scripts criam automaticamente as seguintes pastas (não incluídas no repositório):

```
RelatoriosXMRig/          ← CSVs diários do XMRig
RelatoriosHardware/       ← CSVs diários do hardware
RelatoriosBackup/
├── XMRig/                ← Relatórios .txt organizados por data
├── Hardware/             ← Relatórios .txt organizados por data
└── Logs/                 ← Logs de execução dos scripts
```

---

## Solução de Problemas

### LibreHardwareMonitor não detecta temperatura

Certifique-se de que o LHM está rodando como **Administrador** e que o servidor web está ativo na porta `8085`.

### XMRig API não responde

Verifique se a API está habilitada no `config.json` e se o XMRig está rodando. A URL padrão é `http://127.0.0.1:8080/2/summary`.

### Janelas não posicionam automaticamente

O posicionamento requer que a janela tenha um handle válido (pode demorar alguns segundos). Se o timeout for atingido, posicione manualmente com `Win + ←` e `Win + →`.

### Relatórios Python não geram

Verifique se o caminho do Python está correto e se as dependências estão instaladas:

```bash
pip install pandas numpy
```

Confira também se existem arquivos CSV na pasta configurada e se o padrão de nome (`RelatorioXMRig_dd-mm-aaaa.csv`) está correto.

### Erro de permissão ao criar agendamentos

Os scripts de agendamento precisam ser executados como **Administrador**.

---

## Contribuindo

Contribuições são bem-vindas! Para contribuir:

1. Fork o repositório
2. Crie uma branch de feature (`git checkout -b feature/minha-feature`)
3. Faça suas alterações
4. Certifique-se de não incluir dados pessoais ou caminhos hardcoded
5. Abra um Pull Request descrevendo as mudanças

---

**Versão:** 1.0.0 | **PowerShell:** 7.0+ | **Python:** 3.8+ | **Plataforma:** Windows 10/11