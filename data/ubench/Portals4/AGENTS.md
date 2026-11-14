# Repository Guidelines

## Project Structure & Module Organization

This repository contains Portals4 benchmark measurements and scripts for plotting latency and bandwidth.

- `data/bxi-latency.csv` and `data/bxi-bandwidth.csv` contain the main BXI results.
- `plot.R` generates the main plots with tidyverse and paletteer.
- `plots/` holds generated PDFs, named `latency.pdf` and `bandwidth.pdf`.
- `buffered_data/` contains a separate measurement set and its own `plot.R`, which writes to `buffered_data/plots/`.

There is no application build system or dedicated test directory.

## Build, Test, and Development Commands

Run from the repository root:

```sh
Rscript plot.R
Rscript buffered_data/plot.R
```

The first command regenerates both main PDFs. The second plots the separate buffered dataset using its existing configuration. Both scripts resolve input and output paths relative to their own locations.

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
