#!/usr/bin/perl

# Usage: perl tarextractor.perl [ options ] <tgz file> ... [options] <tgz file> ...
# options:
# -v        increase the level of debugging messages (default 0, quietest)
# -v#       set the level of debugging messages to #
# -br       process buildResult tgz files
# -nbr      skip buildResult tgz files (default)
# -e=<dir>  put error files in the listed directory (default $XROOT/errorfiles)
#           <dir> will be created if it does not already exist
#
# environment variables:
# XROOT     root directory of the xtreemfs project tree
# JROOT     root of the jcorpus tree
#
# Expected usage example:
# export XROOT=....
# export JROOT=....
# find $XROOT/[0-9a-f] -type f -a -name '*.tgz' -print0 | xargs -0 perl tarextractor.perl -e=$JROOT/errorfiles
#
# Each <tgz file> listed on the command line needs to be a full, absolute path
# to the tgz file under XROOT.  The tgz file will be tested for errors, listed,
# and if it contains java, jar, class, or special files, those files will be
# extracted to a matching directory under JROOT.
#
# Extracted buildResults files are extracted to a directory matching the
# project directory plus the string "-BR" appended.
#
# Error files are created in the errorfiles directory.  The basename of the
# tgz file serves as the root name <rn> of the error files.  <rn>.stderr is
# a temporary file used to capture the STDERR output of the tar command.
# The <rn>.stderr file should be processed after the tar execution and deleted
# so it should not exist permanently.  If an error is detected in a tgz file
# that prevents it from process extracted then a permanent error file <rn>.error
# is created that contains the text of the errors.  If a tgz file does not
# meet the necessary conditions to be extracted (i.e. zero bytes or does not
# contain any "interesting" files) then permanent error file <rn>.skip is
# created.  If there are any non-fatal messages from processing the tgz file,
# those messages are saved in a permanent error file <rn>.warning.

use strict;
use File::Basename;
use File::Path qw( make_path remove_tree );

my @tarpatterns = qw(index.json filter.json uciMaven/info.json uciMaven/languages.json uciMaven/comments.json github/info.json github/languages.json github/comments.json uci2010/info.json uci2010/languages.json uci2010/comments.json uci2011/info.json uci2011/languages.json uci2011/comments.json);

my @TARPATTERN;
my $XROOT;
my $JROOT;
my $JARCENTRAL;
my $EFDIR;

my $TAR;

my $VERBOSE = 0;
my $DOBR = 0;

##############################################################################

sub init () {
    if ( defined $ENV{'XROOT'} ) { $XROOT = $ENV{'XROOT'}; } else { e_error(); }
    $XROOT = addslash($XROOT);
    die "Cannot find XROOT directory\n" unless (-d $XROOT);
    debug(1) and print "XROOT set to $XROOT\n";

    if ( defined $ENV{'JROOT'} ) { $JROOT = $ENV{'JROOT'}; } else { e_error(); }
    $JROOT = addslash($JROOT);
    die "Cannot find JROOT directory\n" unless (-d $JROOT);
    debug(1) and print "JROOT set to $JROOT\n";

    $EFDIR = $XROOT . 'errorfiles/';
    debug(1) and print "EFDIR set to $EFDIR\n";

    chomp($TAR   = `which tar`);
    #print "External programs $TAR\n";
}

sub e_error () {
    die 'tarextractor.perl requires values for the environment variables XROOT, JROOT';
}

sub addslash {
    my $d = shift;
    return $d if (substr($d, -1) eq '/');
    return $d . '/';
}

##############################################################################

sub main {
    foreach my $arg (@ARGV) {
	if ($arg eq '-v')   { $VERBOSE++; next; }
	if ($arg =~ m|^-v(\d+)$|) { $VERBOSE = $1; next; }
	if ($arg eq '-br')  { $DOBR = 1; next; }
	if ($arg eq '-nbr') { $DOBR = 0; next; }
	if ($arg =~ m|^-e=(.+)$|) { $EFDIR = addslash($1); reset_dir_exists(); next; }
	next unless (-f $arg);
	next unless ($arg =~ /\.tgz$/);
	debug(1) and print "Processing file $arg\n";
	process_tar($arg);
    }
}

