#!/usr/bin/env bash
#SBATCH -Anhr-sw29231
#SBATCH -p parallel
#SBATCH -N4
#SBATCH -n64
#SBATCH --ntasks-per-node=16
#SBATCH --cpus-per-task=8
#SBATCH -t 2:00:00
#SBATCH --switches=1

module load openmpi

OUTDIR="${LUSTRE_HOME}/QWS/64_PPN"
mkdir -p $OUTDIR

for i in {1..10}
do
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws_prism/main_recv 32 6 4 3  2 2 4 4    -1   -1  6 50 2>&1 | tee "${OUTDIR}/opt_benchmark_recv_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws_prism/main_send 32 6 4 3  2 2 4 4    -1   -1  6 50 2>&1 | tee "${OUTDIR}/opt_benchmark_send_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws_prism/main_send_post 32 6 4 3  2 2 4 4    -1   -1  6 50 2>&1 | tee "${OUTDIR}/opt_benchmark_send_post_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws_prism/main_all 32 6 4 3  2 2 4 4    -1   -1  6 50 2>&1 | tee "${OUTDIR}/opt_benchmark_all_${i}.dat"

	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws_no_sync/main_recv 32 6 4 3  2 2 4 4	-1   -1  6 50 2>&1 | tee "${OUTDIR}/no_sync_benchmark_recv_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws_no_sync/main_send 32 6 4 3  2 2 4 4	-1   -1  6 50 2>&1 | tee "${OUTDIR}/no_sync_benchmark_send_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws_no_sync/main_send_post 32 6 4 3  2 2 4 4	-1   -1  6 50 2>&1 | tee "${OUTDIR}/no_sync_benchmark_send_post_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws_no_sync/main_all 32 6 4 3  2 2 4 4	-1   -1  6 50 2>&1 | tee "${OUTDIR}/no_sync_benchmark_all_${i}.dat"

	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws/main_recv 32 6 4 3   2 2 4 4  -1   -1  6 50 2>&1 | tee "${OUTDIR}/vanilla_benchmark_recv_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws/main_send 32 6 4 3   2 2 4 4  -1   -1  6 50 2>&1 | tee "${OUTDIR}/vanilla_benchmark_send_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws/main_send_post 32 6 4 3   2 2 4 4  -1   -1  6 50 2>&1 | tee "${OUTDIR}/vanilla_benchmark_send_post_${i}.dat"
	mpirun -x OMP_DISPLAY_AFFINITY=false -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/qws/main_all 32 6 4 3   2 2 4 4  -1   -1  6 50 2>&1 | tee "${OUTDIR}/vanilla_benchmark_all_${i}.dat"
done
