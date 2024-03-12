#!/bin/tcsh

set dir = $1

cd $dir

set results = `ls -1 result.* | sort -n`

echo "DM,NBIN,NCHAN,CFREQ,BW,BWDFFT,TIME_DADA,TIME_UPCK,TIME_FB,TIME_DET,TIME_FOLD,TIME_REAL,TIME_PREP,TIME_UNLOAD,PERCENT_REALTIME"

foreach result ( $results )

  set cfreq  = `echo $result | awk -F. '{print $2}' | awk -F= '{print $2}'`
  set bw     = `echo $result | awk -F. '{print $3}' | awk -F= '{print $2}'`
  set nchan  = `echo $result | awk -F. '{print $4}' | awk -F= '{print $2}'`
  set nbin   = `echo $result | awk -F. '{print $5}' | awk -F= '{print $2}'`
  set dm     = `echo $result | awk -F. '{print $6}' | awk -F= '{print $2}'`
  set bwdfft = `echo $result | awk -F. '{print $7}' | awk -F= '{print $2}'`

  set time_dada_buffer   = `grep "^DADABuffer     " $result | awk '{print $2}'`
  set time_ska1_unpacker = `grep "^SKA1Unpacker     " $result | awk '{print $2}'`
  set time_filterbank    = `grep "^Filterbank     " $result | awk '{print $2}'`
  set time_detection     = `grep "^Detection     " $result | awk '{print $2}'`
  set time_fold          = `grep "^Fold     " $result | awk '{print $2}'`

  set fail = `grep "Command exited with non-zero status" $result | wc -l`
  set oom = `grep "out of memory" $result | wc -l`
  set term = `grep "Command terminated by signal" $result | wc -l`

  set preptime = `grep prepared $result | awk '{print $4}'`
  set realtime = `tail -n 1 $result`
  #set realtime = `grep -F % $result| grep -v Operation | awk '{print $3}' | awk -F: '{print $1*60 + $2}'`
  set unloadtime = `grep dsp::Archiver::unload $result | awk  '{print $3}'`
  set percent_real = `echo $realtime $preptime $unloadtime | awk '{print ($1-($2+$3))/10}'`

	 if ( ( $oom == 0 ) && ( $fail == 0 ) && ( $term == 0) ) then
    echo "$dm,$nbin,$nchan,$cfreq,$bw,$bwdfft,$time_dada_buffer,$time_ska1_unpacker,$time_filterbank,$time_detection,$time_fold,$realtime,$preptime,$unloadtime,$percent_real"
  endif

end
