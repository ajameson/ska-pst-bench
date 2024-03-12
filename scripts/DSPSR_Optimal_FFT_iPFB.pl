#!/usr/bin/env perl

#
# Run DSPSR to find optimal BWD FFT length for the given parameters
#
#   Assumptions:
#     PSRDada Ring buffer input format
#     10 MHz Channels

use strict;
use warnings;
use threads;
use Getopt::Long;
sub usage();

sub usage()
{
  print "$0: [opts] nchan freq\n";
  print "compute optimal FFT length for given bw and freq\n\n";
  print "   nchan                 number of channels to process\n";
  print "   freq                  centre frequnecy of the total bandwidth\n";
  print "   -cfg [low|mid]        SKA configuration to assume\n";
  print "   -rechan <num>         rechannelisation factor in the iPFB\n";
  print "   -nbin <num>           number phase bins [default 1024]\n";
  print "   -dm <dm>              use specified DM [default 2000]\n";
  print "   -gpu <device>         CUDA device to use [default 0]\n";
  print "   -overlap              do not use input buffering\n";
  print "   -verbose              more verbose output\n";
}

my $gpu = "0";
my $dm = "2000";
my $nbin = "1024";
my $rechan = "1";
my $verbose;
my $cfg = "mid";
my $overlap;

GetOptions( "nbin=i" => \$nbin,
            "cfg=s" => \$cfg,
            "rechan=i" => \$rechan,
            "dm=i" => \$dm,
            "gpu=i" => \$gpu,
            "overlap" => \$overlap,
            "verbose" => \$verbose) 
  or die("Error in command line options\n");


