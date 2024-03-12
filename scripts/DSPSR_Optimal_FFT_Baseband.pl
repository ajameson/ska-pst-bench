#!/usr/bin/env perl

#
# Run DSPSR to find optimal BWD FFT length for the given parameters
#
#   Assumptions:
#     PSRDada Ring buffer input format
#     no input channelisation

use constant BASE_DIR => "/home/ajameson/ska1_prototyping";

use strict;
use warnings;
use threads;
use Getopt::Long;
sub usage();

sub usage()
{
  print "$0: [opts] bw freq\n";
  print "compute optimal FFT length for given bw and freq\n\n";
  print "   bw          total bandwidth to process\n";
  print "   freq        centre frequnecy of the total bandwidth\n";
  print "   -b nbin     number of phase bins [default 1024]\n";
  print "   -c nchan    number of fine frequnecy channels [default bw]\n";
  print "   -d dm       use specified DM [default 2000]\n";
  print "   -g gpu      gpu device to use [default 0]\n";
}

my $gpu = "0";
my $dm = "2000";
my $nbin = "1024";
my $verbose;
my $nchan_fine = -1;

GetOptions( "nbin=i" => \$nbin,
            "nchan=i" => \$nchan_fine,
            "dm=i" => \$dm,
            "gpu=i" => \$gpu,
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
my $nchan_coarse = 1;
if ($nchan_fine == -1)
{
  $nchan_fine   = $bw;
}


my $npol = 2;
my $ndim = 2;
my $nbyte = 1;
my $shm_max = `cat /proc/sys/kernel/shmmax`;
chomp $shm_max;

# check memory sizes
my $nsamps_res = 253952;
my $resolution = $nchan_coarse * $npol * $ndim * $nsamps_res;
while ( $resolution >= $shm_max )
{
  $nsamps_res /= 2;
  $resolution = $nchan_coarse * $npol * $ndim * $nsamps_res;
  print "trying samller nsamps_res [$nsamps_res] -> resolution [$resolution]\n"
}

my $mibytes_per_second = $bw * $npol * $ndim;
my $results_dir = BASE_DIR."/results";
my $header_dir = BASE_DIR."/headers";
my $header_file = "header.CFREQ=$cfreq.BW=$bw.NCHAN=$nchan_coarse";
my $header = "$header_dir/$header_file";

# setup the header
{
  `cp $header_dir/header.template $header`;
  `perl -i -p -e "s/__BW__/$bw/" $header`;
  `perl -i -p -e "s/__FREQ__/$cfreq/" $header`;
  `perl -i -p -e "s/__NCHAN__/$nchan_coarse/" $header`;
  `perl -i -p -e "s/__RESOLUTION__/$resolution/" $header`;
  `perl -i -p -e "s/__BYTES_PER_SECOND__/${mibytes_per_second}000000/" $header`;

  print "CFREQ=$cfreq BW=$bw NCHAN=$nchan_fine RESOLUTION=$resolution\n";
}

# setup the dada stuff
my $dada_info = BASE_DIR."/aaaa.info";
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
if ( $key_count eq "20" )
{
  `dada_db -k aaaa -d >& /dev/null`;
}

# find the minimum bwd fft
my $bwd_fft = `dmsmear -d $dm -b $bw -f $cfreq -n $nchan_fine |& grep 'Minimum Kernel Length' | awk '{print (\$4 * 2)}'`;
chomp $bwd_fft;

# create the datablock
`dada_db -k aaaa -b $resolution -l -n 16 -p >& /dev/null`;

chdir "/dev/shm";

my $ephem = BASE_DIR."/pulsar.par";
my $polyco = BASE_DIR."/polyco.dat";

my $mem_bad = 0;

my %perf = ();

while (!$mem_bad)
{
  if ($verbose)
  {
    print "testing bwd_fft=$bwd_fft nchan_coarse=$nchan_coarse nchan_fine=$nchan_fine\n";
  }

  my $result = "$results_dir/result.CFREQ=$cfreq.BW=$bw.NCHAN=$nchan_fine.NBIN=$nbin.DM=$dm.BWDFFT=$bwd_fft";

  my $junk_thread = threads->new(\&junkThread, "aaaa", $mibytes_per_second, $header);
  
  sleep 1;

  my $cmd = "~/dspsr/Signal/Pulsar/dspsr -r -D $dm -cuda $gpu -minram 4096 -F $nchan_fine:D -b $nbin -x $bwd_fft -E $ephem -P $polyco $dada_info";
  `( /usr/bin/time -f '%e' $cmd ) >& $result`;

  if ( $? != 0 ) 
  {
    # given dspsr failed, we must kill dada_junkdb
    `pkill ^dada_junkdb`;

    $mem_bad = `grep "out of memory" $result | wc -l`;
    chomp $mem_bad;
    if ( $mem_bad eq "1" )
    {
      my $mem_required = `grep "dspsr: blocksize=" $result | awk '{print \$5, \$6}'`;
      chomp $mem_required;
      print "ERROR: dspsr ran out of memory: ".$mem_required."\n";
    }
  }
  else
  {
    my $preptime = `grep prepared $result | awk '{print \$4}'`;
    chomp $preptime;
    my $unloadtime = `grep dsp::Archiver::unload $result | awk  '{print \$3}'`;
    chomp $unloadtime;
    my $realtime = `tail -n 1 $result`;
    chomp $realtime;
    my $percent_real = ($realtime - ($preptime + $unloadtime)) / 10;
    print "prep=$preptime unload=$unloadtime real=$realtime\n";
    #if ($percent_real > 3)
    #{
    #  $mem_bad = 1;
    #}
    $perf{$bwd_fft} = $percent_real;
    print "bwd_fft=$bwd_fft percent_real=$percent_real\n"
  }

  $junk_thread->join();

  $bwd_fft *= 2;
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

`dada_db -k aaaa -d >& /dev/null`;

exit 0;

########################################

sub junkThread($$$)
{
  my ($key, $rate, $header) = @_;

  $rate .= "0";
  my $cmd = "dada_junkdb -k $key -R $rate -z -t 1 $header";
  `$cmd >& /dev/null`;

  return 0;
}
