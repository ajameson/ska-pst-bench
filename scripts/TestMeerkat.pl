#!/usr/bin/env perl

use strict;
use warnings;

my @bws    = ( 250, 260, 270 );
my @cfreqs = ( 932, 1187, 1452 );

my @channelisations = ( 10, 40 );
my @nbins = ( 1024, 2048 );

@channelisations = ( 10 );
@nbins = ( 1024 );

# WCS parameters from
my $dm = 2000;

my ($bw, $cfreq, $channelisation, $nchan, $nbin, $i, $cmd, $response, $subband, $fft, $perf);
my @lines = ();

$fft = "";
$perf = "";

print "NBIN\tNCHAN\tSubband\tBW\tCFREQ\tNFFT\tPERF\n";
foreach $nbin ( @nbins )
{
  foreach $channelisation ( @channelisations )
  {
    for ($i=0; $i<8; $i++)
    {
      $subband = $i + 1;
      $bw = $bws[$i];
      $cfreq = $cfreqs[$i];
      $nchan = ($bw / 10) * $channelisation;

      $cmd = "./DSPSR_Optimal_FFT.pl ".$bw." ".$cfreq." -dm ".$dm." -nchan ".$nchan." -nbin ".$nbin;
      $response = `$cmd`;
      @lines = split(/\n/, $response);
      ($fft, $perf) = split(/ /, $lines[$#lines]);
      printf $nbin."\t".$nchan."\t".$subband."\t".$bw."\t".$cfreq."\t".$fft."\t".$perf."\n";
    }
  }
}
