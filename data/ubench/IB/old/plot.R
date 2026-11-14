#!/usr/bin/env Rscript

suppressMessages(library(tidyverse))
suppressMessages(library(paletteer))

wd <- getwd()
print(wd)
setwd("/Users/niklas/Data/PRISM/ubench/IB")

read_osu_data <- function(path, pattern = NULL) {
    files <- list.files(
        path = path,
        pattern = pattern,
        full.names = TRUE
    )

    map2_dfr(files, seq_along(files), \(file, count) {
        read_table(
            file,
            comment = "#",
            col_names = c("message_size", "metric"),
            show_col_types = FALSE
        ) %>%
            mutate(count = count)
    })
}

persistent_bw <- "^persistent_bw_[0-9]+\\.out$"
persistent_lat <- "^persistent_latency_[0-9]+\\.out$"
persistent_bw_no_sync <- "^persistent_bw_no_sync_[0-9]+\\.out$"
persistent_lat_no_sync <- "^persistent_latency_no_sync_[0-9]+\\.out$"
standard_bw <- "^standard_bw_[0-9]+\\.out$"
standard_lat <- "^standard_latency_[0-9]+\\.out$"

p_bw <- read_osu_data("data", persistent_bw) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "persistent")
s_bw <- read_osu_data("data", standard_bw) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "standard")
p_bw_no_sync <- read_osu_data("data", persistent_bw_no_sync) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "persistent_no_sync")
p_lat <- read_osu_data("data", persistent_lat) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "persistent")
s_lat <- read_osu_data("data", standard_lat) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "standard")
p_lat_no_sync <- read_osu_data("data", persistent_lat_no_sync) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "persistent_no_sync")

bw <- rbind(p_bw, s_bw, p_bw_no_sync)
lat <- rbind(p_lat, s_lat, p_lat_no_sync)

speedup_bw <- bw %>%
    group_by(message_size) %>%
    mutate(speedup = median / median[type == "standard"])
speedup_lat <- lat %>%
    group_by(message_size) %>%
    mutate(speedup = median[type == "standard"] / median)

print(speedup_lat, n = 100)

p <- ggplot(bw, aes(x = message_size, y = median, color = type)) +
    geom_point() +
    geom_line() +
    geom_errorbar(aes(ymin = min, ymax = max)) +
    scale_x_continuous(trans = "log2") +
    xlab("Message Size [B]") +
    ylab("Bandwidth [MB/s]") +
    scale_color_paletteer_d("ggthemes::Tableau_10") +
    labs(color = "") +
    theme_linedraw()
ggsave("plots/bw.pdf", width = 8, height = 4)


p <- ggplot(lat, aes(x = message_size, y = median, color = type)) +
    geom_point() +
    geom_line() +
    geom_errorbar(aes(ymin = min, ymax = max)) +
    scale_x_continuous(trans = "log2") +
    scale_y_log10() +
    xlab("Message Size [B]") +
    ylab("Latency [us]") +
    scale_color_paletteer_d("ggthemes::Tableau_10") +
    labs(color = "") +
    theme_linedraw()
ggsave("plots/lat.pdf", width = 8, height = 4)


### Intra Node Performance

p_lat <- read_osu_data("single_node_data", persistent_lat) |>
    group_by(message_size) |>
    summarise(median = median(metric), min = min(metric), max = max(metric)) |>
    add_column(type = "persistent")
p_bw <- read_osu_data("single_node_data", persistent_bw) |>
    group_by(message_size) |>
    summarise(median = median(metric), min = min(metric), max = max(metric)) |>
    add_column(type = "persistent")
s_bw <- read_osu_data("single_node_data", standard_bw) |>
    group_by(message_size) |>
    summarise(median = median(metric), min = min(metric), max = max(metric)) |>
    add_column(type = "standard")
s_lat <- read_osu_data("single_node_data", standard_lat) |>
    group_by(message_size) |>
    summarise(median = median(metric), min = min(metric), max = max(metric)) |>
    add_column(type = "standard")

lat <- rbind(p_lat, s_lat)
bw <- rbind(p_bw, s_bw)


p <- ggplot(bw, aes(x = message_size, y = median, color = type)) +
    geom_point() +
    geom_line() +
    geom_errorbar(aes(ymin = min, ymax = max)) +
    scale_x_continuous(trans = "log2") +
    xlab("Message Size [B]") +
    ylab("Bandwidth [MB/s]") +
    scale_color_paletteer_d("ggthemes::Tableau_10") +
    labs(color = "") +
    theme_linedraw()
ggsave("plots/intra_node_bw.pdf", width = 8, height = 4)

p <- ggplot(lat, aes(x = message_size, y = median, color = type)) +
    geom_point() +
    geom_line() +
    geom_errorbar(aes(ymin = min, ymax = max)) +
    scale_x_continuous(trans = "log2") +
    scale_y_log10() +
    xlab("Message Size [B]") +
    ylab("Latency [us]") +
    scale_color_paletteer_d("ggthemes::Tableau_10") +
    labs(color = "") +
    theme_linedraw()
ggsave("plots/intra_node_lat.pdf", width = 8, height = 4)