##############################################################################

sub process_tar {
    my $tar = shift;

    debug(0) and print "Processing TGZ file $tar\n";

    if ($tar =~ m|/buildResults/|) {
	if ($DOBR == 0) {
	    debug(1) and print "Skip $tar, skipping files under buildResults\n";
	    return;
	}
    }

    my $target = xroot2jroot($tar);
    if ($target eq '') {
	debug(1) and print "Skip $tar, xroot2jroot returned empty target\n";
	return;
    }
    # TODO: reinstall this next check and make it dependent on a command line switch
    # if (-d $target) {
    # 	debug(1) and print "Skip $tar, target directory $target already exists\n";
    # 	return;
    # }

    my ($stderrfile, $errorfile, $warningfile, $skipfile) = make_error_files($tar);
    if (-f $stderrfile) {
	# this should never occur
	debug(0) and print "Skip $tar, stderr file $stderrfile already exist\n";
	return;
    }
    if (-f $errorfile) {
	debug(1) and print "Skip $tar, error file $errorfile already exists\n";
	return;
    }
    if (-f $skipfile) {
	debug(1) and print "Skip $tar, skip file $skipfile already exists\n";
	return;
    }

    my $tsize = -s $tar;
    if ($tsize == 0) {
	run_touch($skipfile);
	debug(1) and print "Skip $tar, file is zero bytes\n";
	return;
    }

    my ($javacount, $jarcount, $classcount, $others) = check_tar($tar, $stderrfile, $errorfile, $warningfile);

    if (($javacount + $jarcount + $classcount + $others) == 0) {
	run_touch($skipfile);
	debug(1) and print "Skip $tar, contains no extractions files\n";
	return;
    }

    debug(1) and print "Extracting TGZ file $tar\n";
    extract_tar($tar, $target);
}

##############################################################################

sub extract_tar {
    my ($tar, $target) = @_;

    debug(1) and print "Extract $tar to $target\n";

    my $tmptar = "tmptarfile.$$";

    unless (-f $tar) {
	print "ERROR: TGZ file $tar does not exist\n";
	exit(1);
    }

    unless (-d $target) {
	run_make_path($target);
	unless (-d $target) {
	    print "ERROR: cannot create '$target'\n";
	    exit(1);
	}
    }

    my @cmd = ($TAR, 'xf', $tar, '-C', $target);
    push(@cmd, @TARPATTERN);
    run_command(@cmd);
}

##############################################################################
# three cases to handle:
# a) standard tgz file (not under buildResults)
#   in:  $XROOT/3/b/8/9/c/8/3/a/3b89c83a-cd89-11e4-b0fc-5bcb3c1ab93f/3b89c83a-cd89-11e4-b0fc-5bcb3c1ab93f.tgz
#   out: $JROOT/3/b/8/9/c/8/3/a/3b89c83a-cd89-11e4-b0fc-5bcb3c1ab93f
# b) tgz file under buildResults
#   in:  $XROOT/3/b/8/9/c/8/3/a/3b89c83a-cd89-11e4-b0fc-5bcb3c1ab93f/buildResults/3b89c83a-cd89-11e4-b0fc-5bcb3c1ab93f_UCI_build.tgz
#   out: $JROOT/3/b/8/9/c/8/3/a/3b89c83a-cd89-11e4-b0fc-5bcb3c1ab93f-BR
# c) buildResults tgz file with timestamp (SKIPPING)
#   in:  $XROOT/7/8/a/6/2/7/2/a/78a6272a-4ceb-42da-93a0-b29686dc48b4/buildResults/78a6272a-4ceb-42da-93a0-b29686dc48b4-20150625T133745.tgz
#   out: $JROOT/7/8/a/6/2/7/2/a/78a6272a-4ceb-42da-93a0-b29686dc48b4-BR/20150625T133745

