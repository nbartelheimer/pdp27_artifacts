#!/usr/bin/env bash
sbatch -Mmogonnhr batch_64.sh
sbatch -Mmogonnhr batch_512.sh
sbatch -Mmogonnhr batch_2048.sh
sbatch -Mmogonnhr batch_4096.sh
