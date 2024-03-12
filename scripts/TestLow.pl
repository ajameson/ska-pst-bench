#!/usr/bin/env perl

use strict;
use warnings;
use dspsr_benchmarker;

# 800 kHz channels

$dspsr_benchmarker::dl = 2;
$dspsr_benchmarker::centre_frequency = 200;
$dspsr_benchmarker::total_bandwidth = 300;
$dspsr_benchmarker::chan_bw = 0.003616898148;

@dspsr_benchmarker::subband_bandwidths = ( 24, 64, 96, 116);
@dspsr_benchmarker::rechannelisations = ( 216 );
@dspsr_benchmarker::nbins = ( 1024 );

dspsr_benchmarker->benchmark_low ();

