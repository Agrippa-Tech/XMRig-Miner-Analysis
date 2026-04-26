"""
Gerador de Relatorios de Hardware
==================================
Le arquivos CSV no padrao RelatorioHardware_dd-mm-aaaa.csv,
agrupa por data e gera relatorios .txt para os periodos:
  - Diario
  - Semanal   (minimo 7 dias de span)
  - Mensal    (minimo 30 dias de span)
  - Semestral (minimo 180 dias de span)
  - Anual     (minimo 365 dias de span)

"""

import os
import re
import glob
from datetime import datetime, date, timedelta
from pathlib import Path
from collections import defaultdict

import pandas as pd
import numpy as np

# ==============================================================================
# CONFIGURACOES
# ==============================================================================

CSV_FOLDER     = r"C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosHardware"
OUTPUT_BASE    = r"C:\Users\USERNAMEs\XMRig-Miner-Analysis\RelatoriosBackup\Hardware"
CSV_PATTERN    = "RelatorioHardware_*.csv"
CSV_DATE_REGEX = re.compile(r"RelatorioHardware_(\d{2}-\d{2}-\d{4})\.csv", re.IGNORECASE)

PERIODOS = {
    "diario":    0,
    "semanal":   7,
    "mensal":    30,
    "semestral": 180,
    "anual":     365,
}

COLS_IGNORE = {"Timestamp", "Disk1_Drive", "_date"}

W = 90  # largura total do relatorio

# ==============================================================================
# LEITURA E PRE-PROCESSAMENTO
# ==============================================================================

def ler_csv(filepath: str) -> pd.DataFrame:
    df = pd.read_csv(
        filepath, sep=",", quotechar='"', decimal=",",
        na_values=["", " "], low_memory=False,
    )
    df.columns = [c.strip().strip('"') for c in df.columns]
    if "Timestamp" in df.columns:
        df["Timestamp"] = pd.to_datetime(df["Timestamp"], errors="coerce")
        df["_date"] = df["Timestamp"].dt.date
    return df


def descobrir_arquivos(pasta: str) -> dict:
    arquivos_por_data = defaultdict(list)
    for fp in glob.glob(os.path.join(pasta, CSV_PATTERN)):
        m = CSV_DATE_REGEX.search(os.path.basename(fp))
        if m:
            dt = datetime.strptime(m.group(1), "%d-%m-%Y").date()
            arquivos_por_data[dt].append(fp)
    return arquivos_por_data


def carregar_periodo(arquivos_por_data: dict, datas: list) -> pd.DataFrame:
    frames = []
    for d in datas:
        for fp in arquivos_por_data.get(d, []):
            try:
                frames.append(ler_csv(fp))
            except Exception as e:
                print(f"  [AVISO] Erro ao ler {fp}: {e}")
    return pd.concat(frames, ignore_index=True) if frames else pd.DataFrame()


# ==============================================================================
# CALCULO DE ESTATISTICAS
# ==============================================================================

def estatisticas_coluna(serie: pd.Series) -> dict:
    s = pd.to_numeric(serie, errors="coerce").dropna()
    if s.empty:
        return {}
    q1, med, q3 = np.percentile(s, [25, 50, 75])
    std  = float(s.std(ddof=1)) if len(s) > 1 else 0.0
    mean = float(s.mean())
    return {
        "count":    len(s),
        "missing":  int(serie.isna().sum()),
        "mean":     mean,
        "median":   float(med),
        "std":      std,
        "variance": float(s.var(ddof=1)) if len(s) > 1 else 0.0,
        "cv_pct":   (std / mean * 100) if mean != 0 else 0.0,
        "min":      float(s.min()),
        "p5":       float(np.percentile(s, 5)),
        "q1":       float(q1),
        "q3":       float(q3),
        "p95":      float(np.percentile(s, 95)),
        "max":      float(s.max()),
        "range":    float(s.max() - s.min()),
        "iqr":      float(q3 - q1),
        "skewness": float(s.skew()),
        "kurtosis": float(s.kurtosis()),
    }


