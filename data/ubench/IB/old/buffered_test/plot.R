#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(paletteer))

# Resolve paths relative to this script when run with Rscript, or from either
# the repository root or buffered_test when sourced interactively.
script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
plot_dir <- if (length(script_arg) > 0) {
  dirname(normalizePath(sub("^--file=", "", script_arg[[1]])))
} else if (file.exists("buffered_test/data/latency.csv")) {
  normalizePath("buffered_test")
} else {
  normalizePath(".")
}
output_dir <- file.path(plot_dir, "plots")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

implementations <- c("vanilla", "prism_eager", "prism_rendezvous")

read_medians <- function(metric) {
  read_csv(
    file.path(plot_dir, "data", paste0(metric, ".csv")),
    show_col_types = FALSE
  ) |>
    pivot_longer(
      cols = all_of(implementations),
      names_to = "implementation",
      values_to = "value"
    ) |>
    group_by(message_size, implementation) |>
    summarise(median = median(value), .groups = "drop") |>
    mutate(implementation = factor(implementation, levels = implementations))
}

make_plot <- function(data, y_label, log_y = FALSE) {
  p <- ggplot(data, aes(message_size, median, color = implementation)) +
    geom_line(linewidth = 0.7) +
    geom_point(size = 1.8) +
    scale_x_continuous(
      trans = "log2",
      breaks = 2^seq(0, 20, by = 2),
      labels = scales::label_comma()
    ) +
    scale_color_paletteer_d("ggthemes::Tableau_10") +
    labs(x = "Message size [B]", y = y_label, color = NULL) +
    theme_linedraw(base_size = 11) +
    theme(
      legend.position = "top",
      panel.grid.minor = element_blank(),
      axis.text.x = element_text(angle = 35, hjust = 1)
    )

  if (log_y) {
    p + scale_y_log10(labels = scales::label_number())
  } else {
    p + scale_y_continuous(labels = scales::label_comma(), limits = c(0, NA))
  }
}

# Input units follow the benchmark convention used in the repository's plot.R:
# latency in microseconds and bandwidth in MB/s.
latency_plot <- make_plot(read_medians("latency"), "Median latency [us]", log_y = TRUE)
bandwidth_plot <- make_plot(read_medians("bandwidth"), "Median bandwidth [MB/s]")

ggsave(file.path(output_dir, "latency.pdf"), latency_plot, width = 8, height = 4.5)
ggsave(file.path(output_dir, "bandwidth.pdf"), bandwidth_plot, width = 8, height = 4.5)