# Eric M. 2016-10-14: This definition is written for the case where you are
# iterating over a directory tree of tarballs, and ignoring things that
# you don't want.
# However, currently we don't call tarextractor.perl that way, we call it
# individually on each tarball that we know we want.  So it is bad for
# this to silently ignore a tarball if the extension is not recognized.
# TODO: add a switch to control whether unrecognized tarball extensions
# are considered errors or whether we should just skip them.

sub xroot2jroot {
    my $x = shift;

    unless ($x =~ m|^$XROOT|) {
	print "Path not under XROOT: $x\n";
	exit(1);
    }

    my $name = basename($x);
    if ($name =~ m|.{8}-.{4}-.{4}-.{4}-.{12}(.*)\.tgz$|) {
	my $extension = $1;
	if (($extension eq '')
	    or ($extension eq '_metadata')
	    or ($extension eq '_code')
	    or ($extension eq '_UCI_build')) {
	    # OK
	} else {
	    # skipping buildResults with timestamps (or something else)
	    debug(2) and print "xroot2jroot: $x -> ''\n";
	    return '';
	}
    } else {
	# unrecognized file name
	debug(2) and print "xroot2jroot: $x -> ''\n";
	return '';
    }

    my $path = dirname($x);
    $path =~ s|^$XROOT|$JROOT|;
    $path =~ s|/buildResults$|-BR|;

    unless ($path =~ m|^$JROOT|) {
	print "Path not under JROOT: $path\n";
	exit(1);
    }

    debug(2) and print "xroot2jroot: $x ->\n             $path\n";
    return $path;
}

##############################################################################

{
    my $directory_exists = 0;

    # when $EFDIR gets set on command line, make sure new $EFDIR exists
    # by clearing this flag.
    sub reset_dir_exists {
	$directory_exists = 0;
    }

    sub make_error_files {
	my ($file) = @_;

	my $base = basename($file);
	if ($directory_exists == 0) {
	    run_make_path($EFDIR) unless (-d $EFDIR);
	    if (-d $EFDIR) {
		$directory_exists == 1;
	    } else {
		print "ERROR: cannot create error directory $EFDIR\n";
		exit(1);
	    }
	}
	my $stderrfile  = $EFDIR . $base . '.stderr';
	my $errorfile   = $EFDIR . $base . '.error';
	my $warningfile = $EFDIR . $base . '.warning';
	my $skipfile    = $EFDIR . $base . '.skip';
	if (debug(2)) {
	    print "make_error_files() -> $stderrfile\n";
	    print "                      $errorfile\n";
	    print "                      $warningfile\n";
	    print "                      $warningfile\n";
	    print "                      $skipfile\n";
	}
	return ($stderrfile, $errorfile, $warningfile, $skipfile);
    }
}

##############################################################################