def calcular_correlacoes(df: pd.DataFrame, cols: list) -> pd.DataFrame:
    sub = df[cols].apply(pd.to_numeric, errors="coerce")
    return sub.corr(method="pearson")


def colunas_validas(df: pd.DataFrame) -> list:
    result = []
    for c in df.columns:
        if c in COLS_IGNORE:
            continue
        s = pd.to_numeric(df[c], errors="coerce").dropna()
        if not s.empty:
            result.append(c)
    return result


def colunas_com_variancia(df: pd.DataFrame, cols: list) -> list:
    return [c for c in cols
            if pd.to_numeric(df[c], errors="coerce").dropna().std() > 0]


# ==============================================================================
# PRIMITIVAS DE FORMATACAO
# ==============================================================================

def linha(char: str = "-", largura: int = None) -> str:
    return char * (largura or W)


def num(v: float, decimais: int = 4) -> str:
    """Formata numero no padrao BR (ponto como milhar, virgula como decimal)."""
    fmt = f"{v:,.{decimais}f}"
    return fmt.replace(",", "X").replace(".", ",").replace("X", ".")


def barra(valor: float, maximo: float, largura: int = 34,
          char_cheio: str = "#", char_vazio: str = ".") -> str:
    if maximo <= 0:
        return char_vazio * largura
    proporcao = min(valor / maximo, 1.0)
    cheios = round(proporcao * largura)
    return char_cheio * cheios + char_vazio * (largura - cheios)


def caixa(texto: str, char_borda: str = "=") -> str:
    """Caixa centralizada com borda dupla."""
    inner = W - 4
    borda = char_borda * W
    conteudo = f"  {texto.center(inner)}  "
    return f"{borda}\n{conteudo}\n{borda}"


def cabecalho_secao(numero: int, titulo: str) -> str:
    rotulo = f"  SECAO {numero}  |  {titulo.upper()}"
    return f"\n\n{'#' * W}\n{rotulo}\n{'#' * W}\n"


def cabecalho_subsecao(titulo: str) -> str:
    return f"\n  {'~' * (W - 4)}\n  {titulo}\n  {'~' * (W - 4)}\n"


def campo(label: str, valor: str, largura_label: int = 24) -> str:
    return f"  {label:<{largura_label}} {valor}"


# ==============================================================================
# GRUPOS DE VARIAVEIS
# ==============================================================================

GRUPOS_DEF = {
    "CPU":     lambda c: "cpu" in c.lower(),
    "GPU":     lambda c: "gpu" in c.lower(),
    "RAM":     lambda c: "ram" in c.lower(),
    "Energia": lambda c: "power" in c.lower(),
    "Rede":    lambda c: "net" in c.lower(),
    "Disco":   lambda c: "disk" in c.lower(),
    "Sistema": lambda c: c in ("Process_Count", "Thread_Count"),
}

def agrupar_colunas(cols: list) -> dict:
    grupos = {g: [] for g in GRUPOS_DEF}
    grupos["Outros"] = []
    alocadas = set()
    for g, pred in GRUPOS_DEF.items():
        for c in cols:
            if c not in alocadas and pred(c):
                grupos[g].append(c)
                alocadas.add(c)
    for c in cols:
        if c not in alocadas:
            grupos["Outros"].append(c)
    return {g: v for g, v in grupos.items() if v}


# ==============================================================================
# BLOCO 1 – CABECALHO
# ==============================================================================

def bloco_cabecalho(periodo: str, data_ini: date, data_fim: date,
                    n_registros: int, n_dias: int, n_arquivos: int) -> str:
    titulo = f"RELATORIO DE MONITORAMENTO DE HARDWARE  |  {periodo.upper()}"
    gerado = datetime.now().strftime("%d/%m/%Y   %H:%M:%S")
    linhas = [
        "",
        caixa(titulo),
        "",
        campo("Gerado em:",            gerado),
        campo("Periodo coberto:",
              f"{data_ini.strftime('%d/%m/%Y')}  ate  {data_fim.strftime('%d/%m/%Y')}"),
        campo("Duracao:",              f"{n_dias} dia(s) de dados"),
        campo("Arquivos processados:", str(n_arquivos)),
        campo("Total de registros:",   f"{n_registros:,}".replace(",", ".")),
        "",
        linha("="),
        "",
    ]
    return "\n".join(linhas)


