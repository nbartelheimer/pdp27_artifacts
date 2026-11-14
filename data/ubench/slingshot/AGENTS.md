# Repository Guidelines

## Project Structure & Module Organization

This repository contains Slingshot/CXI benchmark measurements and scripts for plotting latency and bandwidth.

- `results-cxi/latency.csv` and `results-cxi/bandwidth.csv` contain the main Slingshot/CXI results for `PRISM_eager`, `PRISM_rendezvous`, `PRISM_no_sync`, and `vanilla` across ten experiments.
- Message sizes range from 1 byte to 4 MiB (23 powers of two), with ten runs per message size.
- `results-cxi/manifest.json` records benchmark configuration; `results-cxi/logs/` contains raw run logs. Preserve these source files. The manifest records `FI_PROVIDER=cxi`, `ct-buffered` completion for `PRISM_eager`, and `ct` for `PRISM_rendezvous` and `PRISM_no_sync`.
- `plot.R` generates the main plots with tidyverse and paletteer.
- `plots/` holds generated PDFs, named `latency.pdf` and `bandwidth.pdf`.
- `old/` contains historical measurements and plotting scripts; it is separate from the current Slingshot/CXI dataset.

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
