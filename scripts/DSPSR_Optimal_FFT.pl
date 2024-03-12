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
  print "$0: [opts] bw freq\n";
  print "compute optimal FFT length for given bw and freq\n\n";
  print "   bw                    total bandwidth to process\n";
  print "   freq                  centre frequnecy of the total bandwidth\n";
  print "   -bw_coarse <num>      bandwidth in coarse channel [default 10]\n";
  print "   -nbin <num>           number phase bins [default 1024]\n";
  print "   -nchan_coarse <num>   number of coarse frequnecy channels [default bw/10]\n";
  print "   -nchan_fine <num>     number of fine frequnecy channels [default bw/10]\n";
  print "   -dm <dm>              use specified DM [default 2000]\n";
  print "   -gpu <device>         CUDA device to use [default 0]\n";
  print "   -overlap              do not use input buffering\n";
  print "   -verbose              more verbose output\n";
}

my $gpu = "0";
my $dm = "2000";
my $nbin = "1024";
my $verbose;
my $nchan_coarse = -1;
my $nchan_fine = -1;
my $bw_coarse = 10;
my $overlap;

GetOptions( "nbin=i" => \$nbin,
            "nchan_fine=i" => \$nchan_fine,
            "nchan_coarse=i" => \$nchan_coarse,
            "bw_coarse=f" => \$bw_coarse,
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

my $bw   = $ARGV[0];
my $cfreq = $ARGV[1];
if ($nchan_coarse == -1)
{
  $nchan_coarse = $bw / $bw_coarse;
}
if ($nchan_fine == -1)
{
  $nchan_fine   = $bw / $bw_coarse;
}

my $bench_dir = `pwd`;
chomp $bench_dir;
$bench_dir =~ s/\/scripts//;

my $npol = 2;
my $ndim = 2;
my $nbyte = 1;
my $shm_max = `cat /proc/sys/kernel/shmmax`;
chomp $shm_max;

# resoultion is always 1024 samples
my $nsamps_res = 1024;

# check memory sizes
my $resolution = $nchan_coarse * $npol * $ndim * $nsamps_res;

# aim for memory block at least 32 MB in size
print "RESOLUTION=".$resolution."\n";


my $block_size = $resolution;
while ( $block_size < 33554432 )
{
  $block_size *= 2;
}

#my $max_res = 31457280;
#while ( ( $resolution >= $shm_max ) or ( $resolution > $max_res ) )
#{
#  $nsamps_res /= 2;
#  $resolution = $nchan_coarse * $npol * $ndim * $nsamps_res;
#  print "trying smaller nsamps_res [$nsamps_res] -> resolution [$resolution]\n"
#}

my $mibytes_per_second = $bw * $npol * $ndim;
my $bytes_per_second = $mibytes_per_second * 1000000;
my $results_dir = $bench_dir."/results";
my $header_dir = $bench_dir."/headers";
my $header_file = "header.CFREQ=$cfreq.BW=$bw.NCHAN=$nchan_coarse";
my $header = "$header_dir/$header_file";
my $tsamp = 1 / $bw_coarse;

# setup the header
{
  `cp $header_dir/header.template $header`;
  `perl -i -p -e "s/__BW__/$bw/" $header`;
  `perl -i -p -e "s/__FREQ__/$cfreq/" $header`;
  `perl -i -p -e "s/__NCHAN__/$nchan_coarse/" $header`;
  `perl -i -p -e "s/__RESOLUTION__/$resolution/" $header`;
  `perl -i -p -e "s/__TSAMP__/$tsamp/" $header`;
  `perl -i -p -e "s/__BYTES_PER_SECOND__/${bytes_per_second}/" $header`;

  print "CFREQ=$cfreq BW=$bw NCHAN=$nchan_fine RESOLUTION=$resolution\n";
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

# find the minimum bwd fft
`dmsmear -d $dm -b $bw -f $cfreq -n $nchan_fine 2>&1 | grep 'Minimum Kernel Length' | awk '{print (\$4) * 2}'`;
my $bwd_fft = `dmsmear -d $dm -b $bw -f $cfreq -n $nchan_fine 2>&1 | grep 'Minimum Kernel Length' | awk '{print (\$4) * 2}'`;
chomp $bwd_fft;
if ($verbose)
{
  print "dmsmear -d $dm -b $bw -f $cfreq -n $nchan_fine\n";
  print "bwd_fft=".$bwd_fft."\n";
}

if ($bwd_fft < 1024) {
  $bwd_fft = 1024;
}


# create the datablock
my $cmd = "dada_db -k aaaa -b $block_size -l -n 16 -p > /dev/null 2>&1";
if ($verbose)
{
  print $cmd."\n";
}
`$cmd`;

chdir "/dev/shm";

my $ephem = $bench_dir."/pulsar.par";
my $polyco = $bench_dir."/polyco.dat";

my $mem_bad = 0;

my %perf = ();

while (!$mem_bad)
{
  if ($verbose)
  {
    print "testing bwd_fft=$bwd_fft nchan_coarse=$nchan_coarse nchan_fine=$nchan_fine\n";
  }

  my $result = "$results_dir/result.CFREQ=$cfreq.BW=$bw.NCHAN=$nchan_fine.NBIN=$nbin.DM=$dm.BWDFFT=$bwd_fft";
  if ($verbose)
  {
    print $header."\n";
  }

  my $junk_thread = threads->new(\&junkThread, "aaaa", $mibytes_per_second, $header);
  
  sleep 1;

  my $cmd = "dspsr";
  if ($overlap)
  {
    $cmd .= " -overlap";
  }

  $cmd .= " -Q -D $dm -cuda $gpu -minram 8000";

  if ($nchan_coarse == $nchan_fine)
  {
    $cmd .= " -b $nbin -x $bwd_fft -E $ephem -P $polyco $dada_info -no_dyn";
  } 
  else
  {
    $cmd .= " -F $nchan_fine:D -b $nbin -x $bwd_fft -E $ephem -P $polyco $dada_info -no_dyn";
  }

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

    $mem_bad = `grep "out of memory" $result | wc -l`;
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
    print "prep=$preptime unload=$unloadtime real=$realtime\n";
    my $percent_real = ($realtime - ($preptime + $unloadtime)) / 10;
    #if ($percent_real > 3)
    #{
    #  $mem_bad = 1;
    #}
    $perf{$bwd_fft} = $percent_real;
    print "bwd_fft=$bwd_fft percent_real=$percent_real\n"
  }

  $junk_thread->join();

  $bwd_fft *= 2;

  if ($bwd_fft > 8388608)
  {
    $mem_bad = 1;
  }
}

my $best_fft = "none";
my $best_perf = "10";

foreach $bwd_fft ( keys %perf )
{
  if ($perf{$bwd_fft} < $best_perf)
  {
    $best_perf = $perf{$bwd_fft};
    $best_fft = $bwd_fft;
  }
}

print "$best_fft $best_perf\n";

`dada_db -k aaaa -d > /dev/null 2>&1`;

exit 0;

########################################

sub junkThread($$$)
{
  my ($key, $rate, $header) = @_;

  my $ten_rate = 10.0 * $rate;
  my $cmd = "dada_junkdb -g -k $key -R $ten_rate -z -t 1 -n $header";
  if ($verbose)
  {
    print $cmd."\n";
  }
  `$cmd > /dev/null 2>&1`;

  return 0;
}
