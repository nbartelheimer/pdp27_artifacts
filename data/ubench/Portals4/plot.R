#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(tidyverse)
  library(paletteer)
})
script <- grep("^--file=", commandArgs(), value = TRUE)[1]
root <- dirname(normalizePath(sub("^--file=", "", script)))
dir.create(file.path(root, "plots"), showWarnings = FALSE)
for (metric in c("latency", "bandwidth")) {
  medians <- read_csv(file.path(root, "data", paste0("bxi-", metric, ".csv")),
                      show_col_types = FALSE) %>%
    pivot_longer(-c(message_size, experiment_id), names_to = "implementation") %>%
    group_by(message_size, implementation) %>%
    summarise(value = median(value, na.rm = TRUE), .groups = "drop")
  p <- ggplot(medians, aes(message_size, value, color = implementation)) +
    geom_line(linewidth = 0.7) + geom_point(size = 1.8) +
    scale_x_continuous(trans = "log2",
      breaks = 2^seq(0, floor(log2(max(medians$message_size))), by = 2),
      labels = scales::label_comma()) +
    scale_color_paletteer_d("ggthemes::Tableau_10") +
    labs(x = "Message size [B]", y = if (metric == "latency")
      "Latency [us]" else "Bandwidth [MB/s]", color = NULL) +
    theme_linedraw(base_size = 11) +
    theme(legend.position = "top",
          axis.text.x = element_text(angle = 45, hjust = 1)) +
    guides(color = guide_legend(nrow = 2))
  if (metric == "latency") p <- p + scale_y_log10(labels = scales::label_number())
  ggsave(file.path(root, "plots", paste0(metric, ".pdf")),
         p, width = 8, height = 5)
}
