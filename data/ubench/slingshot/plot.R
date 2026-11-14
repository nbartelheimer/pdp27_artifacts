#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(paletteer))

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_dir <- dirname(normalizePath(sub("^--file=", "", script_arg)))
output_dir <- file.path(script_dir, "plots")
dir.create(output_dir, showWarnings = FALSE)

implementations <- c("PRISM_eager", "PRISM_rendezvous", "PRISM_no_sync", "vanilla")
implementation_colors <- setNames(
  as.character(paletteer_d("ggthemes::Tableau_10", n = 4)),
  implementations
)

plot_metric <- function(metric, y_label) {
  measurements <- read_csv(
    file.path(script_dir, "results-cxi", paste0(metric, ".csv")),
    show_col_types = FALSE
  )
  summary <- measurements %>%
    pivot_longer(all_of(implementations), names_to = "implementation", values_to = "value") %>%
    group_by(message_size, implementation) %>%
    summarise(value = median(value), .groups = "drop")

  p <- ggplot(summary, aes(message_size, value, color = implementation)) +
    geom_line(linewidth = 0.7) +
    geom_point(size = 1.7) +
    scale_x_continuous(
      trans = "log2",
      breaks = 2^seq(0, 22, 2),
      labels = c("1", "4", "16", "64", "256", "1 KiB", "4 KiB",
                 "16 KiB", "64 KiB", "256 KiB", "1 MiB", "4 MiB")
    ) +
    scale_color_manual(values = implementation_colors, breaks = implementations) +
    labs(x = "Message Size [B]", y = y_label, color = NULL) +
    theme_linedraw(base_size = 11) +
    theme(
      legend.position = "bottom",
      panel.grid.minor = element_blank(),
      axis.text.x = element_text(angle = 45, hjust = 1)
    )

  if (metric == "latency") {
    p <- p + scale_y_log10()
  } else {
    p <- p + scale_y_continuous(labels = scales::label_comma(), limits = c(0, NA))
  }

  ggsave(file.path(output_dir, paste0(metric, ".pdf")), p, width = 8, height = 4.5)
}

plot_metric("latency", "Latency [us]")
plot_metric("bandwidth", "Bandwidth [MB/s]")
