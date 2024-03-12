#!/usr/bin/env perl

use strict;
use warnings;
use dspsr_benchmarker;

$dspsr_benchmarker::centre_frequency = 700;
$dspsr_benchmarker::total_bandwidth = 700;
$dspsr_benchmarker::chan_bw = 0.05376;

@dspsr_benchmarker::subband_bandwidths = ( 100, 150, 200, 250 );
#@dspsr_benchmarker::rechannelisations = ( 5, 37 );
@dspsr_benchmarker::rechannelisations = ( 5 );
@dspsr_benchmarker::nbins = ( 1024 );

dspsr_benchmarker->benchmark_mid ();
