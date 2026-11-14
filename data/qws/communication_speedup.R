#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(tidyverse))

# Run from repository root. PPN labels are taken directly from input folders.
pattern <- "^(vanilla|opt|no_sync)_benchmark_+(send_post|send|recv|all)_([0-9]+)\\.dat$"
files <- sort(list.files("qws_data", full.names = TRUE, recursive = TRUE))
files <- files[!str_detect(files, "/(bak|bak_data|backup|archive|archives)/")]
parts <- str_match(basename(files), pattern)
sources <- tibble(source_file = files, prefix = parts[, 2],
                  target = parts[, 3], run = as.integer(parts[, 4]),
                  process_count = as.integer(str_match(dirname(files), "/([0-9]+)_PPN$")[, 2])) |>
  filter(!is.na(target), !is.na(process_count)) |>
  mutate(variant = recode(prefix, opt = "PRISM", no_sync = "PRISM_no_sync",
                          vanilla = "vanilla"),
         extra_underscore = str_detect(basename(source_file), "benchmark__")) |>
  group_by(process_count, variant, target, run) |>
  arrange(extra_underscore, source_file, .by_group = TRUE) |>
  mutate(duplicate = row_number() > 1) |>
  ungroup()
stopifnot(nrow(sources) > 0)
expected_functions <- c(send = "comlib_isend_all_c", recv = "comlib_irecv_all_c",
                        send_post = "comlib_isend_wait_all_c", all = "all")
sources <- sources |>
  mutate(has_timing_block = map_lgl(source_file, function(file) {
    lines <- str_trim(read_lines(file))
    starts <- which(lines == "print timing")
    ends <- which(lines == "end")
    length(starts) == 1 && length(ends) == 1 && starts < ends
  }), reason = case_when(
    duplicate ~ "Duplicate run ID; preferred filename with single underscore",
    !has_timing_block ~ "No complete timing block",
    TRUE ~ NA_character_
  ))
dir.create("results", showWarnings = FALSE)
write_csv(sources |> filter(!is.na(reason)), "results/communication_target_exclusions.csv")
runs <- pmap_dfr(sources |> filter(is.na(reason)) |>
                  select(variant, target, run, source_file, process_count),
                function(variant, target, run, source_file, process_count) {
  lines <- read_lines(source_file)
  inside <- cumsum(str_trim(lines) == "print timing") > cumsum(str_trim(lines) == "end")
  matched <- str_match(lines,
    "^\\s*(\\d+)\\s+(\\S+)\\s+(\\d+)\\s+([0-9.eE+-]+)\\s+([0-9.eE+-]+)\\s*$")
  rows <- tibble(variant, target, run, source_file, process_count, inside,
                 rank = as.integer(matched[, 2]), function_name = matched[, 3],
                 calls = as.numeric(matched[, 4]), total_s = as.numeric(matched[, 5])) |>
    filter(inside, !is.na(function_name)) |>
    select(-inside)
  stopifnot(nrow(rows) == 1, rows$function_name == expected_functions[[target]])
  rows
})
stopifnot(all(is.finite(runs$total_s)), all(runs$total_s > 0), all(runs$calls > 0))
summary <- runs |>
  group_by(process_count, variant, target, rank, function_name) |>
  summarise(n_runs = n(), median_total_s = median(total_s),
            min_total_s = min(total_s), max_total_s = max(total_s),
            min_calls = min(calls), max_calls = max(calls),
            source_files = paste(sort(source_file), collapse = ";"), .groups = "drop")
baseline <- summary |>
  filter(variant == "vanilla") |>
  select(process_count, target, rank, vanilla_n_runs = n_runs,
         vanilla_median_s = median_total_s)
summary <- summary |>
  left_join(baseline, by = c("process_count", "target", "rank"),
            relationship = "many-to-one") |>
  mutate(speedup = vanilla_median_s / median_total_s,
         min_speedup = vanilla_median_s / max_total_s,
         max_speedup = vanilla_median_s / min_total_s)