# ==============================================================================
# BLOCO 2 – VISAO GERAL
# ==============================================================================

def bloco_visao_geral(df: pd.DataFrame, cols: list) -> str:
    grupos = agrupar_colunas(cols)
    linhas = [cabecalho_secao(1, "Visao Geral")]

    # Cobertura temporal
    if "Timestamp" in df.columns:
        ts = df["Timestamp"].dropna()
        if not ts.empty:
            dur_h  = (ts.max() - ts.min()).total_seconds() / 3600
            freq_s = ts.sort_values().diff().dt.total_seconds().dropna().median()
            linhas += [
                campo("Inicio da coleta:", ts.min().strftime("%d/%m/%Y  %H:%M:%S")),
                campo("Fim da coleta:",    ts.max().strftime("%d/%m/%Y  %H:%M:%S")),
                campo("Duracao total:",    f"{dur_h:.1f} horas"),
                campo("Freq. amostragem:", f"~{freq_s:.0f} segundos entre leituras"),
                "",
            ]

    linhas.append(campo("Variaveis monitoradas:", str(len(cols))))
    linhas.append("")

    # Tabela de grupos
    linhas += [
        f"  {'Grupo':<14}  {'Qtd':>4}   Variaveis",
        f"  {linha('-', W - 4)}",
    ]
    for grupo, gcols in grupos.items():
        nomes = "  ".join(gcols)
        # quebra em multiplas linhas se necessario
        max_w = W - 26
        if len(nomes) > max_w:
            linhas_nomes = []
            atual = ""
            for c in gcols:
                teste = (atual + "  " + c) if atual else c
                if len(teste) <= max_w:
                    atual = teste
                else:
                    linhas_nomes.append(atual)
                    atual = c
            if atual:
                linhas_nomes.append(atual)
            linhas.append(f"  {grupo:<14}  {len(gcols):>4}   {linhas_nomes[0]}")
            for l in linhas_nomes[1:]:
                linhas.append(f"  {'':14}  {'':>4}   {l}")
        else:
            linhas.append(f"  {grupo:<14}  {len(gcols):>4}   {nomes}")

    linhas.append("")
    return "\n".join(linhas)


# ==============================================================================
# BLOCO 3 – ESTATISTICAS DESCRITIVAS
# ==============================================================================

