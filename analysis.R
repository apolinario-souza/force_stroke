# =============================================================================
# Análise Longitudinal — Stroke Force Control
# Perguntas: (1) fmax aumentou ao longo das sessões?
#            (2) RMSE entre meta e produzido diminuiu com as sessões?
# =============================================================================

# --- Pacotes -----------------------------------------------------------------
library(dplyr)
library(tidyr)
library(purrr)
library(readr)
library(stringr)
library(ggplot2)
library(scales)
library(lme4)
library(lmerTest)
library(lubridate)
library(zoo)

# --- Constantes --------------------------------------------------------------
# Resolve o diretório do script de forma compatível com Rscript e RStudio
get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_flag <- args[startsWith(args, "--file=")]
  if (length(file_flag) > 0) {
    return(dirname(normalizePath(sub("--file=", "", file_flag[1]))))
  }
  tryCatch(dirname(normalizePath(sys.frame(1)$ofile)), error = function(e) getwd())
}
DATA_DIR      <- file.path(get_script_dir(), "dados")
ADC_TO_KG     <- 20 / 1024  # fator de conversão unidades ADC → kg
TRIM_SEC      <- 1.0         # segundos a remover no início e fim de cada tentativa (F6)
MIN_PEAK_ADC  <- 80          # pico suavizado mínimo para fmax válido: 80 ADC ≈ 1.6 kg (F3)
SMOOTH_K      <- 40          # janela de suavização fmax: 40 amostras = 200 ms a 200 Hz (F2)

# =============================================================================
# ETAPA 1 — INGESTÃO E PARSING
# =============================================================================

# Mapeamento de variantes de nome de pasta → canônico
movement_map <- c(
  "extensao_cotovelo"    = "extensao_cotovelo",
  "Extensão Cotovelo"    = "extensao_cotovelo",
  "Extensão de Cotovelo" = "extensao_cotovelo",
  "extensao_punho"       = "extensao_punho",
  "Extensão Punho"       = "extensao_punho",
  "Extensão de Punho"    = "extensao_punho",
  "flexao_ombro"         = "flexao_ombro",
  "Flexão Ombro"         = "flexao_ombro",
  "Flexão de Ombro"      = "flexao_ombro",
  "flexao_punho"         = "flexao_punho",
  "Flexão Punho"         = "flexao_punho",
  "Flexão de Punho"      = "flexao_punho"
)

# Descobre todos os arquivos .xls e classifica cada um
discover_files <- function(data_dir) {
  # Encontra todas as pastas de participante
  participant_dirs <- list.dirs(data_dir, recursive = FALSE)

  map_dfr(participant_dirs, function(pdir) {
    participante <- as.integer(str_extract(basename(pdir), "\\d+"))
    mov_dirs <- list.dirs(pdir, recursive = FALSE)

    map_dfr(mov_dirs, function(mdir) {
      mov_raw  <- basename(mdir)
      movimento <- movement_map[mov_raw]
      if (is.na(movimento)) return(NULL)  # pasta desconhecida — ignorar

      xls_files <- list.files(mdir, pattern = "\\.xls$", full.names = TRUE)
      if (length(xls_files) == 0) return(NULL)

      map_dfr(xls_files, function(f) {
        fname <- tools::file_path_sans_ext(basename(f))

        # F4: exclui arquivos com prefixo "{N}o" (condição/membro diferente)
        if (str_detect(fname, "^\\d+o")) return(NULL)

        # Detecta tipo: fmax ou trial
        is_fmax <- str_detect(fname, "_fmax")

        # Extrai data (DD-MM-YY)
        date_str <- str_extract(fname, "\\d{2}-\\d{2}-\\d{2}")
        data_arquivo <- dmy(paste0(
          str_sub(date_str, 1, 2), "-",
          str_sub(date_str, 4, 5), "-20",
          str_sub(date_str, 7, 8)
        ))
        # Arquivos gravados novamente (substituindo arquivo vazio/NaN de 2025)
        # ficaram com ano 2026 no nome — normaliza para 2025
        if (!is.na(data_arquivo) && year(data_arquivo) == 2026) {
          year(data_arquivo) <- 2025
        }

        if (is_fmax) {
          rep_num <- str_extract(fname, "(?<=_fmax_)\\d+")
          rep_num <- if (is.na(rep_num)) 0L else as.integer(rep_num)
          tibble(
            participante  = participante,
            movimento     = movimento,
            data          = data_arquivo,
            tipo          = "fmax",
            tentativa_num = NA_integer_,
            rep_fmax      = rep_num,
            caminho       = f
          )
        } else {
          # Remove prefixo extra de participante e movimento para chegar ao número
          # Padrão: {P#}[f?]{mov}{trial_num}_{date}.xls
          trial_num_str <- str_extract(fname, "(?<=[a-z_])(\\d+)(?=_\\d{2}-\\d{2}-\\d{2})")
          tibble(
            participante  = participante,
            movimento     = movimento,
            data          = data_arquivo,
            tipo          = "trial",
            tentativa_num = as.integer(trial_num_str),
            rep_fmax      = NA_integer_,
            caminho       = f
          )
        }
      })
    })
  })
}

