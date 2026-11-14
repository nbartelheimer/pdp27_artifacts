#!/usr/bin/env Rscript

suppressMessages(library(tidyverse))
suppressMessages(library(paletteer))

wd <- getwd()
print(wd)
setwd("/Users/niklas/Data/PRISM/ubench/slingshot/")

read_osu_data <- function(path, pattern = NULL, skip = 0) {
    files <- list.files(
        path = path,
        pattern = pattern,
        full.names = TRUE
    )

    map2_dfr(files, seq_along(files), \(file, count) {
        read_table(
            file,
            skip = skip,
            comment = "#",
            col_names = c("message_size", "metric"),
            show_col_types = FALSE
        ) %>%
            mutate(count = count)
    })
}

persistent_bw <- "^persistent_bw_[0-9]+\\.out$"
persistent_lat <- "^persistent_latency_[0-9]+\\.out$"
standard_bw <- "^standard_bw_[0-9]+\\.out$"
standard_lat <- "^standard_latency_[0-9]+\\.out$"

p_bw <- read_osu_data("data", persistent_bw, 31) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "persistent")
s_bw <- read_osu_data("data", standard_bw) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "standard")

p_lat <- read_osu_data("data", persistent_lat, 31) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "persistent")
s_lat <- read_osu_data("data", standard_lat) %>%
    group_by(message_size) %>%
    summarise(median = median(metric), min = min(metric), max = max(metric)) %>%
    add_column(type = "standard")


bw <- rbind(p_bw, s_bw)
lat <- rbind(p_lat, s_lat)

print(n = 50, bw)

# print(speedup_lat, n = 100)

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
# plot(p)
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
# plot(p)
ggsave("plots/lat.pdf", width = 8, height = 4)