def bloco_estatisticas(df: pd.DataFrame, cols: list) -> str:
    grupos = agrupar_colunas(cols)
    linhas = [cabecalho_secao(2, "Estatisticas Descritivas por Variavel")]

    for grupo, gcols in grupos.items():
        linhas.append(cabecalho_subsecao(f"Grupo  >>  {grupo}"))

        for col in gcols:
            est = estatisticas_coluna(df[col])
            if not est:
                linhas += [f"  {col}: sem dados validos", ""]
                continue

            pct_ausente = (est["missing"] / (est["count"] + est["missing"]) * 100
                           if (est["count"] + est["missing"]) > 0 else 0)

            # Cabecalho da variavel
            linhas += [
                f"  +{'-' * (W - 4)}+",
                f"  | Variavel : {col:<{W - 16}}|",
                f"  | Registros: {est['count']:>7,}   Ausentes: {est['missing']:>5,} ({pct_ausente:>4.1f}%){' ' * (W - 57)}|".replace(",", "."),
                f"  +{'=' * (W - 4)}+",
            ]

            # Painel esquerdo: tendencia central | Painel direito: dispersao
            L = 41
            def row(label, val, dec=4):
                return f"  {label:<22} {num(val, dec):>14}"

            esq = [
                "  TENDENCIA CENTRAL & PERCENTIS",
                "  " + "-" * L,
                row("Media",          est["mean"],   2),
                row("Mediana",        est["median"], 2),
                row("Minimo",         est["min"],    2),
                row("Maximo",         est["max"],    2),
                row("Amplitude",      est["range"],  2),
                row("P5   ( 5%)",     est["p5"],     2),
                row("Q1   (25%)",     est["q1"],     2),
                row("Q3   (75%)",     est["q3"],     2),
                row("P95  (95%)",     est["p95"],    2),
            ]
            dir_ = [
                "  DISPERSAO & FORMA",
                "  " + "-" * L,
                row("Desvio Padrao",      est["std"],      4),
                row("Variancia",          est["variance"], 4),
                row("Coef. Variacao (%)", est["cv_pct"],   2),
                row("IQR",               est["iqr"],      4),
                row("Assimetria",         est["skewness"], 4),
                row("Curtose",            est["kurtosis"], 4),
            ]

            maxl = max(len(esq), len(dir_))
            while len(esq)  < maxl: esq.append("")
            while len(dir_) < maxl: dir_.append("")

            for a, b in zip(esq, dir_):
                pad_a = f"{a:<{L + 6}}"
                linhas.append(f"  {pad_a}  {b}")

            # Histograma ASCII
            s = pd.to_numeric(df[col], errors="coerce").dropna()
            if len(s) > 1 and s.std() > 0:
                buckets = 10
                counts, edges = np.histogram(s, bins=buckets)
                max_c = max(counts) if max(counts) > 0 else 1
                linhas += [
                    "",
                    "  HISTOGRAMA DE DISTRIBUICAO",
                    f"  {'Faixa de valores':<28}  {'Frequencia':>10}  {'Grafico'}",
                    "  " + "-" * 72,
                ]
                for i in range(buckets):
                    rotulo = f"[{num(edges[i], 2):>10}  a  {num(edges[i+1], 2):>10}]"
                    b_str  = barra(counts[i], max_c, largura=28)
                    linhas.append(f"  {rotulo}  {counts[i]:>10}  {b_str}")

            linhas += [f"  +{'-' * (W - 4)}+", ""]

    return "\n".join(linhas)


# ==============================================================================
# BLOCO 4 – CORRELACOES
# ==============================================================================

def bloco_correlacao(df: pd.DataFrame, cols: list) -> str:
    linhas = [cabecalho_secao(3, "Analise de Correlacao (Pearson)"), ""]
    cols_v = colunas_com_variancia(df, cols)

    if len(cols_v) < 2:
        linhas.append("  Dados insuficientes para calcular correlacoes.")
        return "\n".join(linhas)

    corr_df = calcular_correlacoes(df, cols_v)

    # Coleta todos os pares
    pares = []
    for i, c1 in enumerate(cols_v):
        for j, c2 in enumerate(cols_v):
            if j <= i: continue
            val = corr_df.loc[c1, c2]
            if not pd.isna(val):
                pares.append((abs(val), val, c1, c2))
    pares.sort(reverse=True)

    def intensidade(r: float) -> str:
        a = abs(r)
        if a >= 0.90: return "MUITO FORTE"
        if a >= 0.70: return "FORTE      "
        if a >= 0.50: return "MODERADA   "
        return              "FRACA      "

    def direcao(r: float) -> str:
        return "(+) positiva" if r > 0 else "(-) negativa"

    # --- Tabela de pares relevantes ---
    linhas += [
        "  Pares com correlacao relevante  (|r| >= 0,50)",
        "  " + linha("-", W - 4),
        f"  {'Variavel A':<28}  {'Variavel B':<28}  {'r':>8}  {'Intensidade':<13}  {'Direcao'}",
        "  " + linha("-", W - 4),
    ]

    encontrou = False
    for _, val, c1, c2 in pares:
        if abs(val) < 0.50: break
        linhas.append(
            f"  {c1:<28}  {c2:<28}  {val:>+8.4f}  {intensidade(val)}  {direcao(val)}"
        )
        encontrou = True

    if not encontrou:
        linhas.append("  Nenhum par com correlacao relevante encontrado.")
    linhas += [f"  {linha('-', W - 4)}", ""]

    # --- Insights automaticos ---
    linhas += [cabecalho_subsecao("Interpretacao Automatica"), ""]
    insights = []
    for _, val, c1, c2 in pares:
        if abs(val) >= 0.90:
            insights.append(
                f"  >> {c1}  <->  {c2}\n"
                f"     Correlacao MUITO FORTE (r = {val:+.4f}): as variaveis"
                f" variam quase identicamente."
            )
        elif abs(val) >= 0.70:
            insights.append(
                f"  >> {c1}  <->  {c2}\n"
                f"     Correlacao FORTE (r = {val:+.4f}): forte tendencia de variacao conjunta."
            )
        if len(insights) >= 8:
            break

    if not insights:
        insights.append("  Nenhuma correlacao forte identificada.")
    linhas += insights
    linhas.append("")

    return "\n".join(linhas)


