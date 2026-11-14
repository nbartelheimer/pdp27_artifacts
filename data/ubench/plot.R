#!/usr/bin/env Rscript

# Run with Rscript /path/to/ubench/plot_paper.R from any working directory.
# Dependencies: install.packages(c("tidyverse", "paletteer"))
suppressPackageStartupMessages({
  library(tidyverse)
  library(paletteer)
})

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
script_dir <- dirname(normalizePath(sub("^--file=", "", script_arg)))
output_dir <- file.path(script_dir, "paper plots")
dir.create(output_dir, showWarnings = FALSE)

# Explicitly select the current datasets; historical/buffered runs are separate.
datasets <- tribble(
  ~interconnect, ~directory, ~file_prefix,
  "IB", "IB/ib-results", "",
  "Portals4", "Portals4/data", "bxi-",
  "slingshot", "slingshot/results-cxi", ""
)
implementations <- c("PRISM_eager", "PRISM_rendezvous", "PRISM_no_sync",
                     "PRISM_triggered", "vanilla")
implementation_colors <- setNames(
  as.character(paletteer_d("ggthemes::Tableau_10"))[seq_along(implementations)],
  implementations
)
# Filled symbols support a black border independently of the series color.
implementation_shapes <- setNames(c(21, 24, 22, 23, 25), implementations)
implementation_labels <- setNames(implementations, implementations)
implementation_labels["vanilla"] <- "MPI-P2P"

read_medians <- function(path) {
  measurements <- read_csv(path, show_col_types = FALSE)
  series <- implementations[implementations %in% names(measurements)]
  if (length(series) == 0) stop("No implementation columns in ", path)
  measurements %>%
    pivot_longer(all_of(series), names_to = "implementation",
                 values_to = "measurement") %>%
    group_by(message_size, implementation) %>%
    summarise(value = median(measurement), .groups = "drop")
}

plot_metric <- function(interconnect, measurements, metric, y_limits) {
  series <- implementations[implementations %in% measurements$implementation]
  # Sparse byte labels remain readable at publication size.
  x_breaks <- 2^seq(0, floor(log2(max(measurements$message_size))), by = 4)
  p <- ggplot(measurements, aes(message_size, value,
                               color = implementation, shape = implementation)) +
    geom_line(linewidth = 1.25) +
    geom_point(aes(fill = implementation), color = "black",
               size = 3.5, stroke = 0.65) +
    scale_x_continuous(trans = "log2", breaks = x_breaks,
                       labels = scales::label_comma()) +
    scale_color_manual(values = implementation_colors, breaks = series,
                       labels = implementation_labels[series]) +
    scale_fill_manual(values = implementation_colors, breaks = series,
                      labels = implementation_labels[series]) +
    scale_shape_manual(values = implementation_shapes, breaks = series,
                       labels = implementation_labels[series]) +
    labs(x = "Message Size [B]",
         y = if (metric == "latency") "Latency [us]" else "Bandwidth [MB/s]",
         color = NULL, fill = NULL, shape = NULL) +
    theme_linedraw(base_size = 20, base_family = "sans") +
    theme(
      axis.title = element_text(size = 22),
      axis.text = element_text(size = 18, color = "black"),
      axis.title.x = element_text(margin = margin(t = 10)),
      axis.title.y = element_text(margin = margin(r = 10)),
      legend.position = "top",
      legend.text = element_text(size = 18),
      legend.key.width = grid::unit(1.3, "cm"),
      panel.grid.minor = element_blank(),
      panel.grid.major = element_line(color = "grey90", linewidth = 0.3),
      plot.margin = margin(12, 16, 12, 12)
    ) +
    guides(color = guide_legend(ncol = 2, byrow = TRUE),
           fill = guide_legend(ncol = 2, byrow = TRUE),
           shape = guide_legend(ncol = 2, byrow = TRUE))

  if (metric == "latency") {
    p <- p + scale_y_log10(labels = scales::label_number(), limits = y_limits)
  } else {
    p <- p + scale_y_continuous(labels = scales::label_comma(), limits = y_limits)
  }

  output_path <- file.path(output_dir, paste0(interconnect, "_", metric, ".pdf"))
  ggsave(output_path, plot = p, device = "pdf", width = 9, height = 6,
         units = "in", bg = "white")
  message("Saved ", output_path)
}

# Calculate limits from the plotted medians, pooling IB and Portals4 only.
walk(c("latency", "bandwidth"), function(metric) {
  medians <- pmap_dfr(datasets, function(interconnect, directory, file_prefix) {
    read_medians(file.path(
      script_dir, directory, paste0(file_prefix, metric, ".csv")
    )) %>%
      mutate(interconnect = interconnect)
  })
  if (any(!is.finite(medians$value)) ||
      any(!is.finite(medians$message_size) | medians$message_size <= 0)) {
    stop("Non-finite measurements or invalid message sizes for ", metric)
  }
  if (metric == "latency" && any(medians$value <= 0)) {
    stop("Latency must be positive for the log10 axis")
  }
  comparison_values <- medians %>%
    filter(interconnect %in% c("IB", "Portals4")) %>%
    pull(value)
  shared_limits <- if (metric == "latency") {
    range(comparison_values)
  } else {
    c(0, max(comparison_values))
  }

  walk(datasets$interconnect, function(network) {
    measurements <- filter(medians, interconnect == network)
    y_limits <- if (network %in% c("IB", "Portals4")) {
      shared_limits
    } else if (metric == "latency") {
      range(measurements$value)
    } else {
      c(0, max(measurements$value))
    }
    plot_metric(network, measurements, metric, y_limits)
  })
})