if ($#ARGV != 1)
{
  print STDERR "ERROR: 2 command line arguments expected, found ".($#ARGV+1)."\n";
  usage();
  exit(1);
}

my $nchan   = $ARGV[0];
my $cfreq = $ARGV[1];
my ($osd, $osn, $os_factor, $tsamp, $nsamps_res, $chan_bw);
if ($cfg eq "low")
{
  $osd = 4;
  $osn = 3;
  $os_factor = "4/3";
  $chan_bw = 0.003616898148;
  $tsamp = 207.36;
  $nsamps_res = 32;
}
else
{
  $osd = 8;
  $osn = 7;
  $os_factor = "8/7";
  $chan_bw = 0.05376;
  $tsamp = 16.276041667;
  $nsamps_res = 4;
}

my $bench_dir = `pwd`;
chomp $bench_dir;
$bench_dir =~ s/\/scripts//;

if ($nchan % $rechan != 0)
{
  print STDERR "ERROR: nchan [$nchan] must be a multiple of $rechan\n";
  exit(1);
}

my $nchan_out = $nchan / $rechan;
my $bw = $nchan * $chan_bw;
my $npol = 2;
my $ndim = 2;
my $nbyte = 1;
my $noverlap = 128;
my $shm_max = `cat /proc/sys/kernel/shmmax`;
chomp $shm_max;

# check memory sizes
my $resolution = $nchan * $npol * $ndim * $nsamps_res;

# aim for memory block at least 32 MB in size
print "RESOLUTION=".$resolution."\n";


my $block_size = $resolution;
while ( $block_size < 33554432 )
{
  $block_size *= 2;
}

my $mibytes_per_second = $bw * $npol * $ndim * $osd / $osn;
my $bytes_per_second = $mibytes_per_second * 1000000;
my $results_dir = $bench_dir."/results";
my $header_dir = $bench_dir."/headers";
my $header_file = "header.CFREQ_$cfreq.BW_".int($bw).".NCHAN_$nchan";
my $header = "$header_dir/$header_file";

# setup the header
{
  `cp $header_dir/header.template.ipfb $header`;
  `sed -i -e "s|__BW__|$bw|" $header`;
  `sed -i -e "s|__FREQ__|$cfreq|" $header`;
  `sed -i -e "s|__NCHAN__|$nchan|" $header`;
  `sed -i -e "s|__RESOLUTION__|$resolution|" $header`;
  `sed -i -e "s|__TSAMP__|$tsamp|" $header`;
  `sed -i -e "s|__BYTES_PER_SECOND__|${bytes_per_second}|" $header`;
  `sed -i -e "s|__OS_FACTOR__|${os_factor}|" $header`;
  `sed -i -e "s|__PFB_NCHAN__|${nchan}|" $header`;

  print "CFREQ=$cfreq BW=".int($bw)." NCHAN=$nchan RESOLUTION=$resolution\n";
}

# setup the dada stuff
my $dada_info = $bench_dir."/aaaa.info";
if ( -f $dada_info )
{
  unlink ($dada_info);
}

open FH, ">$dada_info";
print FH "DADA INFO:\n";
print FH "key aaaa\n";
close FH;

# be sure that no SHM block named aaaa exists
my $key_count = `ipcs | grep aaaa | wc -l`;
chomp $key_count;
if ( $key_count > 0 )
{
  `dada_db -k aaaa -d > /dev/null 2>&1`;
}

my $nfft = 128;
my $fft_overlap = 2;
my $nchan_fine = $nchan * $nfft;

# find the minimum bwd fft
my $fft32 = `dmsmear -d $dm -b $bw -f $cfreq -n $nchan_fine 2>&1 | grep 'Minimum Kernel Length' | awk '{print (\$4) * 2}'`;
chomp $fft32;
if ($verbose)
{
  print "dmsmear -d $dm -b $bw -f $cfreq -n $nchan_fine\n";
  print "fft32=".$fft32."\n";
}

# create the datablock
my $cmd = "dada_db -k aaaa -b $block_size -c 0 -l -n 16 -p > /dev/null 2>&1";
if ($verbose)
{
  print $cmd."\n";
}
`$cmd`;

chdir "/dev/shm";

my $ephem = $bench_dir."/pulsar.par";
my $polyco = $bench_dir."/polyco.dat";

my %perf = ();

my $result = "$results_dir/result.CFREQ_$cfreq.BW_".int($bw).".NCHAN_$nchan.NBIN_$nbin.DM_$dm.NFFT_$nfft";
if ($verbose)
{
  print $header."\n";
}

my $junk_thread = threads->new(\&junkThread, "aaaa", $mibytes_per_second, $header);
  
sleep 1;

$cmd = "dspsr";
if ($overlap)
{
  $cmd .= " -overlap";
}

$cmd .= " -Q -cuda $gpu -minram 7000";
$cmd .= " -IF $nchan_out:D:32 -b $nbin -E $ephem -P $polyco $dada_info -no_dyn -r";

if ($verbose)
{
   print "cmd=".$cmd."\n";
   print "output=".$result."\n";
}
`( /usr/bin/time -f '%e' $cmd ) > $result 2>&1`;

if ( $? != 0 ) 
{
  print "dspsr had a non zero return value\n";

  # given dspsr failed, we must kill dada_junkdb
  `pkill ^dada_junkdb`;

  my $mem_bad = `grep "out of memory" $result | wc -l`;
  chomp $mem_bad;
  if ( $mem_bad eq "1" )
  {
    my $mem_required = `grep "dspsr: blocksize=" $result | awk '{print \$5, \$6}'`;
    chomp $mem_required;
    print "ERROR: dspsr ran out of memory: ".$mem_required."\n";
    if ($verbose)
    {
      system("cat $result");
    }
  }
}
else
{
  my $preptime = `grep prepared $result | awk '{print \$4}'`;
  chomp $preptime;
  my $unloadtime = `grep dsp::Archiver::unload $result | awk  '{print \$3}'`;
  if ($unloadtime ne "")
  {
    chomp $unloadtime;
  }
  else
  {
    $unloadtime = 0;
  }
  my $realtime = `tail -n 1 $result`;
  chomp $realtime;
  #print "prep=$preptime unload=$unloadtime real=$realtime\n";
  my $percent_real = ($realtime - ($preptime + $unloadtime)) / 60;
  print "$nfft $percent_real\n"
}

$junk_thread->join();

`dada_db -k aaaa -d > /dev/null 2>&1`;

exit 0;

########################################

sub junkThread($$$)
{
  my ($key, $rate, $header) = @_;

  my $ten_rate = 60.0 * $rate;
  my $cmd = "dada_junkdb -g -k $key -R $ten_rate -z -t 1 -n $header";
  if ($verbose)
  {
    print $cmd."\n";
  }
  `$cmd > /dev/null 2>&1`;

  return 0;
}