# ==============================================================================
# BLOCO 5 – ANALISE TEMPORAL
# ==============================================================================

def bloco_temporal(df: pd.DataFrame) -> str:
    linhas = [cabecalho_secao(4, "Analise Temporal"), ""]

    if "Timestamp" not in df.columns or df["Timestamp"].isna().all():
        linhas.append("  Dados temporais insuficientes.")
        return "\n".join(linhas)

    df2 = df.copy()
    df2["hora"] = df2["Timestamp"].dt.hour

    metricas = [
        ("CPU_Pct",        "Uso CPU (%)",        100),
        ("CPU_Temp_C",     "Temperatura CPU (C)", None),
        ("RAM_Pct",        "Uso RAM (%)",         100),
        ("Power_Total_W",  "Potencia Total (W)",  None),
        ("GPU_Temp_C",     "Temperatura GPU (C)", None),
        ("Net_Recv_Mbps",  "Rede Recebida (Mbps)",None),
    ]

    for col, label, ref in metricas:
        if col not in df2.columns: continue
        sub = df2[["hora", col]].copy()
        sub[col] = pd.to_numeric(sub[col], errors="coerce")
        sub = sub.dropna()
        if sub.empty: continue

        g = sub.groupby("hora")[col]
        medias  = g.mean()
        maximos = g.max()
        minimos = g.min()
        mx_ref  = ref if ref is not None else float(medias.max()) or 1.0

        linhas += [
            f"  {label}",
            f"  {'Hora':>5}  {'Media':>10}  {'Minimo':>10}  {'Maximo':>10}  Grafico (proporcional a media)",
            "  " + linha("-", W - 4),
        ]
        for h in sorted(medias.index):
            med = medias[h]; mn = minimos[h]; mx = maximos[h]
            b   = barra(med, mx_ref, largura=30, char_cheio="=", char_vazio=" ")
            linhas.append(
                f"  {h:02d}h    {num(med, 2):>10}  {num(mn, 2):>10}  {num(mx, 2):>10}  |{b}|"
            )
        linhas.append("")

    # Tendencia diaria (se houver multiplos dias)
    if "_date" in df2.columns:
        datas_unicas = sorted(df2["_date"].dropna().unique())
        if len(datas_unicas) > 1:
            linhas += [
                cabecalho_subsecao("Tendencia Diaria  (media das principais metricas)"), "",
                f"  {'Data':<14}  {'CPU (%)':>10}  {'Temp CPU':>10}  {'RAM (%)':>10}  {'Watts':>10}",
                "  " + linha("-", W - 4),
            ]
            for d in datas_unicas:
                sub_d = df2[df2["_date"] == d]
                vals  = []
                for c in ["CPU_Pct", "CPU_Temp_C", "RAM_Pct", "Power_Total_W"]:
                    s = pd.to_numeric(sub_d.get(c, pd.Series()), errors="coerce").dropna()
                    vals.append(f"{s.mean():>10.2f}" if not s.empty else f"{'N/A':>10}")
                linhas.append(f"  {str(d):<14}  {'  '.join(vals)}")
            linhas.append("")

    return "\n".join(linhas)