message("Descobrindo arquivos...")
all_files <- discover_files(DATA_DIR)
message(sprintf("  %d arquivos encontrados (%d fmax, %d trials)",
                nrow(all_files),
                sum(all_files$tipo == "fmax"),
                sum(all_files$tipo == "trial")))

# =============================================================================
# ETAPA 2 — PROCESSAMENTO DA FMAX
# =============================================================================

read_fmax_file <- function(path) {
  # Colunas: [vazio] | tempo | força_ADC
  tryCatch({
    df <- read_tsv(path,
                   col_names = FALSE,
                   locale    = locale(decimal_mark = ","),
                   col_types = cols(.default = col_double()),
                   show_col_types = FALSE)
    df <- df[!is.na(df[[3]]), ]  # remove última linha incompleta
    if (nrow(df) < 2) return(NA_real_)
    df <- df[-1, ]               # F1: remove linha 0 (artefato de inicialização)
    force <- df[[3]]
    # F2: pico sustentado via média deslizante de 200 ms (40 amostras)
    k <- min(SMOOTH_K, floor(length(force) / 2))
    smoothed <- rollmean(force, k = k, fill = NA)
    pico <- max(smoothed, na.rm = TRUE)
    # F3: descarta se pico < 80 ADC — gap limpo entre ruído (≤47) e contração real (≥81)
    if (pico < MIN_PEAK_ADC) return(NA_real_)
    pico
  }, error = function(e) NA_real_)
}

message("Processando fmax...")
fmax_files <- filter(all_files, tipo == "fmax")

fmax_raw <- fmax_files %>%
  mutate(pico_adc = map_dbl(caminho, read_fmax_file))

# Seleciona o maior pico válido por (participante, movimento, data)
fmax_sessao <- fmax_raw %>%
  filter(!is.na(pico_adc), pico_adc > 10) %>%  # descarta tentativas inválidas (~zero)
  group_by(participante, movimento, data) %>%
  summarise(fmax_adc = max(pico_adc), .groups = "drop") %>%
  mutate(fmax_kg = fmax_adc * ADC_TO_KG)

# Numera sessões por participante + movimento (ordem cronológica)
fmax_sessao <- fmax_sessao %>%
  arrange(participante, movimento, data) %>%
  group_by(participante, movimento) %>%
  mutate(sessao_num = row_number()) %>%
  ungroup()

message(sprintf("  fmax extraída para %d combinações participante × movimento × sessão",
                nrow(fmax_sessao)))

