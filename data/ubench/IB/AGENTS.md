# Repository Guidelines

## Project Structure & Module Organization

This repository contains InfiniBand (IB) benchmark measurements and scripts for plotting latency and bandwidth.

- `ib-results/latency.csv` and `ib-results/bandwidth.csv` contain the main IB results for `PRISM_eager`, `PRISM_rendezvous`, `PRISM_no_sync`, and `vanilla` across ten experiments.
- `ib-results/manifest.json` records benchmark configuration; `ib-results/logs/` contains raw run logs. Preserve these source files.
- `plot.R` generates the main plots with tidyverse and paletteer.
- `plots/` holds generated PDFs, named `latency.pdf` and `bandwidth.pdf`.
- `old/` contains historical measurements and plotting scripts; it is separate from the current IB dataset.

There is no application build system or dedicated test directory.

## Build, Test, and Development Commands

Run from the repository root:

```sh
Rscript plot.R
```

This command regenerates both main PDFs. The script resolves input and output paths relative to its own location, so it can also be invoked from another working directory.

Install R dependencies with `install.packages(c("tidyverse", "paletteer"))`. The main plots use `ggthemes::Tableau_10` through paletteer; keep implementation colors consistent across latency and bandwidth.

## Coding Style & Naming Conventions

Use two-space indentation in R. Follow the existing tidyverse pipelines and use `snake_case` names. Keep plotting scripts small, readable, and executable without an interactive session. No formatter or linter configuration is currently provided.

Preserve CSV column names: `message_size`, `experiment_id`, and implementation-specific measurement columns. Treat `experiment_id` as a run identifier, never as a measurement series.

## Testing Guidelines

No automated test framework or coverage target is configured. Validate changes by running `Rscript plot.R` and opening both PDFs in `plots/`. Confirm medians against the source data, consistent implementation colors, readable legends, and unclipped labels.

Aggregate medians by message size and implementation across experiments. Use a log2 x-axis, log10 latency y-axis, and linear bandwidth y-axis. Keep labels exactly `Latency [us]` and `Bandwidth [MB/s]`. Preserve raw measurements when adjusting presentation.

## Commit & Pull Request Guidelines

No Git metadata is available in this checkout, so existing commit conventions cannot be established. Use concise, imperative messages such as `Improve bandwidth plot labels`.

For pull requests, describe the dataset and plotting changes, list commands run, and attach representative plot previews when appearance changes. Reference related issues when applicable and identify any intentional changes to aggregation or units.