# ==============================================================================
# BLOCO 6 – ALERTAS E ANOMALIAS
# ==============================================================================

def bloco_alertas(df: pd.DataFrame) -> str:
    linhas = [cabecalho_secao(5, "Alertas e Anomalias"), ""]

    limites = {
        "CPU_Temp_C":    ("Temperatura CPU",   None, 85,  "C",    "acima do limite de seguranca"),
        "GPU_Temp_C":    ("Temperatura GPU",   None, 80,  "C",    "acima do limite de seguranca"),
        "RAM_Pct":       ("Uso de RAM",        None, 90,  "%",    "de uso critico de memoria"),
        "Power_Total_W": ("Potencia Total",    None, 120, "W",    "consumo elevado"),
        "Net_Recv_Mbps": ("Rede Recebida",     None, 50,  "Mbps", "trafego intenso"),
    }

    alertas_criticos = []
    status_ok = []

    for col, (nome, lo, hi, unid, desc) in limites.items():
        if col not in df.columns: continue
        s = pd.to_numeric(df[col], errors="coerce").dropna()
        if s.empty: continue

        n_total = len(s)
        n_acima = int((s > hi).sum()) if hi is not None else 0
        pct     = n_acima / n_total * 100

        if n_acima > 0:
            viol = s[s > hi]
            alertas_criticos.append((
                pct,
                f"  [!] {nome:<24}  {n_acima:>6} leituras em violacao  ({pct:>5.1f}% do tempo)\n"
                f"       Limite: {hi} {unid}  |  Descricao: {desc}\n"
                f"       Maximo registrado: {num(float(s.max()), 2)} {unid}"
                f"   |  Media nas violacoes: {num(float(viol.mean()), 2)} {unid}"
            ))
        else:
            status_ok.append(
                f"  [OK] {nome:<24}  Maximo: {num(float(s.max()), 2):>10} {unid}"
                f"   (limite: {hi} {unid})"
            )

    if alertas_criticos:
        linhas.append(f"  {len(alertas_criticos)} ALERTA(S) IDENTIFICADO(S):\n")
        for _, msg in sorted(alertas_criticos, reverse=True):
            linhas += [msg, ""]
    else:
        linhas += ["  Nenhum alerta critico detectado.", ""]

    linhas += ["  STATUS DE MONITORAMENTO", "  " + linha("-", W - 4)]
    linhas += status_ok
    linhas += ["", cabecalho_subsecao("Deteccao de Outliers  (metodo IQR)"), ""]

    cols_check = [c for c in df.columns if c not in COLS_IGNORE]
    encontrou  = False
    linhas.append(
        f"  {'Variavel':<28}  {'Outliers':>9}  {'(%)':<8}  Faixa normal (Q1-1,5*IQR  a  Q3+1,5*IQR)"
    )
    linhas.append("  " + linha("-", W - 4))

    for col in cols_check:
        s = pd.to_numeric(df[col], errors="coerce").dropna()
        if len(s) < 10 or s.std() == 0: continue
        q1, q3 = np.percentile(s, [25, 75])
        iqr    = q3 - q1
        fl     = q1 - 1.5 * iqr
        fh     = q3 + 1.5 * iqr
        n_out  = int(((s < fl) | (s > fh)).sum())
        if n_out > 0:
            pct = n_out / len(s) * 100
            linhas.append(
                f"  {col:<28}  {n_out:>9}  {pct:>6.2f}%  "
                f"[{num(fl, 2):>10}  a  {num(fh, 2):>10}]"
            )
            encontrou = True

    if not encontrou:
        linhas.append("  Nenhum outlier significativo detectado.")
    linhas.append("")
    return "\n".join(linhas)


# ==============================================================================
# BLOCO 7 – SUMARIO EXECUTIVO
# ==============================================================================