# Calcula delta fmax em relação à primeira sessão e detecta outliers intra-participante
fmax_sessao <- fmax_sessao %>%
  group_by(participante, movimento) %>%
  mutate(
    fmax_kg_baseline = fmax_kg[sessao_num == 1],
    delta_fmax_kg    = fmax_kg - fmax_kg_baseline,
    fmax_mediana     = median(fmax_kg),
    # Sessão suspeita: fmax < 20% da mediana do próprio participante × movimento
    fmax_suspeita    = fmax_kg < 0.20 * fmax_mediana
  ) %>%
  ungroup()

# =============================================================================
# ETAPA 3 — PROCESSAMENTO DAS TENTATIVAS (RMSE)
# =============================================================================

read_trial_rmse <- function(path, trim_sec = TRIM_SEC) {
  # Arquivo: [tab vazio] | tempo | meta% | produzido% | força_bruta
  # Colunas:     1           2       3          4             5
  tryCatch({
    df <- read_tsv(path,
                   col_names = FALSE,
                   locale    = locale(decimal_mark = ","),
                   col_types = cols(.default = col_double()),
                   show_col_types = FALSE)
    # Remove última linha incompleta (sem meta% ou produzido%)
    df <- df[!is.na(df[[3]]) & !is.na(df[[4]]), ]
    if (nrow(df) < 2) return(NA_real_)
    df <- df[-1, ]  # F5: remove linha 0 (artefato de inicialização)

    # F7: detecta e remove plateau terminal congelado
    # (últimas N linhas com força_bruta idêntica = recording parou com força sustentada)
    raw <- df[[5]]
    changes <- which(abs(diff(raw)) > 1)
    if (length(changes) > 0) {
      last_change <- max(changes)
      df <- df[seq_len(last_change + 1), ]
    }

    # F6: trim inicio e fim (1s) usando coluna de tempo (col 2)
    t_max <- max(df[[2]], na.rm = TRUE)
    df <- df[df[[2]] >= trim_sec & df[[2]] <= t_max - trim_sec, ]
    if (nrow(df) < 10) return(NA_real_)

    meta   <- df[[3]]   # meta em % da fmax
    produz <- df[[4]]   # produzido em % da fmax

    sqrt(mean((meta - produz)^2, na.rm = TRUE))
  }, error = function(e) NA_real_)
}

message("Calculando RMSE das tentativas...")
trial_files <- filter(all_files, tipo == "trial")

trial_rmse <- trial_files %>%
  mutate(rmse = map_dbl(caminho, read_trial_rmse))

# F9 removido: sessões sem fmax válido são mantidas no RMSE

# Agrega por sessão
rmse_sessao <- trial_rmse %>%
  filter(!is.na(rmse)) %>%
  group_by(participante, movimento, data) %>%
  summarise(
    rmse_medio    = mean(rmse),
    rmse_sd       = sd(rmse),
    n_tentativas  = n(),
    .groups       = "drop"
  )

# Numera sessões e calcula delta RMSE em relação à sessão 1
rmse_sessao <- rmse_sessao %>%
  arrange(participante, movimento, data) %>%
  group_by(participante, movimento) %>%
  mutate(
    sessao_num       = row_number(),
    rmse_baseline    = rmse_medio[sessao_num == 1],
    delta_rmse       = rmse_medio - rmse_baseline
  ) %>%
  ungroup()

message(sprintf("  RMSE calculado para %d combinações participante × movimento × sessão",
                nrow(rmse_sessao)))

# =============================================================================
# ETAPA 4 — ANÁLISE ESTATÍSTICA
# =============================================================================

movimentos <- unique(fmax_sessao$movimento)

