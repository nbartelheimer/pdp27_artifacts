#!/usr/bin/env bash


mkdir -p data

ml +PRISM/opa

ITER=30

for i in {0..30}
do
	mpirun --host hpca-011,hpca-012 -np 2 -x LD_LIBRARY_PATH -x FI_PROVIDER=opx ./standard/osu_bw 2>&1 | tee data/standard_bw_$i.dat
done

for i in {0..30}
do
	mpirun --host hpca-011,hpca-012 -np 2 -x LD_LIBRARY_PATH -x FI_PROVIDER=opx ./standard/osu_latency 2>&1 | tee data/standard_latency_$i.dat
done

for i in {0..30}
do
	mpirun --host hpca-011,hpca-012 -np 2 -x LD_LIBRARY_PATH -x FI_PROVIDER=opx ./persistent/osu_bw_persistent 2>&1 | tee data/persistent_bw_$i.dat
done

for i in {0..30}
do
	mpirun --host hpca-011,hpca-012 -np 2 -x LD_LIBRARY_PATH -x FI_PROVIDER=opx ./persistent/osu_latency_persistent 2>&1 | tee data/persistent_latency_$i.dat
done