def bloco_sumario(df: pd.DataFrame, periodo: str,
                  data_ini: date, data_fim: date) -> str:
    linhas = [cabecalho_secao(6, "Sumario Executivo"), ""]

    metricas = [
        ("CPU_Pct",        "Uso CPU",       "%"),
        ("CPU_Temp_C",     "Temperatura CPU","C"),
        ("RAM_Pct",        "Uso RAM",        "%"),
        ("RAM_UsedGB",     "RAM Utilizada",  "GB"),
        ("Power_Total_W",  "Potencia Total", "W"),
        ("GPU_Temp_C",     "Temperatura GPU","C"),
        ("Net_Recv_Mbps",  "Rede Recebida",  "Mbps"),
        ("Disk1_PctUsed",  "Disco C: Uso",   "%"),
        ("Process_Count",  "Processos",      ""),
        ("Thread_Count",   "Threads",        ""),
    ]

    linhas += [
        f"  {'Metrica':<24}  {'Unid':>5}  {'Media':>10}  {'Minimo':>10}"
        f"  {'Maximo':>10}  {'Desvio P.':>10}  {'CV (%)':>8}",
        "  " + linha("=", W - 4),
    ]

    for col, label, unid in metricas:
        if col not in df.columns: continue
        s = pd.to_numeric(df[col], errors="coerce").dropna()
        if s.empty: continue
        std = float(s.std(ddof=1)) if len(s) > 1 else 0.0
        mean= float(s.mean())
        cv  = (std / mean * 100) if mean != 0 else 0.0
        linhas.append(
            f"  {label:<24}  {unid:>5}  {num(mean, 2):>10}  {num(float(s.min()), 2):>10}"
            f"  {num(float(s.max()), 2):>10}  {num(std, 2):>10}  {num(cv, 1):>8}"
        )

    linhas += ["  " + linha("=", W - 4), ""]

    # Diagnostico automatico
    linhas += [cabecalho_subsecao("Diagnostico Automatico do Sistema"), ""]

    diags = []
    checks = [
        ("CPU_Pct",    "CPU",  95,  "com utilizacao critica de CPU (acima de 95%)."),
        ("CPU_Temp_C", "CPU",  80,  "com temperatura de CPU elevada (acima de 80 C)."),
        ("RAM_Pct",    "RAM",  85,  "com uso de memoria acima de 85%."),
        ("GPU_Temp_C", "GPU",  75,  "com temperatura de GPU acima de 75 C."),
        ("Power_Total_W","Energia",100,"com consumo de energia acima de 100 W."),
    ]
    for col, comp, lim, msg in checks:
        if col not in df.columns: continue
        s = pd.to_numeric(df[col], errors="coerce").dropna()
        if s.empty: continue
        pct = (s > lim).mean() * 100
        if pct > 5:
            diags.append(f"  [!] {pct:>5.1f}% do periodo {msg}")

    if not diags:
        diags.append("  [OK] Sistema operando dentro dos parametros normais durante todo o periodo.")
    linhas += diags
    linhas.append("")
    return "\n".join(linhas)


# ==============================================================================
# RODAPE
# ==============================================================================

def bloco_rodape(periodo: str) -> str:
    gerado = datetime.now().strftime("%d/%m/%Y   %H:%M:%S")
    return "\n".join([
        "",
        linha("="),
        f"  Relatorio {periodo.upper():<12}  |  Gerado automaticamente em: {gerado}",
        linha("="),
        "",
    ])


# ==============================================================================
# MONTAGEM FINAL
# ==============================================================================

def gerar_relatorio(df: pd.DataFrame, periodo: str, data_ini: date,
                    data_fim: date, n_arquivos: int) -> str:
    n_dias = (data_fim - data_ini).days + 1
    n_reg  = len(df)
    cols   = colunas_validas(df)

    return "\n".join([
        bloco_cabecalho(periodo, data_ini, data_fim, n_reg, n_dias, n_arquivos),
        bloco_visao_geral(df, cols),
        bloco_estatisticas(df, cols),
        bloco_correlacao(df, cols),
        bloco_temporal(df),
        bloco_alertas(df),
        bloco_sumario(df, periodo, data_ini, data_fim),
        bloco_rodape(periodo),
    ])