# --- 4.1 delta_fmax ~ sessão (modelo por movimento) --------------------------
# Usa delta em relação à sessão 1 para remover heterogeneidade de baseline
message("\n=== MODELOS delta_fmax_kg ~ sessao_num ===")
fmax_models <- map(movimentos, function(mov) {
  d <- filter(fmax_sessao, movimento == mov, sessao_num > 1)  # sessao 1 = 0 por definição
  if (n_distinct(d$participante) < 3) {
    message(sprintf("  [%s] dados insuficientes, pulando", mov))
    return(NULL)
  }
  m <- tryCatch(
    lmer(delta_fmax_kg ~ sessao_num + (1 + sessao_num | participante), data = d,
         REML = FALSE,
         control = lmerControl(optimizer = "bobyqa")),
    error = function(e) {
      message(sprintf("  [%s] slope aleatório singular, usando só intercept: %s", mov, e$message))
      lmer(delta_fmax_kg ~ sessao_num + (1 | participante), data = d, REML = FALSE)
    }
  )
  message(sprintf("\n--- %s ---", mov))
  print(summary(m)$coefficients)
  m
})
names(fmax_models) <- movimentos

# --- 4.2 delta_rmse ~ sessão (modelo por movimento) --------------------------
# Usa delta em relação à sessão 1 para remover heterogeneidade de baseline
message("\n=== MODELOS delta_rmse ~ sessao_num ===")
rmse_models <- map(movimentos, function(mov) {
  d <- filter(rmse_sessao, movimento == mov, sessao_num > 1)  # sessão 1 = 0 por definição
  if (n_distinct(d$participante) < 3) {
    message(sprintf("  [%s] dados insuficientes, pulando", mov))
    return(NULL)
  }
  m <- tryCatch(
    lmer(delta_rmse ~ sessao_num + (1 + sessao_num | participante), data = d,
         REML = FALSE,
         control = lmerControl(optimizer = "bobyqa")),
    error = function(e) {
      message(sprintf("  [%s] slope aleatório singular, usando só intercept: %s", mov, e$message))
      lmer(delta_rmse ~ sessao_num + (1 | participante), data = d, REML = FALSE)
    }
  )
  message(sprintf("\n--- %s ---", mov))
  print(summary(m)$coefficients)
  m
})
names(rmse_models) <- movimentos

# --- 4.3 Tabela resumo dos modelos -------------------------------------------
extract_coefs <- function(models, var_resp) {
  map_dfr(names(models), function(mov) {
    m <- models[[mov]]
    if (is.null(m)) return(NULL)
    coefs <- summary(m)$coefficients
    if (!"sessao_num" %in% rownames(coefs)) return(NULL)
    tibble(
      variavel_resposta = var_resp,
      movimento         = mov,
      beta              = coefs["sessao_num", "Estimate"],
      se                = coefs["sessao_num", "Std. Error"],
      t_value           = coefs["sessao_num", "t value"],
      p_value           = coefs["sessao_num", "Pr(>|t|)"],
      ic_inf            = beta - 1.96 * se,
      ic_sup            = beta + 1.96 * se
    )
  })
}

tabela_modelos <- bind_rows(
  extract_coefs(fmax_models,  "delta_fmax_kg"),
  extract_coefs(rmse_models,  "delta_rmse")
)

message("\n=== TABELA RESUMO DOS MODELOS ===")
print(tabela_modelos, n = Inf)

# =============================================================================
# ETAPA 5 — VISUALIZAÇÕES
# =============================================================================

dir.create("figuras", showWarnings = FALSE)

mov_labels <- c(
  extensao_cotovelo = "Extensão de Cotovelo",
  extensao_punho    = "Extensão de Punho",
  flexao_ombro      = "Flexão de Ombro",
  flexao_punho      = "Flexão de Punho"
)

# --- 5.1 Spaghetti plot — fmax -----------------------------------------------
p_fmax <- ggplot(fmax_sessao,
                 aes(x = sessao_num, y = fmax_kg,
                     group = factor(participante),
                     color = factor(participante))) +
  geom_line(alpha = 0.5) +
  geom_point(size = 1.5, alpha = 0.7) +
  geom_smooth(aes(group = 1), method = "lm", se = TRUE,
              color = "black", linewidth = 1.2) +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels)) +
  scale_x_continuous(breaks = scales::breaks_pretty()) +
  labs(
    title  = "Força Máxima (fmax) ao longo das sessões",
    x      = "Número da sessão",
    y      = "fmax (kg)",
    color  = "Participante"
  ) +
  theme_bw(base_size = 12) +
  theme(legend.position = "bottom")

