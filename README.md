# SKA-PST-BENCH

Simple set of benchmarking scripts for the Pulsar Timing Product for SKA.

Uses DSPSR's PFB inversion features to benchmark the run-time performance of GPUs for SKA PST workloads

    
    export PERL5LIB=`pwd`/scripts:$PERL5LIB
    cd scripts
    ./TestLow.pl
    ./TestBand1.pl
    ./TestBand2.pl
    ./TestBand3.pl
    ./TestBand4.pl
    ./TestBand5.pl