{
    my @PATS;
    sub init_patterns {
	foreach my $pat (@tarpatterns) {
	    push(@PATS, $pat);
	}
	foreach my $pat (@tarpatterns) {
	    push(@PATS, './' . $pat);
	}
    }
    my $DULL = -99;

    # The goal of check_tar is:
    # 1) skip a tar file with bad file names
    # 2) skip a tar with errors (what about date errors?)
    # 3) get a count of java/jar/class/other files to extract
    # 4) create a extract pattern for tar
    # 4a) handle the case of hard links in the extract pattern
    sub check_tar {
	my ($tar, $stderrfile, $errorfile, $warningfile) = @_;

	my %PATTERNS;
	my %WPATTERNS;
	my $javacount = 0;
	my $jarcount = 0;
	my $classcount = 0;
	my $others = 0;

	set_env('tmptar', $tar, 'tmperror', $stderrfile);
	my $command = $TAR . ' tvf "$tmptar" 2>"$tmperror"';
	debug(2) and print "Running: $command\n";
	open(CHECK, "$command |");

	my $error = '';
	my $warning = '';
	while (my $entry = <CHECK>) {
	    chomp($entry);
	    debug(2) and print "Looking at tar listing: $entry\n";
	    my ($type, $filename, $target) = getname($entry);
	    unless (($type eq 'd') or ($type eq '-') or ($type eq 'l') or ($type eq 'h')) {
		$warning .= "Unusual tar entry: $entry\n";
	    }
	    if ($filename eq '') {
		$error .= "No file name match: $entry\n";
		last;
	    }
	    if (badfilename($filename)) {
		$error .= "Bad filename in entry: $entry\n";
		last;
	    }
	    if (($type eq 'h') and ($target eq '')) {
		$error .= "No hard link target: $entry\n";
		last;
	    }
	    my $interest = interesting($filename);

	    if (($type eq 'h') and ($interest != $DULL)) {
		# We have a hard link that we want to extract
		my $target_interest = interesting($target);
		if ($target_interest == $DULL) {
		    # Problem, the underlying file will not be extracted, we have to change that.
		    $PATTERNS{$target} = 1;
		    $warning .= "Hard link addition: $entry\n";
		    debug(2) and print "Adding hard link target: $target\n";
		}
	    }

	    if (($type eq 'd') and ($interest != $DULL)) {
		$warning .= "Directory: $entry\n";
	    }

	    if (($type eq '-') or ($type eq 'h')) {
		next if ($interest == $DULL);
		if ($interest == -1) { $javacount++;  $WPATTERNS{'java'} = 1;  next; }
		if ($interest == -2) { $jarcount++;   $WPATTERNS{'jar'} = 1;   next; }
		if ($interest == -3) { $classcount++; $WPATTERNS{'class'} = 1; next; }
		$PATTERNS{$PATS[$interest]} = 1;
		$others++;
		next;
	    }
	}
	close(CHECK);

	process_error_files($stderrfile, $errorfile, $warningfile, $error, $warning);

	if (-f $errorfile) {
	    debug(1) and print "Tar errors saved in $errorfile\n";
	    return(0, 0, 0, 0);
	}

	@TARPATTERN = ();
	if (($WPATTERNS{'java'} == 1) or
	    ($WPATTERNS{'jar'} == 1) or
	    ($WPATTERNS{'class'} == 1)) {
	    push(@TARPATTERN, '--wildcards');
	    push(@TARPATTERN, '--no-anchored');
	    push(@TARPATTERN, '--no-recursion');
	    push(@TARPATTERN, '*.java')  if ($WPATTERNS{'java'} == 1);
	    push(@TARPATTERN, '*.jar')   if ($WPATTERNS{'jar'} == 1);
	    push(@TARPATTERN, '*.class') if ($WPATTERNS{'class'} == 1);
	}
	if (scalar(keys %PATTERNS) > 0) {
	    push(@TARPATTERN, '--no-wildcards');
	    push(@TARPATTERN, '--anchored');
	    foreach my $pat (keys %PATTERNS) {
		push(@TARPATTERN, $pat);
	    }
	}

	debug(1) and printf "INFO: [%d/%d/%d/%d] \"%s\"\n", $javacount, $jarcount, $classcount, $others, $tar;
	debug(1) and print "TARPATTERN: ->@TARPATTERN<-\n";

	return($javacount, $jarcount, $classcount, $others);
    }

    sub interesting {
	my $filename = shift;
	return -1 if (substr($filename, -5) eq '.java');
	return -2 if (substr($filename, -4) eq '.jar');
	return -3 if (substr($filename, -6) eq '.class');
	for (my $x = 0; $x < scalar @PATS; $x++) {
	    debug(3) and print "Comparing $filename to pattern $PATS[$x]\n";
	    return $x if ($filename eq $PATS[$x]);
	}
	return $DULL;
    }

    sub badfilename {
	my $name = shift;
	return 1 if (substr($name, 0, 1) eq '/');
	return 1 if (substr($name, 0, 3) eq '../');
	return 1 if ($name =~ m|/\.\./|);
	return 0;
    }

    sub getname {
	my $fullpath = shift;
	my $name = '';

	my $type = substr($fullpath, 0, 1);
	if ($fullpath =~ /^[^:]+ \d\d\d\d-\d\d-\d\d \d\d:\d\d (.+)$/) {
	    $name = $1;
	}
	if ($name eq '') {
	    print "Error: Cannot match name: $fullpath\n";
	    return ($type, '', '');
	}

	if ($type eq '-') {
	    return ($type, $name, '');
	}

	if ($type eq 'l') {
	    if ($name =~ /^(.+) -\> (.*)$/) {
		$name = $1;
		my $target = $2;
		return ($type, $name, $target);
	    } else {
		print "Error: unable to find '->' in symbolic link: $fullpath\n";
		return ($type, '', '');
	    }
	}

	if ($type eq 'h') {
	    if ($name =~ /^(.+) link to (.*)$/) {
		$name = $1;
		my $target = $2;
		return ($type, $name, $target);
	    } else {
		print "Error: unable to find 'link to' in hard link: $fullpath\n";
		return ($type, '', '');
	    }
	}

	# Everything else for now...
	return ($type, $name, '');
    }
}

