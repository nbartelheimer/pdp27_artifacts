#!/usr/bin/env Rscript
suppressPackageStartupMessages(library(tidyverse))

# Resolve paths relative to this script, independently of the caller's directory.
script_arg <- commandArgs(FALSE) |> str_subset("^--file=")
root <- dirname(normalizePath(str_remove(script_arg[[1]], "^--file=")))
input_dir <- file.path(root, "lulesh_data")
output_dir <- file.path(root, "data")
number <- "[-+]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?"
routine_names <- c(
  CommRecv = "comm_recv", CommSend = "comm_send", CommSBN = "comm_sbn",
  CommSyncPosVel = "comm_sync_pos_vel", CommMonoQ = "comm_mono_q",
  MPI_Allreduce = "mpi_allreduce", `Persistent setup` = "persistent_setup",
  `Total (simulation)` = "simulation_total", Total = "total"
)

extract_one <- function(lines, pattern, location) {
  matches <- str_match(lines, pattern)
  values <- matches[!is.na(matches[, 1]), 2]
  if (length(values) != 1) stop(location, ": expected one match for ", pattern)
  as.double(values)
}

parse_file <- function(path) {
  lines <- read_lines(path)
  filename <- basename(path)
  config <- str_match(filename, "^N([0-9]+)_P([0-9]+)\\.dat$")
  if (anyNA(config)) stop("Unexpected filename: ", filename)
  starts <- which(str_detect(lines, "^Running problem size "))
  if (!length(starts)) stop("No runs in ", filename)
  ends <- c(starts[-1] - 1L, length(lines))

  map2_dfr(starts, ends, function(first, last) {
    block <- lines[first:last]
    location <- paste0(filename, ":", first)
    get <- function(pattern) extract_one(block, pattern, location)
    size <- get("^Running problem size ([0-9]+)\\^3")
    processes <- get("^Num processors: ([0-9]+)")
    if (processes != as.double(config[1, 3]) ||
        get("^\\s*MPI tasks\\s*=\\s*([0-9]+)") != processes ||
        get("^\\s*Problem size\\s*=\\s*([0-9]+)") != size ||
        sum(str_detect(block, "^Run completed:")) != 1) {
      stop("Incomplete or inconsistent run: ", location)
    }
    grind <- str_match(block, paste0(
      "^Grind time.*=\\s*(", number, ")\\s*\\(per dom\\)\\s*\\(\\s*(",
      number, ") overall\\)"
    ))
    grind <- grind[!is.na(grind[, 1]), , drop = FALSE]
    if (nrow(grind) != 1) stop("Missing/duplicate grind timing: ", location)

    timing <- str_match(block, paste0(
      "^\\s+(.+?)\\s+(", number, ")\\s+(", number, ")\\s*$"
    ))
    timing <- as_tibble(timing, .name_repair = ~ c("raw", "routine", "rank_average", "rank_maximum")) |>
      filter(!is.na(raw)) |>
      mutate(routine = str_trim(routine))
    if (any(!timing$routine %in% names(routine_names)) || anyDuplicated(timing$routine)) {
      stop("Unknown or duplicate communication timing: ", location)
    }
    prism <- "Persistent setup" %in% timing$routine
    expected <- if (prism) names(routine_names) else setdiff(
      names(routine_names), c("Persistent setup", "Total (simulation)")
    )
    if (!setequal(timing$routine, expected)) stop("Missing timings: ", location)
    wide <- timing |>
      mutate(routine = unname(routine_names[routine])) |>
      select(-raw) |>
      pivot_longer(-routine, names_to = "statistic", values_to = "value") |>
      mutate(column = paste0("communication_", routine, "_", statistic, "_s"),
             value = as.double(value)) |>
      select(column, value) |>
      pivot_wider(names_from = column, values_from = value)

    bind_cols(tibble(
      source_file = filename, source_line = first,
      run_in_file = match(first, starts), nodes = as.integer(config[1, 2]),
      processes = processes, threads = get("^Num threads: ([0-9]+)"),
      size = size, implementation = if_else(prism, "PRISM", "MPI"),
      total_elements = get("^Total number of elements:\\s*([0-9]+)"),
      iterations = get("^\\s*Iteration count\\s*=\\s*([0-9]+)"),
      elapsed_time_s = get(paste0("^Elapsed time\\s*=\\s*(", number, ")")),
      grind_time_per_domain_us_per_zone_cycle = as.double(grind[1, 2]),
      grind_time_overall_us_per_zone_cycle = as.double(grind[1, 3]),
      fom_zones_per_s = get(paste0("^FOM\\s*=\\s*(", number, ")"))
    ), wide)
  })
}

files <- list.files(input_dir, pattern = "\\.dat$", full.names = TRUE)
if (!length(files)) stop("No input logs found")
runs <- map_dfr(files, parse_file) |>
  arrange(nodes, run_in_file) |>
  group_by(source_file, size, implementation) |>
  mutate(repetition = row_number()) |>
  ungroup() |>
  relocate(repetition, .after = implementation)
counts <- runs |>
  count(source_file, nodes, processes, size, implementation, name = "runs")
if (any(counts$runs != 10L) || nrow(counts) != length(files) * 4L ||
    !setequal(runs$size, c(32, 64))) stop("Expected 10 runs per size and implementation in every file")
metrics <- runs |> select(elapsed_time_s:last_col())
required_metrics <- metrics |> select(-contains("persistent_setup"), -contains("simulation_total"))
if (anyNA(required_metrics) || any(as.matrix(metrics) < 0, na.rm = TRUE) ||
    any(!is.finite(as.matrix(required_metrics)))) stop("Missing or invalid metrics")

diagnostics <- map_dfr(files, function(path) {
  lines <- read_lines(path)
  tibble(source_file = basename(path), source_line = seq_along(lines), message = lines) |>
    filter(str_detect(message, regex("error|abort|failed", ignore_case = TRUE)))
})

dir.create(output_dir, showWarnings = FALSE)
write_csv(runs, file.path(output_dir, "lulesh_runs.csv"), na = "")
write_csv(counts, file.path(output_dir, "lulesh_run_counts.csv"))
write_csv(diagnostics, file.path(output_dir, "lulesh_diagnostics.csv"))
message("Wrote ", nrow(runs), " runs, ", nrow(counts), " experiment groups, and ",
        nrow(diagnostics), " diagnostic lines to ", output_dir)