ggsave("figuras/fmax_sessoes.png", p_fmax, width = 10, height = 7, dpi = 150)
message("Figura salva: figuras/fmax_sessoes.png")

# --- 5.1b Spaghetti plot — delta fmax (mudança em relação à sessão 1) --------
p_delta_fmax <- ggplot(fmax_sessao,
                       aes(x = sessao_num, y = delta_fmax_kg,
                           group = factor(participante),
                           color = factor(participante))) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_line(alpha = 0.5) +
  geom_point(size = 1.5, alpha = 0.7) +
  geom_smooth(aes(group = 1), method = "lm", se = TRUE,
              color = "black", linewidth = 1.2) +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels)) +
  scale_x_continuous(breaks = scales::breaks_pretty()) +
  labs(
    title    = "Mudança na fmax em relação à sessão 1",
    subtitle = "Linha tracejada = sem mudança; acima = ganho de força",
    x        = "Número da sessão",
    y        = "Δ fmax (kg)",
    color    = "Participante"
  ) +
  theme_bw(base_size = 12) +
  theme(legend.position = "bottom")

ggsave("figuras/delta_fmax_sessoes.png", p_delta_fmax, width = 10, height = 7, dpi = 150)
message("Figura salva: figuras/delta_fmax_sessoes.png")

# --- 5.2 Spaghetti plot — RMSE -----------------------------------------------
if (nrow(rmse_sessao) == 0) stop("rmse_sessao está vazio — verificar read_trial_rmse()")

# --- 5.2a RMSE absoluto -------------------------------------------------------
p_rmse <- ggplot(rmse_sessao,
                 aes(x = sessao_num, y = rmse_medio,
                     group = factor(participante),
                     color = factor(participante))) +
  geom_line(alpha = 0.5) +
  geom_point(size = 1.5, alpha = 0.7) +
  geom_smooth(aes(group = 1), method = "lm", se = TRUE,
              color = "black", linewidth = 1.2) +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels)) +
  scale_x_continuous(breaks = scales::breaks_pretty()) +
  labs(title = "RMSE médio por sessão ao longo do protocolo",
       x = "Número da sessão", y = "RMSE (% fmax)", color = "Participante") +
  theme_bw(base_size = 12) +
  theme(legend.position = "bottom")

ggsave("figuras/rmse_sessoes.png", p_rmse, width = 10, height = 7, dpi = 150)
message("Figura salva: figuras/rmse_sessoes.png")

# --- 5.2b Delta RMSE (mudança em relação à sessão 1) -------------------------
p_delta_rmse <- ggplot(rmse_sessao,
                       aes(x = sessao_num, y = delta_rmse,
                           group = factor(participante),
                           color = factor(participante))) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_line(alpha = 0.5) +
  geom_point(size = 1.5, alpha = 0.7) +
  geom_smooth(aes(group = 1), method = "lm", se = TRUE,
              color = "black", linewidth = 1.2) +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels)) +
  scale_x_continuous(breaks = scales::breaks_pretty()) +
  labs(
    title    = "Mudança no RMSE em relação à sessão 1",
    subtitle = "Abaixo da linha = melhora no controle; acima = piora",
    x        = "Número da sessão",
    y        = "Δ RMSE (% fmax)",
    color    = "Participante"
  ) +
  theme_bw(base_size = 12) +
  theme(legend.position = "bottom")

ggsave("figuras/delta_rmse_sessoes.png", p_delta_rmse, width = 10, height = 7, dpi = 150)
message("Figura salva: figuras/delta_rmse_sessoes.png")

