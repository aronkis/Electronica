# Canonical Jupiter build env (speed-optimized; build-speed analysis 2026-06-24)
# NO ADI_PERF_TIMING: Jupiter's functional clk_pl_0 closes at +2ns; the aggressive
# Explore/phys_opt directives only chase the benign adc_1_clk over-constraint -> ~20min wasted.
export ADI_MAX_OOC_JOBS=4      # only ~2-3 IPs ever re-synth (rest are IP-cache hits); 8 just contends on 12 cores
export ADI_LIB_JOBS=8
export ADI_LIB_CACHE_DIR=/mnt/onetb/scratch/adi_lib_cache
export ADI_IP_CACHE_DIR=/mnt/onetb/scratch/adi_ipcache_jupiter
export ADI_MAX_THREADS=12      # use all 12 logical cores (adi_build.tcl honors this after the maxThreads patch)
