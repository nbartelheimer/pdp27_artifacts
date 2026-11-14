#!/usr/bin/env bash
#SBATCH -p parallel
#SBATCH -N32
#SBATCH -n512
#SBATCH -Anhr-sw29231
#SBATCH --ntasks-per-node=16
#SBATCH --cpus-per-task=8
#SBATCH -t 8:00:00

ml +openmpi

for s in 32 64 128; do
    echo "=== Running with -s $s ==="

    OUTDIR="${LUSTRE_HOME}/lulesh_persistent_results"
    mkdir -p $OUTDIR

    for i in {1..10}
    do
        mpirun -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/lulesh_persistent/build/lulesh2.0 -s $s -i 500 2>&1 | tee $OUTDIR/N32_P512_s$s_$i.out
    done

    OUTDIR="${LUSTRE_HOME}/lulesh_results"
    mkdir -p $OUTDIR

    for i in {1..10}
    do
        mpirun -x OMP_NUM_THREADS=8 -x OMP_PLACES=cores -x OMP_PROC_BIND=close --map-by ppr:1:numa:PE=8 ~/LULESH/build/lulesh2.0 -s $s -i 500 2>&1 | tee $OUTDIR/N32_P512_s$s_$i.out
    done
done
