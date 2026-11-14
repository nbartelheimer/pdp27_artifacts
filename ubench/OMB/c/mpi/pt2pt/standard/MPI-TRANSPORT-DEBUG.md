# Open MPI local latency investigation — 2026-09-29

## Finding

The installed Open MPI 5.0.9 selects `cm` + OFI MTL using
`verbs;ofi_rxm` on `mlx5_0`, including for ranks on the same node.
It does not select the `ob1` PML, which is the component that combines
the `sm` shared-memory BTL with remote-network BTLs.

The shared-memory implementation works: selecting `ob1` reduces small-message
latency from approximately 1.83–1.88 us to 0.32–0.33 us.

No benchmark or Open MPI source was changed, and no persistent MPI configuration
was changed during this investigation.

## Evidence and selection logic

- `mpirun` resolves to `/home/niklas/opt/openmpi-ib/bin/mpirun`.
  `osu_latency` links to that installation's `libmpi.so.40`.
- `ompi_info --version` reports **5.0.9**. The module's help text says
  5.0.10rc2, but this does not match the installed executable.
- No `OMPI_MCA_*` or `FI_*` overrides were present in the initial environment.
- `ompi_info --param pml all` lists `cm`, `monitoring`, `ob1`, and `v`;
  there is no `ucx` PML.
- A run with `--mca pml_base_verbose 100 --mca mtl_base_verbose 100`
  reported OFI/CM priority **25**, OB1 priority **20**, and `selected cm best priority 25`.
- `--mca mtl_ofi_verbose 10` reported `verbs;ofi_rxm`, domain `mlx5_0`.
- `/home/niklas/openmpi-5.0.9/config.log` records failure to find
  `ucp/api/ucp.h` and that `pml:ucx` cannot compile.

Relevant source paths, relative to `/home/niklas/openmpi-5.0.9`:

| Location | Behavior |
| --- | --- |
| `ompi/mca/mtl/ofi/mtl_ofi_component.c:127` | OFI MTL defaults to priority 25 |
| `ompi/mca/pml/cm/pml_cm_component.c:135` | CM gets its priority from MTL selection |
| `ompi/mca/pml/ob1/pml_ob1_component.c:206` | OB1 defaults to priority 20 |
| `ompi/mca/pml/base/pml_base_select.c:138` | Highest-priority PML wins |
| `config.log:40964` | UCX header lookup fails |
| `config.log:60784` | UCX PML cannot compile |

The documentation's automatic selection of the best **BTL** applies when using
the BTL-based transport model. CM uses an MTL instead; setting `btl=sm,...`
alone does not make CM send local messages through SM. The OFI MTL's default
exclusion of libfabric `shm` is separate from Open MPI's `sm` BTL.

References:

- https://docs.open-mpi.org/en/v5.0.9/release-notes/networks.html
- https://docs.open-mpi.org/en/v5.0.9/tuning-apps/networking/shared-memory.html

## Measurements

Tests ran on hpca-013, using default process binding.

| Configuration | 1 B | 2 B | 4 B | 8 B | 64 B |
| --- | ---: | ---: | ---: | ---: | ---: |
| Default, 1,000 timed iterations | 1.88 | 1.88 | 1.88 | 1.85 | not measured |
| `--mca pml ob1`, 10,000 timed iterations | 0.33 | 0.33 | 0.33 | 0.33 | 0.39 |
| OB1 + `self,sm,ofi`, OFI mode 1, 10,000 timed iterations | 0.32 | 0.32 | 0.32 | 0.32 | 0.34 |

Values are OSU one-way latency in microseconds. A subsequent default-provider
trace measured 1.83–1.85 us. These are diagnostic runs, not statistical estimates.

Local reproduction:

```sh
mpirun -np 2 ./osu_latency -m 1:8 -i 1000 -x 100
mpirun -np 2 --mca pml ob1 ./osu_latency -m 1:64 -i 10000 -x 1000
```

The local combined-BTL run included `--mca btl_base_verbose 30
--mca bml_base_verbose 50`; both ranks explicitly logged `Using sm btl` for
the other rank and `self` for themselves.

## Multi-node validation and limits

Used the existing `/home/niklas/openmpi-5.0.9/debug/ib/mpi-check` program,
whose source verifies ring transfers from 4 B through 1 MiB, allreduce,
barrier, and self-send.

This **passed** with four ranks, two on each node:

```sh
mpirun --host hpca-013:2,hpca-014:2 -np 4 --map-by ppr:2:node \
  -x LD_LIBRARY_PATH --mca pml ob1 --mca btl self,sm,tcp \
  /home/niklas/openmpi-5.0.9/debug/ib/mpi-check
```

This is a working mixed-node control, but uses TCP for remote communication.
Selecting OB1 alone is therefore not a validated InfiniBand solution here.

The OFI BTL defaults to **one-sided only** (`btl_ofi_mode=0`). Enabling
two-sided sends with `--mca btl self,sm,ofi --mca btl_ofi_mode 1`
worked locally, but the four-rank mixed-node check failed to complete within
45 seconds. Its trace selected SM for local peers and OFI for remote peers.
There was no TCP BTL in that run.

Two additional runs timed out with exit status 124 after 35 seconds:

- `--mca mpi_add_procs_cutoff 100` to preallocate remote peers.
- Loading the existing debug PMIx and libfabric libraries via `LD_PRELOAD`.

The cause of this additional OFI BTL hang was not isolated. Consequently,
the OB1/OFI configuration is **not validated for production use**.

## Recommended next change

Build/install UCX and rebuild this Open MPI installation with
`--with-ucx=/path/to/ucx`, retaining its other required configure options.
Open MPI documents UCX as its default InfiniBand transport when available;
UCX supports both InfiniBand and shared memory. This addresses the missing
transport model without selecting a different PML based on job placement.

Validate the new build with a plain `mpirun -np 2 ./osu_latency`, transport
traces, and the four-rank mixed-node correctness check. This rebuild was not
performed as part of the diagnosis, and its performance remains unmeasured.

## Saved logs

- `transport-debug-logs/default-latency.log`: provider selection and baseline.
- `transport-debug-logs/local-sm-ofi.log`: shared-memory selection and latency.
- `transport-debug-logs/mixed-sm-ofi.log`: initial mixed-node OFI attempt.
- `transport-debug-logs/mixed-eager-modex.log`: eager peer setup attempt.
- `transport-debug-logs/mixed-preload.log`: existing patched libraries attempt.
- `transport-debug-logs/mixed-sm-tcp.log`: passing mixed-node control.