# --- 5.3 Boxplots por terço do protocolo -------------------------------------
tercil_breaks <- function(df) {
  df %>%
    group_by(participante, movimento) %>%
    mutate(n_sess = max(sessao_num),
           tercio = case_when(
             sessao_num <= n_sess / 3       ~ "1º terço",
             sessao_num <= 2 * n_sess / 3   ~ "2º terço",
             TRUE                            ~ "3º terço"
           )) %>%
    ungroup() %>%
    mutate(tercio = factor(tercio, levels = c("1º terço", "2º terço", "3º terço")))
}

fmax_tercio <- tercil_breaks(fmax_sessao)
rmse_tercio <- tercil_breaks(rmse_sessao)

p_fmax_box <- ggplot(fmax_tercio, aes(x = tercio, y = delta_fmax_kg, fill = tercio)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_boxplot(outlier.shape = 21, alpha = 0.7) +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels)) +
  labs(title = "Δ fmax por terço do protocolo (relativo à sessão 1)",
       x = NULL, y = "Δ fmax (kg)") +
  theme_bw(base_size = 12) +
  theme(legend.position = "none")

ggsave("figuras/fmax_tercio.png", p_fmax_box, width = 10, height = 7, dpi = 150)

p_rmse_box <- ggplot(rmse_tercio, aes(x = tercio, y = delta_rmse, fill = tercio)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_boxplot(outlier.shape = 21, alpha = 0.7) +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels)) +
  labs(title = "Δ RMSE por terço do protocolo (relativo à sessão 1)",
       x = NULL, y = "Δ RMSE (% fmax)") +
  theme_bw(base_size = 12) +
  theme(legend.position = "none")

ggsave("figuras/rmse_tercio.png", p_rmse_box, width = 10, height = 7, dpi = 150)
message("Figuras de boxplot salvas")

# --- 5.4 Scatter fmax × RMSE -------------------------------------------------
dados_combinados <- inner_join(
  fmax_sessao  %>% select(participante, movimento, data, sessao_num, fmax_kg, delta_fmax_kg),
  rmse_sessao  %>% select(participante, movimento, data, rmse_medio, delta_rmse),
  by = c("participante", "movimento", "data")
)

p_scatter <- ggplot(dados_combinados,
                    aes(x = delta_fmax_kg, y = delta_rmse, color = sessao_num)) +
  geom_point(alpha = 0.6, size = 2) +
  geom_smooth(method = "lm", se = FALSE, color = "black", linetype = "dashed") +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels)) +
  scale_color_viridis_c(name = "Sessão") +
  labs(title = "Relação entre Δ fmax e Δ RMSE por sessão",
       x = "Δ fmax (kg, relativo à sessão 1)", y = "Δ RMSE (% fmax, relativo à sessão 1)") +
  theme_bw(base_size = 12)

ggsave("figuras/scatter_fmax_rmse.png", p_scatter, width = 10, height = 7, dpi = 150)
message("Figura scatter salva")

# --- 5.5 Correlação Pearson Δfmax × Δrmse por movimento ---------------------
message("\n=== CORRELAÇÃO Δfmax × Δrmse ===")
cor_resultados <- dados_combinados %>%
  group_by(movimento) %>%
  summarise(
    n       = n(),
    r       = cor(delta_fmax_kg, delta_rmse, use = "complete.obs"),
    p_value = tryCatch(
      cor.test(delta_fmax_kg, delta_rmse, use = "complete.obs")$p.value,
      error = function(e) NA_real_
    ),
    .groups = "drop"
  ) %>%
  mutate(
    ic_inf = tanh(atanh(r) - 1.96 / sqrt(n - 3)),
    ic_sup = tanh(atanh(r) + 1.96 / sqrt(n - 3))
  )

print(cor_resultados)
write.csv(cor_resultados, "correlacao_fmax_rmse.csv", row.names = FALSE)

