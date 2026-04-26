"""
Gerador de Relatorios XMRig
==============================
Le arquivos CSV no padrao RelatorioXMRig_dd-mm-aaaa.csv,
agrupa por data e gera relatorios .txt para os periodos:
  - Diario
  - Semanal   (minimo 7 dias com dados)
  - Mensal    (minimo 30 dias com dados)
  - Semestral (minimo 180 dias com dados)
  - Anual     (minimo 365 dias com dados)

Colunas esperadas:
  Timestamp, Hashrate_60s, Hashrate_15m,
  Shares_Accepted, Shares_Total, Uptime_Seconds

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

CSV_FOLDER     = r"C:\Users\USERNAMEs\XMRig-Miner-Analysis\RelatoriosXMRig"
OUTPUT_BASE    = r"C:\Users\USERNAME\XMRig-Miner-Analysis\RelatoriosBackup\XMRig"
CSV_PATTERN    = "RelatorioXMRig_*.csv"
CSV_DATE_REGEX = re.compile(r"RelatorioXMRig_(\d{2}-\d{2}-\d{4})\.csv", re.IGNORECASE)

PERIODOS = {
    "diario":    0,
    "semanal":   7,
    "mensal":    30,
    "semestral": 180,
    "anual":     365,
}

COLS_IGNORE = {"Timestamp", "_date"}

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
    return df[cols].apply(pd.to_numeric, errors="coerce").corr(method="pearson")


def colunas_validas(df: pd.DataFrame) -> list:
    return [c for c in df.columns if c not in COLS_IGNORE
            and not pd.to_numeric(df[c], errors="coerce").dropna().empty]


def colunas_com_variancia(df: pd.DataFrame, cols: list) -> list:
    return [c for c in cols
            if pd.to_numeric(df[c], errors="coerce").dropna().std() > 0]


# ==============================================================================
# PRIMITIVAS DE FORMATACAO
# ==============================================================================

def linha(char: str = "-", largura: int = None) -> str:
    return char * (largura or W)


def num(v: float, decimais: int = 4) -> str:
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
    inner = W - 4
    b = char_borda * W
    cont = f"  {texto.center(inner)}  "
    return f"{b}\n{cont}\n{b}"


def cabecalho_secao(numero: int, titulo: str) -> str:
    rotulo = f"  SECAO {numero}  |  {titulo.upper()}"
    return f"\n\n{'#' * W}\n{rotulo}\n{'#' * W}\n"


def cabecalho_subsecao(titulo: str) -> str:
    return f"\n  {'~' * (W - 4)}\n  {titulo}\n  {'~' * (W - 4)}\n"


def campo(label: str, valor: str, ll: int = 24) -> str:
    return f"  {label:<{ll}} {valor}"


# ==============================================================================
# METRICAS ESPECIFICAS DO XMRIG
# ==============================================================================

def calcular_metricas_xmrig(df: pd.DataFrame) -> dict:
    """Calcula metricas de negocio especificas do minerador XMRig."""
    m = {}

    # Hashrate
    if "Hashrate_60s" in df.columns:
        h = pd.to_numeric(df["Hashrate_60s"], errors="coerce").dropna()
        h_ativo = h[h > 0]
        m["hashrate_medio"]       = float(h.mean()) if not h.empty else 0.0
        m["hashrate_medio_ativo"] = float(h_ativo.mean()) if not h_ativo.empty else 0.0
        m["hashrate_max"]         = float(h.max()) if not h.empty else 0.0
        m["hashrate_min_ativo"]   = float(h_ativo.min()) if not h_ativo.empty else 0.0
        m["pct_tempo_ativo"]      = (len(h_ativo) / len(h) * 100) if not h.empty else 0.0

    # Shares
    if "Shares_Accepted" in df.columns and "Shares_Total" in df.columns:
        acc   = pd.to_numeric(df["Shares_Accepted"], errors="coerce").dropna()
        total = pd.to_numeric(df["Shares_Total"],    errors="coerce").dropna()
        shares_acc_max   = float(acc.max())   if not acc.empty   else 0.0
        shares_total_max = float(total.max()) if not total.empty else 0.0
        rejeitados = shares_total_max - shares_acc_max
        m["shares_aceitos"]   = shares_acc_max
        m["shares_total"]     = shares_total_max
        m["shares_rejeitados"]= rejeitados
        m["taxa_aceitacao"]   = (shares_acc_max / shares_total_max * 100) if shares_total_max > 0 else 0.0

    # Uptime
    if "Uptime_Seconds" in df.columns:
        up = pd.to_numeric(df["Uptime_Seconds"], errors="coerce").dropna()
        if not up.empty:
            uptime_max = float(up.max())
            m["uptime_segundos"] = uptime_max
            m["uptime_horas"]    = uptime_max / 3600
            m["uptime_minutos"]  = uptime_max / 60

    # Hashrate 15m (media estavel)
    if "Hashrate_15m" in df.columns:
        h15 = pd.to_numeric(df["Hashrate_15m"], errors="coerce").dropna()
        h15_ativo = h15[h15 > 0]
        m["hashrate_15m_medio"] = float(h15_ativo.mean()) if not h15_ativo.empty else 0.0
        m["hashrate_15m_max"]   = float(h15_ativo.max())  if not h15_ativo.empty else 0.0

    return m


def uptime_fmt(segundos: float) -> str:
    """Converte segundos em string legivel hh:mm:ss."""
    s = int(segundos)
    h = s // 3600; s %= 3600
    m = s // 60;   s %= 60
    return f"{h:02d}h {m:02d}m {s:02d}s"


# ==============================================================================
# BLOCO 1 – CABECALHO
# ==============================================================================

def bloco_cabecalho(periodo: str, data_ini: date, data_fim: date,
                    n_registros: int, n_dias: int, n_arquivos: int) -> str:
    titulo = f"RELATORIO DE MINERACAO XMRIG  |  {periodo.upper()}"
    gerado = datetime.now().strftime("%d/%m/%Y   %H:%M:%S")
    return "\n".join([
        "",
        caixa(titulo),
        "",
        campo("Gerado em:",            gerado),
        campo("Periodo coberto:",
              f"{data_ini.strftime('%d/%m/%Y')}  ate  {data_fim.strftime('%d/%m/%Y')}"),
        campo("Duracao:",              f"{n_dias} dia(s) com dados"),
        campo("Arquivos processados:", str(n_arquivos)),
        campo("Total de registros:",   f"{n_registros:,}".replace(",", ".")),
        "",
        linha("="),
        "",
    ])


# ==============================================================================
# BLOCO 2 – VISAO GERAL E METRICAS DE NEGOCIO
# ==============================================================================

def bloco_visao_geral(df: pd.DataFrame, cols: list, mx: dict) -> str:
    linhas = [cabecalho_secao(1, "Visao Geral e Metricas de Mineracao")]

    # Cobertura temporal
    if "Timestamp" in df.columns:
        ts = df["Timestamp"].dropna()
        if not ts.empty:
            dur_h  = (ts.max() - ts.min()).total_seconds() / 3600
            freq_s = ts.sort_values().diff().dt.total_seconds().dropna().median()
            linhas += [
                campo("Inicio da coleta:", ts.min().strftime("%d/%m/%Y  %H:%M:%S")),
                campo("Fim da coleta:",    ts.max().strftime("%d/%m/%Y  %H:%M:%S")),
                campo("Duracao total:",    f"{dur_h:.1f} horas  ({uptime_fmt(dur_h * 3600)})"),
                campo("Freq. amostragem:", f"~{freq_s:.0f} segundos entre leituras"),
                "",
            ]

    # Painel de metricas de mineracao
    linhas += [
        cabecalho_subsecao("Resumo de Desempenho do Minerador"),
        "",
        linha("-", W - 4),
        f"  {'HASHRATE':}",
        linha("-", W - 4),
    ]

    if "hashrate_medio" in mx:
        linhas += [
            campo("  Hashrate medio (geral):", f"{num(mx['hashrate_medio'], 2)} H/s"),
            campo("  Hashrate medio (ativo):", f"{num(mx['hashrate_medio_ativo'], 2)} H/s  "
                  f"(apenas quando minerando)"),
            campo("  Hashrate 15m medio:",     f"{num(mx.get('hashrate_15m_medio', 0), 2)} H/s"),
            campo("  Hashrate maximo:",        f"{num(mx['hashrate_max'], 2)} H/s"),
            campo("  Hashrate minimo (ativo):",f"{num(mx['hashrate_min_ativo'], 2)} H/s"),
            campo("  Tempo ativo minerando:",  f"{num(mx['pct_tempo_ativo'], 1)}% do periodo"),
        ]

    linhas += [
        "",
        linha("-", W - 4),
        f"  SHARES",
        linha("-", W - 4),
    ]

    if "shares_aceitos" in mx:
        linhas += [
            campo("  Shares aceitos:",    f"{int(mx['shares_aceitos']):,}".replace(",", ".")),
            campo("  Shares rejeitados:", f"{int(mx['shares_rejeitados']):,}".replace(",", ".")),
            campo("  Shares total:",      f"{int(mx['shares_total']):,}".replace(",", ".")),
            campo("  Taxa de aceitacao:", f"{num(mx['taxa_aceitacao'], 4)}%"),
        ]

    linhas += [
        "",
        linha("-", W - 4),
        f"  UPTIME",
        linha("-", W - 4),
    ]

    if "uptime_segundos" in mx:
        linhas += [
            campo("  Uptime total:",   uptime_fmt(mx["uptime_segundos"])),
            campo("  Em horas:",       f"{num(mx['uptime_horas'], 2)} h"),
            campo("  Em minutos:",     f"{num(mx['uptime_minutos'], 2)} min"),
        ]

    linhas += ["", linha("-", W - 4), ""]
    return "\n".join(linhas)


# ==============================================================================
# BLOCO 3 – ESTATISTICAS DESCRITIVAS
# ==============================================================================

# Mapeamento de nomes amigaveis e unidades para cada coluna
COL_INFO = {
    "Hashrate_60s":    ("Hashrate 60s",          "H/s"),
    "Hashrate_15m":    ("Hashrate 15m",           "H/s"),
    "Shares_Accepted": ("Shares Aceitos",         "und"),
    "Shares_Total":    ("Shares Total",           "und"),
    "Uptime_Seconds":  ("Uptime",                 "seg"),
}


def bloco_estatisticas(df: pd.DataFrame, cols: list) -> str:
    linhas = [cabecalho_secao(2, "Estatisticas Descritivas por Variavel")]

    for col in cols:
        est = estatisticas_coluna(df[col])
        if not est:
            linhas += [f"  {col}: sem dados validos", ""]
            continue

        nome, unidade = COL_INFO.get(col, (col, ""))
        pct_aus = (est["missing"] / (est["count"] + est["missing"]) * 100
                   if (est["count"] + est["missing"]) > 0 else 0)

        linhas += [
            f"  +{'-' * (W - 4)}+",
            f"  | Variavel : {nome} ({unidade})  [{col}]{'':<{W - 16 - len(nome) - len(unidade) - len(col) - 7}}|",
            f"  | Registros: {est['count']:>7,}   Ausentes: {est['missing']:>5,} ({pct_aus:>4.1f}%){' ' * (W - 57)}|".replace(",", "."),
            f"  +{'=' * (W - 4)}+",
        ]

        L = 41
        def row(label, val, dec=4):
            return f"  {label:<22} {num(val, dec):>14}"

        esq = [
            "  TENDENCIA CENTRAL & PERCENTIS",
            "  " + "-" * L,
            row("Media",         est["mean"],   2),
            row("Mediana",       est["median"], 2),
            row("Minimo",        est["min"],    2),
            row("Maximo",        est["max"],    2),
            row("Amplitude",     est["range"],  2),
            row("P5   ( 5%)",    est["p5"],     2),
            row("Q1   (25%)",    est["q1"],     2),
            row("Q3   (75%)",    est["q3"],     2),
            row("P95  (95%)",    est["p95"],    2),
        ]
        dir_ = [
            "  DISPERSAO & FORMA",
            "  " + "-" * L,
            row("Desvio Padrao",      est["std"],      4),
            row("Variancia",          est["variance"], 4),
            row("Coef. Variacao (%)", est["cv_pct"],   2),
            row("IQR",                est["iqr"],      4),
            row("Assimetria",         est["skewness"], 4),
            row("Curtose",            est["kurtosis"], 4),
        ]

        maxl = max(len(esq), len(dir_))
        while len(esq)  < maxl: esq.append("")
        while len(dir_) < maxl: dir_.append("")
        for a, b in zip(esq, dir_):
            linhas.append(f"  {a:<{L + 6}}  {b}")

        # Histograma
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
                rot = f"[{num(edges[i], 2):>10}  a  {num(edges[i+1], 2):>10}]"
                b_s = barra(counts[i], max_c, largura=28)
                linhas.append(f"  {rot}  {counts[i]:>10}  {b_s}")

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

    pares = []
    for i, c1 in enumerate(cols_v):
        for j, c2 in enumerate(cols_v):
            if j <= i: continue
            val = corr_df.loc[c1, c2]
            if not pd.isna(val):
                pares.append((abs(val), val, c1, c2))
    pares.sort(reverse=True)

    def intens(r):
        a = abs(r)
        if a >= 0.90: return "MUITO FORTE"
        if a >= 0.70: return "FORTE      "
        if a >= 0.50: return "MODERADA   "
        return              "FRACA      "

    def direcao(r): return "(+) positiva" if r > 0 else "(-) negativa"

    linhas += [
        "  Pares com correlacao relevante  (|r| >= 0,50)",
        "  " + linha("-", W - 4),
        f"  {'Variavel A':<28}  {'Variavel B':<28}  {'r':>8}  {'Intensidade':<13}  {'Direcao'}",
        "  " + linha("-", W - 4),
    ]

    enc = False
    for _, val, c1, c2 in pares:
        if abs(val) < 0.50: break
        n1 = COL_INFO.get(c1, (c1, ""))[0]
        n2 = COL_INFO.get(c2, (c2, ""))[0]
        linhas.append(
            f"  {n1:<28}  {n2:<28}  {val:>+8.4f}  {intens(val)}  {direcao(val)}"
        )
        enc = True

    if not enc:
        linhas.append("  Nenhum par com correlacao relevante encontrado.")
    linhas += [f"  {linha('-', W - 4)}", ""]

    # Interpretacao automatica
    linhas += [cabecalho_subsecao("Interpretacao Automatica"), ""]
    insights = []
    for _, val, c1, c2 in pares:
        n1 = COL_INFO.get(c1, (c1, ""))[0]
        n2 = COL_INFO.get(c2, (c2, ""))[0]
        if abs(val) >= 0.90:
            insights.append(
                f"  >> {n1}  <->  {n2}\n"
                f"     Correlacao MUITO FORTE (r = {val:+.4f}): variam quase identicamente."
            )
        elif abs(val) >= 0.70:
            insights.append(
                f"  >> {n1}  <->  {n2}\n"
                f"     Correlacao FORTE (r = {val:+.4f}): forte tendencia de variacao conjunta."
            )
        if len(insights) >= 6: break

    if not insights:
        insights.append("  Nenhuma correlacao forte identificada.")
    linhas += insights
    linhas.append("")

    # Matriz compacta
    cols_rel = []
    for _, val, c1, c2 in pares:
        if abs(val) >= 0.70:
            if c1 not in cols_rel: cols_rel.append(c1)
            if c2 not in cols_rel: cols_rel.append(c2)

    if len(cols_rel) >= 2:
        linhas += [cabecalho_subsecao("Matriz de Correlacao  (variaveis com |r| >= 0,70)"), ""]
        cw = 16
        abrev = {c: COL_INFO.get(c, (c, ""))[0][:cw - 1] for c in cols_rel}
        linhas.append("  " + " " * 28 + "".join(f"{abrev[c]:>{cw}}" for c in cols_rel))
        linhas.append("  " + linha("-", W - 4))
        for row in cols_rel:
            lr = f"  {COL_INFO.get(row, (row,''))[0]:<28}"
            for col in cols_rel:
                v = corr_df.loc[row, col]
                lr += f"{'  N/A':>{cw}}" if pd.isna(v) else f"{v:>{cw}.4f}"
            linhas.append(lr)
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
        ("Hashrate_60s",    "Hashrate 60s (H/s)",    None),
        ("Hashrate_15m",    "Hashrate 15m (H/s)",    None),
        ("Shares_Accepted", "Shares Aceitos",         None),
    ]

    for col, label, ref in metricas:
        if col not in df2.columns: continue
        sub = df2[["hora", col]].copy()
        sub[col] = pd.to_numeric(sub[col], errors="coerce")
        sub = sub.dropna()
        if sub.empty: continue

        g       = sub.groupby("hora")[col]
        medias  = g.mean()
        maximos = g.max()
        minimos = g.min()
        mx_ref  = ref if ref is not None else (float(medias.max()) or 1.0)

        linhas += [
            f"  {label}",
            f"  {'Hora':>5}  {'Media':>12}  {'Minimo':>12}  {'Maximo':>12}  Grafico (proporcional a media)",
            "  " + linha("-", W - 4),
        ]
        for h in sorted(medias.index):
            med = medias[h]; mn = minimos[h]; mx = maximos[h]
            b_  = barra(med, mx_ref, largura=28, char_cheio="=", char_vazio=" ")
            linhas.append(
                f"  {h:02d}h    {num(med, 2):>12}  {num(mn, 2):>12}  {num(mx, 2):>12}  |{b_}|"
            )
        linhas.append("")

    # Evolucao do hashrate ao longo do tempo (por intervalos de 15 min)
    linhas += [cabecalho_subsecao("Evolucao do Hashrate ao Longo da Sessao"), ""]
    if "Hashrate_60s" in df2.columns and "Timestamp" in df2.columns:
        df3 = df2[["Timestamp", "Hashrate_60s"]].copy()
        df3["Hashrate_60s"] = pd.to_numeric(df3["Hashrate_60s"], errors="coerce")
        df3 = df3.dropna()
        df3 = df3.set_index("Timestamp").resample("15min")["Hashrate_60s"]
        medias_15 = df3.mean().dropna()
        mx_h = float(medias_15.max()) if not medias_15.empty else 1.0

        linhas += [
            f"  {'Horario':<20}  {'Media H/s':>12}  Grafico",
            "  " + linha("-", W - 4),
        ]
        for ts, val in medias_15.items():
            b_ = barra(val, mx_h, largura=35, char_cheio="=", char_vazio=" ")
            linhas.append(f"  {ts.strftime('%d/%m %H:%M'):<20}  {num(val, 2):>12}  |{b_}|")
        linhas.append("")

    # Tendencia diaria (multiplos dias)
    if "_date" in df2.columns:
        datas_unicas = sorted(df2["_date"].dropna().unique())
        if len(datas_unicas) > 1:
            linhas += [
                cabecalho_subsecao("Tendencia Diaria"), "",
                f"  {'Data':<14}  {'H60s Med':>12}  {'H15m Med':>12}  {'Shares':>10}  {'Uptime (h)':>12}",
                "  " + linha("-", W - 4),
            ]
            for d in datas_unicas:
                sub_d = df2[df2["_date"] == d]
                vals = []
                for c in ["Hashrate_60s", "Hashrate_15m"]:
                    s = pd.to_numeric(sub_d.get(c, pd.Series()), errors="coerce").dropna()
                    s = s[s > 0]
                    vals.append(f"{s.mean():>12.2f}" if not s.empty else f"{'N/A':>12}")
                # shares e uptime (max do dia)
                for c in ["Shares_Accepted", "Uptime_Seconds"]:
                    s = pd.to_numeric(sub_d.get(c, pd.Series()), errors="coerce").dropna()
                    if c == "Uptime_Seconds":
                        vals.append(f"{s.max()/3600:>12.2f}" if not s.empty else f"{'N/A':>12}")
                    else:
                        vals.append(f"{int(s.max()):>10}" if not s.empty else f"{'N/A':>10}")
                linhas.append(f"  {str(d):<14}  {'  '.join(vals)}")
            linhas.append("")

    return "\n".join(linhas)


# ==============================================================================
# BLOCO 6 – ALERTAS E ANOMALIAS
# ==============================================================================

def bloco_alertas(df: pd.DataFrame, mx: dict) -> str:
    linhas = [cabecalho_secao(5, "Alertas e Anomalias"), ""]

    alertas_c = []
    ok_l      = []

    # Hashrate caiu abaixo de 80% da media ativa
    if "Hashrate_60s" in df.columns and mx.get("hashrate_medio_ativo", 0) > 0:
        h = pd.to_numeric(df["Hashrate_60s"], errors="coerce").dropna()
        h_ativo = h[h > 0]
        limiar  = mx["hashrate_medio_ativo"] * 0.80
        n_baixo = int((h_ativo < limiar).sum())
        pct     = n_baixo / len(h_ativo) * 100 if len(h_ativo) > 0 else 0
        if n_baixo > 0:
            alertas_c.append((
                pct,
                f"  [!] Hashrate baixo               {n_baixo:>6} leituras abaixo de 80% da media ativa ({pct:.1f}%)\n"
                f"       Limiar: {num(limiar, 2)} H/s  (80% de {num(mx['hashrate_medio_ativo'], 2)} H/s)"
            ))
        else:
            ok_l.append(f"  [OK] Hashrate                    Sem quedas significativas abaixo da media")

    # Taxa de aceitacao de shares
    if mx.get("taxa_aceitacao", 100) < 99.0 and mx.get("shares_total", 0) > 0:
        alertas_c.append((
            100 - mx["taxa_aceitacao"],
            f"  [!] Shares rejeitados            {int(mx['shares_rejeitados'])} shares rejeitados\n"
            f"       Taxa de aceitacao: {num(mx['taxa_aceitacao'], 4)}%  (ideal: >= 99%)"
        ))
    elif mx.get("shares_total", 0) > 0:
        ok_l.append(f"  [OK] Taxa de aceitacao           {num(mx['taxa_aceitacao'], 4)}%  (excelente)")

    # Tempo sem mineracao
    if "Hashrate_60s" in df.columns:
        h = pd.to_numeric(df["Hashrate_60s"], errors="coerce").dropna()
        pct_inativo = ((h == 0).sum() / len(h) * 100) if len(h) > 0 else 0
        if pct_inativo > 5:
            alertas_c.append((
                pct_inativo,
                f"  [!] Minerador inativo            {pct_inativo:.1f}% do tempo com hashrate = 0\n"
                f"       Pode indicar inicializacao, quedas ou interrupcoes."
            ))
        else:
            ok_l.append(f"  [OK] Disponibilidade             {100 - pct_inativo:.1f}% do tempo com hashrate ativo")

    if alertas_c:
        linhas.append(f"  {len(alertas_c)} ALERTA(S) IDENTIFICADO(S):\n")
        for _, msg in sorted(alertas_c, reverse=True):
            linhas += [msg, ""]
    else:
        linhas += ["  Nenhum alerta identificado. Minerador operando normalmente.", ""]

    linhas += ["  STATUS GERAL", "  " + linha("-", W - 4)]
    linhas += ok_l

    # Outliers via IQR
    linhas += ["", cabecalho_subsecao("Deteccao de Outliers  (metodo IQR)"), ""]
    linhas.append(
        f"  {'Variavel':<28}  {'Outliers':>9}  {'(%)':>8}  Faixa normal"
    )
    linhas.append("  " + linha("-", W - 4))
    enc = False
    for col in [c for c in df.columns if c not in COLS_IGNORE]:
        s = pd.to_numeric(df[col], errors="coerce").dropna()
        if len(s) < 10 or s.std() == 0: continue
        q1, q3 = np.percentile(s, [25, 75])
        iqr = q3 - q1; fl = q1 - 1.5 * iqr; fh = q3 + 1.5 * iqr
        n_out = int(((s < fl) | (s > fh)).sum())
        if n_out > 0:
            pct = n_out / len(s) * 100
            nome = COL_INFO.get(col, (col, ""))[0]
            linhas.append(
                f"  {nome:<28}  {n_out:>9}  {pct:>7.2f}%  "
                f"[{num(fl, 2):>10}  a  {num(fh, 2):>10}]"
            )
            enc = True
    if not enc:
        linhas.append("  Nenhum outlier significativo detectado.")
    linhas.append("")
    return "\n".join(linhas)


# ==============================================================================
# BLOCO 7 – SUMARIO EXECUTIVO
# ==============================================================================

def bloco_sumario(df: pd.DataFrame, mx: dict, periodo: str,
                  data_ini: date, data_fim: date) -> str:
    linhas = [cabecalho_secao(6, "Sumario Executivo"), ""]

    # Tabela de metricas
    cols_tab = [
        ("Hashrate_60s",    "Hashrate 60s",   "H/s"),
        ("Hashrate_15m",    "Hashrate 15m",   "H/s"),
        ("Shares_Accepted", "Shares Aceitos", "und"),
        ("Shares_Total",    "Shares Total",   "und"),
        ("Uptime_Seconds",  "Uptime",         "seg"),
    ]

    linhas += [
        f"  {'Metrica':<24}  {'Unid':>5}  {'Media':>12}  {'Minimo':>12}"
        f"  {'Maximo':>12}  {'Desvio P.':>12}",
        "  " + linha("=", W - 4),
    ]
    for col, label, unid in cols_tab:
        if col not in df.columns: continue
        s = pd.to_numeric(df[col], errors="coerce").dropna()
        if s.empty: continue
        std = float(s.std(ddof=1)) if len(s) > 1 else 0.0
        linhas.append(
            f"  {label:<24}  {unid:>5}  {num(float(s.mean()), 2):>12}"
            f"  {num(float(s.min()), 2):>12}  {num(float(s.max()), 2):>12}"
            f"  {num(std, 2):>12}"
        )
    linhas += ["  " + linha("=", W - 4), ""]

    # Painel de metricas-chave de mineracao
    linhas += [
        cabecalho_subsecao("Indicadores-Chave de Desempenho (KPIs)"), "",
        linha("-", W - 4),
    ]
    kpis = []
    if "hashrate_medio_ativo" in mx:
        kpis += [
            campo("  Hashrate medio ativo:", f"{num(mx['hashrate_medio_ativo'], 2)} H/s"),
            campo("  Hashrate 15m medio:",   f"{num(mx.get('hashrate_15m_medio', 0), 2)} H/s"),
            campo("  Hashrate maximo:",      f"{num(mx['hashrate_max'], 2)} H/s"),
            campo("  Tempo minerando:",      f"{num(mx['pct_tempo_ativo'], 2)}% do periodo"),
        ]
    if "shares_aceitos" in mx:
        kpis += [
            campo("  Shares aceitos:",       f"{int(mx['shares_aceitos']):,}".replace(",", ".")),
            campo("  Taxa de aceitacao:",    f"{num(mx['taxa_aceitacao'], 4)}%"),
        ]
    if "uptime_segundos" in mx:
        kpis += [
            campo("  Uptime total:",         uptime_fmt(mx["uptime_segundos"])),
        ]
    linhas += kpis
    linhas += [linha("-", W - 4), ""]

    # Diagnostico
    linhas += [cabecalho_subsecao("Diagnostico Automatico"), ""]
    diags = []
    if mx.get("pct_tempo_ativo", 100) < 95:
        diags.append(f"  [!] Minerador ficou inativo por {100 - mx['pct_tempo_ativo']:.1f}% do periodo.")
    if mx.get("taxa_aceitacao", 100) < 99 and mx.get("shares_total", 0) > 0:
        diags.append(f"  [!] Taxa de aceitacao abaixo do ideal: {num(mx['taxa_aceitacao'], 4)}%.")
    if not diags:
        diags.append("  [OK] Minerador operando dentro dos parametros esperados.")
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
    n_dias = len(df["_date"].dropna().unique()) if "_date" in df.columns else 1
    n_reg  = len(df)
    cols   = colunas_validas(df)
    mx     = calcular_metricas_xmrig(df)

    return "\n".join([
        bloco_cabecalho(periodo, data_ini, data_fim, n_reg, n_dias, n_arquivos),
        bloco_visao_geral(df, cols, mx),
        bloco_estatisticas(df, cols),
        bloco_correlacao(df, cols),
        bloco_temporal(df),
        bloco_alertas(df, mx),
        bloco_sumario(df, mx, periodo, data_ini, data_fim),
        bloco_rodape(periodo),
    ])


# ==============================================================================
# PERSISTENCIA
# ==============================================================================

def salvar_relatorio(conteudo: str, periodo: str, data_ref: date) -> str:
    data_str = data_ref.strftime("%d-%m-%Y")
    pasta    = Path(OUTPUT_BASE) / data_str
    pasta.mkdir(parents=True, exist_ok=True)
    nome     = f"relatorio_xmrig_{periodo}_{data_str}.txt"
    caminho  = pasta / nome
    caminho.write_text(conteudo, encoding="utf-8")
    return str(caminho)


# ==============================================================================
# ORQUESTRADOR PRINCIPAL
# ==============================================================================

def main():
    print(f"\n{'=' * 60}")
    print("  GERADOR DE RELATORIOS XMRIG")
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
    span_total   = len(datas)   # quantidade de dias com dados disponiveis
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