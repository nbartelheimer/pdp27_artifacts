#!/usr/bin/env Rscript

suppressPackageStartupMessages(library(tidyverse))
suppressPackageStartupMessages(library(paletteer))

script_path <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())])
script_dir <- dirname(normalizePath(script_path))
output_dir <- file.path(script_dir, "plots")
dir.create(output_dir, showWarnings = FALSE)

implementations <- c("PRISM_eager", "PRISM_rendezvous", "PRISM_no_sync", "vanilla")
implementation_colors <- setNames(
  as.character(paletteer_d("ggthemes::Tableau_10"))[seq_along(implementations)],
  implementations
)

read_medians <- function(metric) {
  read_csv(file.path(script_dir, "ib-results", paste0(metric, ".csv")),
           show_col_types = FALSE) %>%
    pivot_longer(all_of(implementations), names_to = "implementation",
                 values_to = "measurement") %>%
    group_by(message_size, implementation) %>%
    summarise(median = median(measurement), .groups = "drop")
}

plot_metric <- function(metric, y_label) {
  measurements <- read_medians(metric)
  plot <- ggplot(measurements, aes(message_size, median, color = implementation)) +
    geom_line(linewidth = 0.6) +
    geom_point(size = 1.5) +
    scale_x_continuous(
      trans = "log2", breaks = 2^seq(0, 24, by = 4),
      labels = scales::label_number(big.mark = ",")
    ) +
    scale_color_manual(values = implementation_colors, breaks = implementations) +
    labs(x = "Message Size [B]", y = y_label, color = NULL) +
    theme_linedraw(base_size = 11) +
    theme(legend.position = "top")#, panel.grid.minor = element_blank())

  if (metric == "latency") {
    plot <- plot + scale_y_log10()
  } else {
    plot <- plot + scale_y_continuous(labels = scales::label_number(big.mark = ","))
  }

  ggsave(file.path(output_dir, paste0(metric, ".pdf")), plot,
         width = 8, height = 4.5)
}

plot_metric("latency", "Latency [us]")
plot_metric("bandwidth", "Bandwidth [MB/s]")
