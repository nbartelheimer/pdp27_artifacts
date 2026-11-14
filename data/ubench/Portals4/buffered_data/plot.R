#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(tidyverse)
  library(paletteer)
})

# Resolve paths relative to this script so Rscript works from any directory.
script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
data_dir <- if (length(script_arg)) {
  dirname(normalizePath(sub("^--file=", "", script_arg[[1]])))
} else if (file.exists("latency.csv")) {
  normalizePath(".")
} else {
  normalizePath("buffered_data")
}
output_dir <- file.path(data_dir, "plots")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# Keep the series names supplied by the CSVs; experiment_id identifies runs.
# New measurement columns are included automatically.
read_medians <- function(filename) {
  read_csv(file.path(data_dir, filename), show_col_types = FALSE) %>%
    pivot_longer(
      cols = -c(message_size, experiment_id),
      names_to = "implementation",
      values_to = "value"
    ) %>%
    mutate(implementation = factor(implementation, levels = unique(implementation))) %>%
    group_by(message_size, implementation) %>%
    summarise(median = median(value, na.rm = TRUE), .groups = "drop")
}

plot_medians <- function(data, y_label) {
  ggplot(data, aes(message_size, median, color = implementation)) +
    geom_line(linewidth = 0.65) +
    geom_point(size = 1.8) +
    scale_x_continuous(
      trans = "log2",
      breaks = 2^seq(floor(log2(min(data$message_size))),
                     ceiling(log2(max(data$message_size))), by = 2),
      labels = scales::label_number(big.mark = ",")
    ) +
    scale_y_log10(labels = scales::label_number()) +
    scale_color_paletteer_d("ggthemes::Tableau_10") +
    labs(x = "Message size [B]", y = y_label, color = NULL) +
    theme_bw(base_size = 11) +
    theme(
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      axis.text.x = element_text(angle = 45, hjust = 1)
    )
}

latency <- read_medians("latency.csv")
bandwidth <- read_medians("bandwidth.csv")

ggsave(
  file.path(output_dir, "latency.pdf"),
  plot = plot_medians(latency, "Median latency [us]"),
  width = 8, height = 4.5, units = "in"
)
ggsave(
  file.path(output_dir, "bandwidth.pdf"),
  plot = plot_medians(bandwidth, "Median bandwidth [MB/s]"),
  width = 8, height = 4.5, units = "in"
)