# =============================================================================
# ETAPA 6 — RELATÓRIO DE QUALIDADE DOS DADOS
# =============================================================================

message("\n=== RELATÓRIO DE QUALIDADE ===")

# 6.1 Sessões por participante × movimento
tab_sessoes <- fmax_sessao %>%
  count(participante, movimento, name = "n_sessoes_fmax") %>%
  full_join(
    rmse_sessao %>% count(participante, movimento, name = "n_sessoes_trial"),
    by = c("participante", "movimento")
  ) %>%
  arrange(participante, movimento)

message("\nSessões por participante × movimento:")
print(tab_sessoes, n = Inf)

# 6.2 Sessões sem fmax válido
sess_sem_fmax <- trial_files %>%
  select(participante, movimento, data) %>%
  distinct() %>%
  anti_join(fmax_sessao %>% select(participante, movimento, data),
            by = c("participante", "movimento", "data"))

if (nrow(sess_sem_fmax) > 0) {
  message(sprintf("\nSessões com trials mas SEM fmax válido (%d):", nrow(sess_sem_fmax)))
  print(sess_sem_fmax)
} else {
  message("\nTodas as sessões com trials têm fmax válido.")
}

# 6.3 Sessões com fmax suspeita (< 20% da mediana do participante × movimento)
fmax_suspeitas <- fmax_sessao %>%
  filter(fmax_suspeita) %>%
  select(participante, movimento, data, sessao_num, fmax_kg, fmax_mediana)

if (nrow(fmax_suspeitas) > 0) {
  message(sprintf("\nSessões com fmax suspeita — < 20%% da mediana individual (%d):", nrow(fmax_suspeitas)))
  print(fmax_suspeitas, n = Inf)
} else {
  message("\nNenhuma fmax suspeita detectada.")
}

# 6.5 Outliers de RMSE (> 3 DP da média do participante × movimento)
rmse_outliers <- trial_rmse %>%
  filter(!is.na(rmse)) %>%
  group_by(participante, movimento) %>%
  mutate(z = (rmse - mean(rmse)) / sd(rmse)) %>%
  filter(abs(z) > 3) %>%
  ungroup() %>%
  select(participante, movimento, data, tentativa_num, rmse, z, caminho)

if (nrow(rmse_outliers) > 0) {
  message(sprintf("\nTentativas com RMSE outlier |z| > 3 (%d):", nrow(rmse_outliers)))
  print(rmse_outliers)
} else {
  message("\nNenhum outlier extremo de RMSE detectado.")
}

# 6.6 Arquivos com ano 2026 (normalizados → 2025 automaticamente)
# Esses arquivos são re-gravações de sessões onde o arquivo 2025 estava vazio/NaN.
# O parsing já normaliza o ano; esta contagem é apenas informativa.
n_arq_2026 <- all_files %>%
  filter(!is.na(data)) %>%
  # Recalcula sem normalização para contar
  mutate(ano_orig = as.integer(str_extract(basename(caminho), "\\d{2}(?=\\.xls)"))) %>%
  filter(ano_orig == 26) %>%
  nrow()
message(sprintf("\nArquivos com '26' no nome (normalizados para 2025): %d", n_arq_2026))

# 6.7 Salva tabelas em CSV
write_csv(fmax_sessao,    "fmax_sessao.csv")
write_csv(rmse_sessao,    "rmse_sessao.csv")
write_csv(tabela_modelos, "resultados_modelos.csv")
write_csv(tab_sessoes,    "qualidade_sessoes.csv")

# =============================================================================
# ETAPA 7 — DOSE-RESPOSTA: QUANTIDADE DE SESSÕES × GANHO/PERDA TOTAL
# =============================================================================
# Por participante × movimento: total de sessões frequentadas e mudança
# da primeira à última sessão. Permite comparar participantes com mais vs.
# menos exposição ao protocolo.

