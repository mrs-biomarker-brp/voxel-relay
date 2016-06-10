#!/usr/local/bin/perl
#
# BRPtransfer.pl - process to transfer MPRage to BRP server, retrieve template
# and send template back to scanner
#
# assumes all data is Enhanced MR format (i.e. 1 image per series)
#
# Joe Gillen - Johns Hopkins SOM - 2016/06/08

use strict;
use warnings;
use English;
use IO::Socket::PortState qw(check_ports);
use File::Find;
my $version = "v1.0";
my ($landingZone, $dcmtk, $storescp, $storescu, $findscu, $getscu, $dcmdump);

#-configure--------------------------------------------------------------------
if ($OSNAME ne "MSWin32") {
  $dcmtk = "/Applications/dcm4che-3.3.7";
} else {
  $dcmtk = "C:/Progra~1/dcm4che-3.3.7";
}

# used for storescp server which receives MPRAGE from scanner
my $myaet = "KIRBY_SCU";
my $myserver = "10.8.33.159";
my $myport = 4444;

# remote server at Minnesota used for storescu to send MPRAGE and
# findscu and getscu to retrieve template
my $BRPaet = "BRP_CMRR";
my $BRPserver = "10.8.33.159"; # "brp.cmrr.umn.edu";
my $BRPport = 1104; #104

# local scanner who sends MPRAGE and used for storescu to send template
#my $scanaet = "MR1";
#my $scanserver = "mr1";
#my $scanport = 3010;
my $scanaet = "godzilla2";
my $scanserver = "godzilla.kennedykrieger.org";
my $scanport = 4444;

my $templateID = "Template";	# series description of template for verify
my $scanDelay = 10;		# seconds to sleep between dir scans
my $prcDelay = 10;		# seconds to sleep before looking for template
my $reDelay = 2;		# seconds to sleep between retries
my $retries = 10;		# number of times for check for template

$landingZone = "$ENV{HOME}/BRPdicom";
$storescp = "$dcmtk/bin/storescp";
$storescu = "$dcmtk/bin/storescu";
$findscu  = "$dcmtk/bin/findscu";
$getscu   = "$dcmtk/bin/getscu";
$dcmdump  = "$dcmtk/bin/dcmdump";

#------------------------------------------------------------------------------
END {
  # shutdown the receiver
  if ($OSNAME ne "MSWin32") {
    open PIPE, "ps -ej |";
    while (<PIPE>) {
      m|^$ENV{USER}\s+(\d+)\s+.*$dcmtk/etc/storescp/| and kill 'HUP', $1;
    }
  } else {
    # need something for Windoze
  }
}

#------------------------------------------------------------------------------
unless (-d $landingZone) {
  mkdir $landingZone or
    die "No directory to receive images ($landingZone): $!\n";
}

# start dicom server if not running
my %port_hash = ( tcp => { $myport => {}, } );
check_ports ($myserver, 5, \%port_hash);
unless ($port_hash{tcp}->{$myport}->{open}) {
  print "Starting local DICOM receiver\n";
  &doSystem ($storescp, "-b", "$myaet:$myport", "--directory",
	     $landingZone, "&");
} else {
  print "DICOM receiver already running\n";
}

my $first = 1; my $newest = 0; my $cnewest = 0;
while (1) {
  print "Scanning DICOM directory: ", scalar localtime($cnewest), "\n";
  find (\&process_file, $landingZone);
  sleep $scanDelay;
  $cnewest = $newest;
  $first = 0;
}

