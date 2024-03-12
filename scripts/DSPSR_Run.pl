#!/usr/bin/env perl

#
# Run DSPSR to find optimal BWD FFT length for the given parameters
#
#   Assumptions:
#     PSRDada Ring buffer input format
#     10 MHz Channels

use constant BASE_DIR => "/home/ajameson/ska1_prototyping";

use strict;
use warnings;
use threads;
use Getopt::Long;
sub usage();

sub usage()
{
  print "$0: [opts] bw freq\n";
  print "Run dspsr with the specified bw, cfreq and fft lengthfreq\n\n";
  print "   bw          total bandwidth to process\n";
  print "   freq        centre frequnecy of the total bandwidth\n";
  print "   bwd_fft     length of inverse FFT\n";
  print "   -c nchan    number of fine frequnecy channels [default bw/10]\n";
  print "   -d dm       use specified DM [default 1000]\n";
  print "   -g gpu      gpu device to use [default 0]\n";
}

my $gpu = "0";
my $dm = "1000";
my $verbose;
my $nchan_fine = -1;
my $nbin = 1024;

GetOptions( "nbin=i" => \$nbin, 
            "nchan=i" => \$nchan_fine,
            "dm=i" => \$dm,
            "gpu=i" => \$gpu,
            "verbose" => \$verbose) 
  or die("Error in command line options\n");


if ($#ARGV != 2)
{
  print STDERR "ERROR: 3 command line arguments expected, found ".($#ARGV+1)."\n";
  usage();
  exit(1);
}

my $bw   = $ARGV[0];
my $cfreq = $ARGV[1];
my $bwd_fft = $ARGV[2];

my $nchan_coarse = $bw / 10;
if ($nchan_fine == -1)
{
  $nchan_fine   = $bw / 10;
}

my $npol = 2;
my $ndim = 2;
my $coarse_bw = 10;
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

# create the datablock
`dada_db -k aaaa -b $resolution -l -n 16 -p >& /dev/null`;

chdir "/dev/shm";

my $ephem = BASE_DIR."/pulsar.par";
my $polyco = BASE_DIR."/polyco.dat";

my $mem_bad = 0;

my %perf = ();

if ($verbose)
{
  print "testing bwd_fft=$bwd_fft nchan_coarse=$nchan_coarse nchan_fine=$nchan_fine\n";
}

my $result = "$results_dir/result.CFREQ=$cfreq.BW=$bw.NCHAN=$nchan_fine.DM=$dm.BWDFFT=$bwd_fft";

my $junk_thread = threads->new(\&junkThread, "aaaa", $mibytes_per_second, $header);
  
sleep 1;

my $cmd = "~/dspsr/Signal/Pulsar/dspsr -D $dm -r -cuda $gpu -minram 2048 -F $nchan_fine:D -b $nbin -x $bwd_fft -E $ephem -P $polyco $dada_info";
print $cmd."\n";
`/usr/bin/time -f '%e' $cmd`;

if ( $? != 0 ) 
{
  # given dspsr failed, we must kill dada_junkdb
  `pkill ^dada_junkdb`;
}

$junk_thread->join();

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