dose_fmax <- fmax_sessao %>%
  group_by(participante, movimento) %>%
  summarise(
    n_sessoes   = max(sessao_num),
    delta_final = delta_fmax_kg[sessao_num == max(sessao_num)],
    .groups     = "drop"
  )

dose_rmse <- rmse_sessao %>%
  group_by(participante, movimento) %>%
  summarise(
    n_sessoes   = max(sessao_num),
    delta_final = delta_rmse[sessao_num == max(sessao_num)],
    .groups     = "drop"
  )

cor_dose <- function(df, varname) {
  df %>%
    group_by(movimento) %>%
    summarise(
      n       = n(),
      r       = cor(n_sessoes, delta_final, use = "complete.obs"),
      p_value = tryCatch(
        cor.test(n_sessoes, delta_final)$p.value,
        error = function(e) NA_real_
      ),
      .groups = "drop"
    ) %>%
    mutate(
      variavel = varname,
      ic_inf   = tanh(atanh(r) - 1.96 / sqrt(n - 3)),
      ic_sup   = tanh(atanh(r) + 1.96 / sqrt(n - 3))
    )
}

cor_dose_fmax <- cor_dose(dose_fmax, "delta_fmax_kg")
cor_dose_rmse <- cor_dose(dose_rmse, "delta_rmse")

message("\n=== CORRELAÇÃO n_sessoes × Δfmax (última sessão) ===")
print(cor_dose_fmax)
message("\n=== CORRELAÇÃO n_sessoes × ΔRMSE (última sessão) ===")
print(cor_dose_rmse)

write_csv(bind_rows(cor_dose_fmax, cor_dose_rmse), "correlacao_dose_resposta.csv")

p_dose_fmax <- ggplot(dose_fmax, aes(x = n_sessoes, y = delta_final)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_smooth(method = "lm", se = TRUE, color = "steelblue") +
  geom_point(size = 3, alpha = 0.8) +
  geom_text(aes(label = participante), vjust = -0.7, size = 3) +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels), scales = "free_y") +
  labs(
    title    = "Dose-resposta: sessões × ganho em fmax",
    subtitle = "Cada ponto = um participante; linha = regressão linear com IC 95%",
    x        = "Número total de sessões",
    y        = "Δ fmax na última sessão (kg)"
  ) +
  theme_bw(base_size = 12)

ggsave("figuras/dose_fmax.png", p_dose_fmax, width = 10, height = 7, dpi = 150)
message("Figura salva: figuras/dose_fmax.png")

p_dose_rmse <- ggplot(dose_rmse, aes(x = n_sessoes, y = delta_final)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50") +
  geom_smooth(method = "lm", se = TRUE, color = "tomato") +
  geom_point(size = 3, alpha = 0.8) +
  geom_text(aes(label = participante), vjust = -0.7, size = 3) +
  facet_wrap(~ movimento, labeller = labeller(movimento = mov_labels), scales = "free_y") +
  labs(
    title    = "Dose-resposta: sessões × ganho em RMSE",
    subtitle = "Cada ponto = um participante; abaixo de zero = melhora no controle",
    x        = "Número total de sessões",
    y        = "Δ RMSE na última sessão (% fmax)"
  ) +
  theme_bw(base_size = 12)

ggsave("figuras/dose_rmse.png", p_dose_rmse, width = 10, height = 7, dpi = 150)
message("Figura salva: figuras/dose_rmse.png")

message("\nAnálise concluída. Arquivos gerados:")
message("  fmax_sessao.csv, rmse_sessao.csv, resultados_modelos.csv, qualidade_sessoes.csv")
message("  correlacao_dose_resposta.csv")
message("  figuras/fmax_sessoes.png, figuras/delta_fmax_sessoes.png, figuras/rmse_sessoes.png")
message("  figuras/fmax_tercio.png, figuras/rmse_tercio.png")
message("  figuras/scatter_fmax_rmse.png")
message("  figuras/dose_fmax.png, figuras/dose_rmse.png")