#------------------------------------------------------------------------------
sub process_file {
  my $file = $_;
  ! -f $file || $file =~ /^\./ and return;	# only file, no dot file
  my $mdt = (stat($file))[9];			# modification date
  if ($first) {					# first pass through dir
    $mdt > $newest and $newest =  $mdt;		# record age of youngest file
  }
  # all other passes - any file newer than newest is processed
  elsif ($mdt > $cnewest) {
    print "New file: $file\n";
    $mdt > $newest and $newest = $mdt;
    # make sure file is complete
    my $size = 0;
    while ((my $cs = -s $file) != $size) {
      $size = $cs;
    }
    # send the new file to BRP
    print "Send to $BRPserver\n";
    &doSystem ($storescu, "-b", "$myaet\@$myserver",
	       "-c", "$BRPaet\@$BRPserver:$BRPport", $file);
    # pull out patient and study ids
    my %dcm;
    &dcmdump ($file, "StudyInstanceUID|SeriesNumber", \%dcm);
    print "Study: $dcm{StudyInstanceUID} | Series: $dcm{SeriesNumber}\n";

    # check BRP server for new series with this study id
    my $delay = $prcDelay;
    for (my $tries = 0; $tries < $retries; $tries++) {
      sleep $delay;
      print "Querying...";
      &doSystem ($findscu,
		 "-b", "$myaet\@$myserver",
		 "-c", "$BRPaet\@$BRPserver:$BRPport",
		 "-m", "'StudyInstanceUID=$dcm{StudyInstanceUID}'",
		 "-r", "SeriesNumber", "-r", "SeriesInstanceUID",
		 "-L", "SERIES",
		 "--out-dir", $landingZone, "--out-file", "response.dcm");
      my @resp = <$landingZone/response*.dcm>;
      print scalar @resp, " responses\n";
      foreach my $resp (@resp) {
	my %rsp = ();
	&dcmdump ($resp, "StudyInstanceUID|SeriesInstanceUID|SeriesNumber",
		  \%rsp);
	unlink $resp;
	# see if new series
	if ($rsp{SeriesNumber} eq $dcm{SeriesNumber}) {
	  print "Skip MPRAGE series\n";
	  next;
	}
	print "New series: $rsp{SeriesNumber}\n";
	# get the SOP Instance UID
	&doSystem ($findscu,
		   "-b", "$myaet\@$myserver",
		   "-c", "$BRPaet\@$BRPserver:$BRPport",
		   "-m", "StudyInstanceUID=$rsp{StudyInstanceUID}",
		   "-m", "SeriesInstanceUID=$rsp{SeriesInstanceUID}",
		   "-r", "SOPInstanceUID", "-L", "IMAGE",
		   "--out-dir", $landingZone,
		   "--out-file", "image.dcm");
	my $rspfile = "$landingZone/image1.dcm";
	-f $rspfile or die "findscu image failed";
	my %sop;
	&dcmdump ($rspfile, "SOPInstanceUID", \%sop);
	unlink $rspfile;
	# get the file
	print "C-GET Images\n";
	&doSystem ($getscu,
		   "-b", "$myaet\@$myserver",
		   "-c", "$BRPaet\@$BRPserver:$BRPport",
		   "-m", "StudyInstanceUID=$rsp{StudyInstanceUID}",
		   "-m", "SeriesInstanceUID=$rsp{SeriesInstanceUID}",
		   "-L", "SERIES",
		   "--directory", $landingZone);
	my $templ = "$landingZone/$sop{SOPInstanceUID}";
	-f $templ or
	  die "getscu: no file for SOP $sop{SOPInstanceUID}\n";
	# verify it is the template
	%rsp = ();
	&dcmdump ($templ, "SeriesDescription", \%rsp);
	if ($rsp{SeriesDescription} eq $templateID) {
	  # send it to scanner
	  print "Sending $rsp{SeriesDescription} to scanner\n";
	  &doSystem ($storescu, "-b", "$myaet\@$myserver",
		     "-c", "$scanaet\@$scanserver:$scanport", $templ);
	  return;
	} else {
	  print "Skipping - SeriesDescription: $rsp{SeriesDescription}\n";
	}
	unlink $templ;
      }
      $delay = $reDelay; # delay for retries
    }
    print "Giving up looking for template for $file\n";
  }
}

#------------------------------------------------------------------------------
# run dcmdump and retrieve selected fields into hash
sub dcmdump {
  my ($file, $tags, $hashref) = @_;
  my $cmd = "$dcmdump -w 200 $file";
  open PIPE,  "$cmd |" or die "Pipe failed $cmd: $!";
  while (<PIPE>) {
    /^\d+: \([0-9A-F]{4},[0-9A-F]{4}\) .. #\d+ \[(.*)\] ($tags)$/
      and $hashref->{$2} = $1;
  }
  close PIPE;
  keys %{$hashref} == split /\|/, $tags or
    die "Problem reading DICOM file - fields: $tags\n";
}

#------------------------------------------------------------------------------
# do a command using system with full error check
sub doSystem {
  my $rc = 0xffff & system ("@_") or return;          # success
  if ($rc == 0xff00) {
    die "$_[0]: command error: $!\n";                 # system() failed
  }
  elsif (($rc & 0xff) == 0) {
    die "$_[0]: exit status " . ($rc >> 8), "\n";     # non-zero exit status
  }
  else {
    die "$_[0]: ", ($rc & 0x80 ? "coredump, " : ""),  # dumped and...
	    "signal ", ($rc & ~0x80), "\n";           # died on signal
  }
}
