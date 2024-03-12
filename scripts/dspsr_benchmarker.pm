package dspsr_benchmarker;

use strict;
use warnings;
use POSIX;

BEGIN {

  require Exporter;
  our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

  require AutoLoader;

  $VERSION = '1.00';

  @ISA         = qw(Exporter AutoLoader);
  @EXPORT      = qw(&main);
  %EXPORT_TAGS = ( );
  @EXPORT_OK   = qw($dl $centre_frequency $total_bandwidth $chan_bw @subband_bandwidths @rechannelisations @nbins);

}

our @EXPORT_OK;

our $dl = 1;
our $centre_frequency = 0;
our $total_bandwidth = 0;
our $chan_bw = 0;
our @subband_bandwidths = ();
our @subband_cfreqs = ();
our @rechannelisations = ();
our @nbins = ();

sub configure_subbands ()
{
  my $bottom = $centre_frequency - ( $total_bandwidth / 2);
  my $top = $centre_frequency + ( $total_bandwidth / 2);
    
  my $high = $bottom;
  my ($bw, $low, $mid);
  for $bw ( @subband_bandwidths )
  {
    $low = $high;
    $mid = $low + ($bw / 2);
    $high = $low + $bw;
    
    print "SubBand: ".$low." - ".$high." (".$bw.")\n";
    push @subband_cfreqs, $mid;
  }
  
  if ($high != $top)
  {
    print STDERR "Error in the sub-band frequency division\n";
    return -1;
  }
}

sub benchmark_mid() 
{
  my ($nbin, $rechannelisation);

  configure_subbands ();

  my $nsub = $#subband_cfreqs;
  my $top_freq = ($subband_cfreqs[$nsub] + ($subband_bandwidths[$nsub]/2)) / 1000.0;
  my $dm_chan_bw = 10;

  print "DM\tNBIN\tNCHAN_IN\tNCHAN_OUT\tSubband\tBW\tCFREQ\tNFFT\tPERF\n";
  foreach $nbin ( @nbins )
  {
    foreach $rechannelisation ( @rechannelisations )
    {
      process ($nbin, $rechannelisation, $top_freq, $dm_chan_bw, " -cfg mid");
    }
  }
}

sub benchmark_low() 
{
  my ($nbin, $rechannelisation);

  configure_subbands ();

  my $bottom_freq = ($subband_cfreqs[0] - ($subband_bandwidths[0]/2)) / 1000.0;
  my $chan_bw = 0.8;

  print "DM\tNBIN\tNCHAN_IN\tNCHAN_OUT\tSubband\tBW\tCFREQ\tNFFT\tPERF\n";
  foreach $nbin ( @nbins )
  {
    foreach $rechannelisation ( @rechannelisations )
    {
      process ($nbin, $rechannelisation, $bottom_freq, $chan_bw, "-cfg low");
    }
  }
}


sub process ($$$$$)
{
  my ($nbin, $rechannelisation, $ref_freq, $dm_chan_bw, $opts) = @_;

  my ($tres, $dm_raw, $dm, $i, $cmd, @lines, $fft, $perf);
  my ($nchan, $nchan_div, $cfreq, $bw, $subband, $response);

  $tres = (1.0/($dm_chan_bw * 1e6));
  $dm_raw = 10 ** ((1.0/2.14) * (-0.154 + sqrt(0.0247 + 4.28 * (13.46 + 3.86 * log10($ref_freq) + log10($tres)))));
  $dm = ceil($dm_raw);

  if ($dl > 1)
  {
    print "ref_freq=$ref_freq rechannelisation=$rechannelisation tres=$tres dm=$dm\n";
  }

  for ($i=0; $i<=$#subband_bandwidths; $i++)
  {
    $subband = $i + 1;
    $bw = $subband_bandwidths[$i];
    $cfreq = $subband_cfreqs[$i];
    $nchan = int($bw / $chan_bw);
    $nchan_div = (int($nchan / $rechannelisation) + 1) * $rechannelisation;

    $cmd = "./DSPSR_Optimal_FFT_iPFB.pl ".$nchan_div." ".$cfreq." -dm ".$dm." -rechan ".$rechannelisation." -nbin ".$nbin." ".$opts;
    if ($dl > 1)
    {
      print $cmd."\n";
    }
    $response = `$cmd`;
    @lines = split(/\n/, $response);
    ($fft, $perf) = split(/ /, $lines[$#lines]);
    printf $dm."\t".$nbin."\t".$nchan_div."\t".int($nchan_div/$rechannelisation)."\t".$subband."\t".$bw."\t".$cfreq."\t".$fft."\t".$perf."\n";
  }

}


END { } 

1;