# ==============================================================================
# PERSISTENCIA
# ==============================================================================

def salvar_relatorio(conteudo: str, periodo: str, data_ref: date) -> str:
    data_str = data_ref.strftime("%d-%m-%Y")
    pasta    = Path(OUTPUT_BASE) / data_str
    pasta.mkdir(parents=True, exist_ok=True)
    nome     = f"relatorio_hardware_{periodo}_{data_str}.txt"
    caminho  = pasta / nome
    caminho.write_text(conteudo, encoding="utf-8")
    return str(caminho)


# ==============================================================================
# ORQUESTRADOR PRINCIPAL
# ==============================================================================

def main():
    print(f"\n{'=' * 60}")
    print("  GERADOR DE RELATORIOS DE HARDWARE")
    print(f"{'=' * 60}")
    print(f"  Pasta de CSVs : {CSV_FOLDER}")
    print(f"  Saida base    : {OUTPUT_BASE}\n")

    arquivos_por_data = descobrir_arquivos(CSV_FOLDER)
    if not arquivos_por_data:
        print("  [ERRO] Nenhum arquivo CSV encontrado. Verifique a pasta e o padrao.")
        return

    datas        = sorted(arquivos_por_data.keys())
    data_antiga  = datas[0]
    data_recente = datas[-1]
    span_total   = len(datas)   # quantidade de dias com dados disponíveis
    n_total      = sum(len(v) for v in arquivos_por_data.values())

    print(f"  Arquivos encontrados : {n_total}")
    print(f"  Datas disponiveis    : {len(datas)}")
    print(f"  Periodo total        : {data_antiga} -> {data_recente} ({span_total} dia(s) com dados)\n")

    hoje = date.today()

    for periodo, min_dias in PERIODOS.items():

        if periodo == "diario":
            datas_sel = [data_recente]
            data_ini  = data_recente
            data_fim  = data_recente

        elif periodo == "semanal":
            if span_total < min_dias:
                print(f"  [{periodo.upper():<10}] Aguardando ({span_total}/{min_dias} dias com dados)")
                continue
            data_ini  = max(data_recente - timedelta(days=6), data_antiga)
            datas_sel = [d for d in datas if d >= data_ini]
            data_fim  = data_recente

        elif periodo == "mensal":
            if span_total < min_dias:
                print(f"  [{periodo.upper():<10}] Aguardando ({span_total}/{min_dias} dias com dados)")
                continue
            data_ini  = max(data_recente - timedelta(days=29), data_antiga)
            datas_sel = [d for d in datas if d >= data_ini]
            data_fim  = data_recente

        elif periodo == "semestral":
            if span_total < min_dias:
                print(f"  [{periodo.upper():<10}] Aguardando ({span_total}/{min_dias} dias com dados)")
                continue
            data_ini  = max(data_recente - timedelta(days=179), data_antiga)
            datas_sel = [d for d in datas if d >= data_ini]
            data_fim  = data_recente

        elif periodo == "anual":
            if span_total < min_dias:
                print(f"  [{periodo.upper():<10}] Aguardando ({span_total}/{min_dias} dias com dados)")
                continue
            data_ini  = max(data_recente - timedelta(days=364), data_antiga)
            datas_sel = [d for d in datas if d >= data_ini]
            data_fim  = data_recente

        else:
            continue

        n_arqs = sum(len(arquivos_por_data.get(d, [])) for d in datas_sel)
        print(f"  [{periodo.upper():<10}] Carregando {n_arqs} arquivo(s)...", end=" ", flush=True)

        df = carregar_periodo(arquivos_por_data, datas_sel)
        if df.empty:
            print("sem dados.")
            continue
        print(f"{len(df):,} registros.".replace(",", "."))

        conteudo = gerar_relatorio(df, periodo, data_ini, data_fim, n_arqs)
        caminho  = salvar_relatorio(conteudo, periodo, hoje)
        print(f"             -> Salvo em: {caminho}")

    print(f"\n{'=' * 60}")
    print("  Processamento concluido.")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    main()