stopifnot(all(summary$n_runs >= 2), all(is.finite(summary$speedup)))
# Require all variant/target/count combinations, so missing groups cannot vanish silently.
expected <- crossing(process_count = unique(sources$process_count),
                     variant = c("vanilla", "PRISM", "PRISM_no_sync"),
                     target = names(expected_functions))
stopifnot(nrow(anti_join(expected, summary, by = c("process_count", "variant", "target"))) == 0)
write_csv(runs, "results/communication_target_runs.csv")
write_csv(summary, "results/communication_target_summary.csv")
counts <- sort(unique(summary$process_count))
stopifnot(length(counts) <= 10)
colors <- setNames(as.character(paletteer::paletteer_d("ggthemes::Tableau_10"))[seq_along(counts)],
                   as.character(counts))
dodge <- position_dodge(width = 0.8)
chart <- summary |>
  filter(variant != "vanilla") |>
  mutate(variant = factor(variant, levels = c("PRISM", "PRISM_no_sync")),
         process_count = factor(process_count, levels = counts),
         target = factor(target, levels = c("send", "recv", "send_post", "all"))) |>
  ggplot(aes(target, speedup, fill = process_count)) +
  geom_col(position = dodge, width = 0.7, color = "black", linewidth = 0.5) +
  geom_errorbar(aes(ymin = min_speedup, ymax = max_speedup),
                position = dodge, width = 0.18, linewidth = 0.5, color = "black") +
  geom_hline(yintercept = 1, linetype = "dashed", color = "grey40", linewidth = 1.2) +
  geom_text(aes(y = max_speedup, label = sprintf("%.2fx", speedup)), position = dodge,
            angle = 90, hjust = -0.1, vjust = 0.5, size = 18 / (72.27 / 25.4), family = "sans") +
  facet_wrap(~variant, ncol = 1, scales = "free_y",
             labeller = as_labeller(c(PRISM = "PRISM_rendezvous",
                                      PRISM_no_sync = "PRISM_no_sync"))) +
  scale_fill_manual(values = colors, labels = as.character(counts)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.65))) +
  labs(x = NULL, y = "Speedup", fill = "#Processes") +
  theme_linedraw(base_size = 20, base_family = "sans") +
  theme(axis.title = element_text(size = 22),
        axis.text = element_text(size = 18, color = "black"),
        legend.text = element_text(size = 18),
        legend.position = "top",
        panel.grid.major.x = element_blank(),
        panel.grid.minor = element_blank(),
        strip.background = element_rect(fill = "#E8EDF2", color = "black"),
        strip.text = element_text(size = 20, color = "#222222",
                                  margin = margin(2, 0, 2, 0)))
# Center narrower header backgrounds while keeping the full-width panels.
combined_grob <- ggplotGrob(chart)
for (i in which(str_detect(combined_grob$layout$name, "^strip-"))) {
  strip <- combined_grob$grobs[[i]]
  for (j in seq_along(strip$grobs)) {
    for (k in seq_along(strip$grobs[[j]]$children)) {
      if (inherits(strip$grobs[[j]]$children[[k]], "rect")) {
        strip$grobs[[j]]$children[[k]]$width <- grid::unit(0.6, "npc")
      }
    }
  }
  combined_grob$grobs[[i]] <- strip
}
ggsave("results/communication_target_speedup_bar.pdf", combined_grob,
       width = 9, height = 6, device = cairo_pdf)
# Retain variant-specific axis ranges and styling in standalone plots.
for (selected_variant in c("PRISM", "PRISM_no_sync")) {
  single_chart <- chart + filter(chart$data, variant == selected_variant)
  single_chart <- single_chart + facet_null() +
    scale_y_continuous(expand = expansion(mult = c(0, 0.35)))
  ggsave(paste0("results/communication_target_speedup_", selected_variant, ".pdf"),
         single_chart, width = 9, height = 6, device = cairo_pdf)
}
print(summary |> select(process_count, variant, target, n_runs, median_total_s, speedup),
      n = Inf, width = Inf)
