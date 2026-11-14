#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(tidyverse))

script_arg <- commandArgs(FALSE) |> str_subset("^--file=")
root <- dirname(normalizePath(str_remove(script_arg[[1]], "^--file=")))
plot_dir <- file.path(root, "plots")
runs <- read_csv(file.path(root, "data", "lulesh_runs.csv"), show_col_types = FALSE)

# Aggregate first, then divide: these are ratios of medians, not median ratios.
# Use the reported total at the slowest rank, including PRISM setup.
medians <- runs |>
  group_by(size, processes, implementation) |>
  summarise(
    runs = n(),
    communication_min_s = min(communication_total_rank_maximum_s),
    communication_max_s = max(communication_total_rank_maximum_s),
    fom_min_zones_per_s = min(fom_zones_per_s),
    fom_max_zones_per_s = max(fom_zones_per_s),
    communication_total_rank_maximum_s = median(communication_total_rank_maximum_s),
    fom_zones_per_s = median(fom_zones_per_s),
    .groups = "drop"
  )
stopifnot(
  all(medians$runs == 10),
  setequal(medians$implementation, c("MPI", "PRISM")),
  setequal(medians$size, c(32, 64))
)
speedups <- medians |>
  pivot_wider(
    names_from = implementation,
    values_from = c(runs, communication_total_rank_maximum_s, fom_zones_per_s,
                    communication_min_s, communication_max_s,
                    fom_min_zones_per_s, fom_max_zones_per_s)
  ) |>
  mutate(
    communication_speedup = communication_total_rank_maximum_s_MPI /
      communication_total_rank_maximum_s_PRISM,
    fom_speedup = fom_zones_per_s_PRISM / fom_zones_per_s_MPI,
    # Unpaired runs: extrema over all possible cross-implementation ratios.
    communication_speedup_min = communication_min_s_MPI / communication_max_s_PRISM,
    communication_speedup_max = communication_max_s_MPI / communication_min_s_PRISM,
    fom_speedup_min = fom_min_zones_per_s_PRISM / fom_max_zones_per_s_MPI,
    fom_speedup_max = fom_max_zones_per_s_PRISM / fom_min_zones_per_s_MPI
  ) |>
  arrange(size, processes)
stopifnot(
  nrow(speedups) == 8, !anyNA(speedups),
  all(is.finite(speedups$communication_speedup)),
  all(is.finite(speedups$fom_speedup)),
  all(speedups$communication_speedup > 0), all(speedups$fom_speedup > 0)
)
write_csv(speedups, file.path(root, "data", "lulesh_speedups.csv"))

plot_data <- bind_rows(
  speedups |> transmute(size, processes, metric = "communication_speedup",
    speedup = communication_speedup, lower = communication_speedup_min,
    upper = communication_speedup_max),
  speedups |> transmute(size, processes, metric = "fom_speedup",
    speedup = fom_speedup, lower = fom_speedup_min, upper = fom_speedup_max)
) |>
  mutate(
    processes = factor(processes, levels = sort(unique(processes))),
    metric = factor(metric,
      levels = c("communication_speedup", "fom_speedup"),
      labels = c("Comm. Time", "FOM")
    ),
    label = sprintf("%.2f×", speedup)
  )
stopifnot(all(plot_data$lower <= plot_data$speedup),
          all(plot_data$speedup <= plot_data$upper))
colors <- as.character(paletteer::paletteer_d("ggthemes::Tableau_10"))[1:4]
names(colors) <- levels(plot_data$processes)
dir.create(plot_dir, showWarnings = FALSE)

for (problem_size in c(32, 64)) {
  # Keep every observed bound visible; place labels above the error bars.
  y_min <- if (problem_size == 32) 0.2 else 0.7
  plot <- plot_data |>
    filter(size == problem_size) |>
    mutate(label_y = upper + 0.02) |>
    ggplot(aes(metric, speedup, fill = processes)) +
    geom_col(color = "black", linewidth = 0.5, position = position_dodge(width = 0.8), width = 0.7) +
    geom_errorbar(aes(ymin = lower, ymax = upper),
                  position = position_dodge(width = 0.8), width = 0.18,
                  linewidth = 0.5) +
    geom_hline(yintercept = 1, linetype = "dashed", color = "black", linewidth = 1.1) +
    geom_text(aes(y = label_y, label = label), position = position_dodge(width = 0.8),
              angle = 90, hjust = 0, vjust = 0.5, size = 7,
              family = "sans", show.legend = FALSE) +
    scale_fill_manual(values = colors) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.2))) +
    coord_cartesian(ylim = c(y_min, NA)) +
    labs(x = NULL, y = "Speedup", fill = "#Processes") +
    theme_linedraw(base_size = 20, base_family = "sans") +
    theme(
      panel.grid.major.x = element_blank(),
      panel.grid.minor.x = element_blank(),
      axis.title = element_text(size = 22),
      axis.text = element_text(size = 18),
      legend.text = element_text(size = 18),
      legend.position = "top", legend.justification = "center",
      plot.margin = margin(12, 18, 12, 12)
    )
  for (extension in c("png", "pdf")) {
    ggsave(file.path(plot_dir, paste0("speedup_s", problem_size, ".", extension)),
           plot, width = 9, height = 6, dpi = 300, bg = "white")
  }
}
print(speedups |> select(size, processes, communication_speedup, fom_speedup))
