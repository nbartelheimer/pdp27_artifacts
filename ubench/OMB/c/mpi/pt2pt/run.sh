#!/usr/bin/env bash


mkdir -p data

ml +PRISM/ib

ITER=30

RUN_LATENCY="mpirun --bind-to none  -x LD_LIBRARY_PATH -np 1 --host hpca-013 numactl --cpunodebind=1 ./standard/osu_latency : -np 1 --host hpca-014 numactl --cpunodebind=0 ./standard/osu_latency"
RUN_BW="mpirun --bind-to none  -x LD_LIBRARY_PATH -np 1 --host hpca-013 numactl --cpunodebind=1 ./standard/osu_bw : -np 1 --host hpca-014 numactl --cpunodebind=0 ./standard/osu_bw"
RUN_LATENCY_P="mpirun --bind-to none  -x LD_LIBRARY_PATH -np 1 --host hpca-013 numactl --cpunodebind=1 ./persistent/osu_latency_persistent : -np 1 --host hpca-014 numactl --cpunodebind=0 ./persistent/osu_latency_persistent"
RUN_LATENCY_P_NO_SYNC="mpirun --bind-to none  -x LD_LIBRARY_PATH -np 1 --host hpca-013 numactl --cpunodebind=1 ./persistent/osu_latency_persistent_no_sync : -np 1 --host hpca-014 numactl --cpunodebind=0 ./persistent/osu_latency_persistent_no_sync"
RUN_BW_P="mpirun --bind-to none  -x LD_LIBRARY_PATH -np 1 --host hpca-013 numactl --cpunodebind=1 ./persistent/osu_bw_persistent : -np 1 --host hpca-014 numactl --cpunodebind=0 ./persistent/osu_bw_persistent"
RUN_BW_P_NO_SYNC="mpirun --bind-to none  -x LD_LIBRARY_PATH -np 1 --host hpca-013 numactl --cpunodebind=1 ./persistent/osu_bw_persistent_no_sync : -np 1 --host hpca-014 numactl --cpunodebind=0 ./persistent/osu_bw_persistent_no_sync"


for((i=0; i < ITER; i++));
do
	$RUN_BW 2>&1 | tee data/standard_bw_$i.dat
done

for((i=0; i < ITER; i++)); 
do
	$RUN_LATANCY 2>&1 | tee data/standard_latency_$i.dat
done

for((i=0; i < ITER; i++)); 
do
	$RUN_BW_P 2>&1 | tee data/persistent_bw_$i.dat
done

for((i=0; i < ITER; i++)); 
do
	$RUN_BW_P_NO_SYNC 2>&1 | tee data/persistent_bw_no_sync_$i.dat
done

for((i=0; i < ITER; i++)); 
do
	$RUN_LATENCY_P 2>&1 | tee data/persistent_latency_$i.dat
done

for((i=0; i < ITER; i++)); 
do
	$RUN_LATENCY_P_NO_SYNC 2>&1 | tee data/persistent_latency_$i.dat
done