##############################################################################

sub process_error_files {
    my ($stderrfile, $errorfile, $warningfile, $error, $warning) = @_;

    if (-f $stderrfile) {
	open(IN, '<', $stderrfile) || die "Unable to open $stderrfile: $!\n";
	while (<IN>) {
	    chomp;
	    if (/Exiting with failure status due to previous errors/) {
		next;
	    }
	    if (/Archive value .* is out of time_t range/) {
		$warning .= "$_\n";
		next;
	    }
	    $error .= "$_\n";
	}
	close(IN);
    }
    unless ($error eq '') {
	open(OUT, '>', $errorfile) || die "Unable to open $errorfile: $!\n";
	print OUT $error;
	close(OUT);
    }
    unless ($warning eq '') {
	open(OUT, '>>', $warningfile) || die "Unable to open $warningfile: $!\n";
	print OUT $warning;
	close(OUT);
    }
    unlink($stderrfile) if (-f $stderrfile);
}

##############################################################################

sub set_env {
    while (@_) {
	my $en = shift;
	my $ev = shift;
	$ENV{$en} = $ev;
	debug(2) and print "Set ENV{$en} = $ev\n";
    }
}

sub run_command {
    debug(2) and print "Running: @_\n";
    system(@_);
}

sub run_scommand {
    my $cmd = shift;
    debug(2) and print "Running: $cmd\n";
    system($cmd);
}

sub run_make_path {
    my $dir = shift;
    debug(2) and print "Entering run_make_path($dir)\n";
    return if (-d $dir);
    make_path($dir);
    unless (-d $dir) {
	print "ERROR: run_make_path failed to create $dir\n";
	exit(1);
    }
}

sub run_touch {
    my $file = shift;
    debug(2) and print "Entering run_touch($file)\n";
    my $dir = dirname($file);
    run_make_path($dir) unless (-d $dir);
    unless (-e $file) {
	open(IN, '>>', $file) and close(IN);
    }
    my $now = time;
    utime $now, $now, $file;
    unless (-e $file) {
	print "ERROR: run_touch unable to create $file\n";
	exit(1);
    }
}

##############################################################################

sub debug {
    my $level = shift;
    return 1 if ($VERBOSE >= $level);
    return 0;
}

##############################################################################

init();
init_patterns();

main();

##############################################################################
