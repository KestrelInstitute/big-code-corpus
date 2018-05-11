#!/usr/bin/perl

# Usage: perl jarextractor.perl [ options ] <jar file> ... [options] <tgz file> ...
# options:
# -v        increase the level of debugging messages (default 0, quietest)
# -v#       set the level of debugging messages to #
#
# environment variables:
# JROOT     root of the jcorpus tree
#
# Expected usage example:
# export JROOT=....
# find $JROOT/[0-9a-f] -type f -a -name '*.jar' -print0 | xargs -0 perl jarextractor.perl
#
# Each <jar file> listed on the command line needs to be a full, absolute path
# to the jar file under JROOT.  The jar file will be tested for errors, listed,
# and if it contains java, jar, or class files, those files will be
# extracted to a directory <jar file>.DC.  Any jar files extracted from a jar
# file will be recusively extracted.
#
# Once a jar file is fully extracted (i.e. all sub-jar files extracted if
# conditions met), it may get moved to jarcentral.  A jar is moved to jarcentral
# if the extracted tree contains at least one class file, and the extracted
# does not contain any java files.
#
# If there are errors during the listed/extractions, and error file is created
# as <jar file>.DC.BAD and contains the text of the errors.  Similarly, if a
# jar does not contain any java, jar, or class files, it is not extracted and
# instead an error file <jar file>.DC.NJ is created.  Any non-fatal warning
# messages created during the listing/extraction are left in <jar file>.DC.WARN.
#
# Jarcentral (at $JROOT/jarcentral/) is a tree containing a single copy of
# each jar file meeting certain conditions.  The jar files are stored under
# a path and name created from the MD5 hash of the jar file contents.  It
# has been assumed that a hash collision will not occur.  When a <jar file>
# is moved to jarcentral, all related files are moved also, i.e. <jar file>,
# <jar file>.DC, <jar file>.DC.BAD, <jar file>.DC.NJ, and <jar file>.DC.WARN.
# (Actually <jar file>.DC.BAD and <jar file>.DC.NJ SHOULD NEVER EXIST in
# jarcentral).  Once the original files are moved to jarcentral, symbolic
# links are placed in their original locatons pointing to the actual files
# in jarcentral.  An additional file in jarcentral, <jar file>.original-files
# is created in jarcentral that lists all the original locations of this
# jar file in the jcorpus.

use strict;
use File::Basename;
use File::Path qw( make_path remove_tree );
use Digest::MD5::File qw( file_md5_hex );
use Fcntl qw( :flock SEEK_END );

my $JROOT;
my $JARCENTRAL;

my $CHMOD;
my $P7ZA;
my $UNZIP;

my $VERBOSE = 0;

##############################################################################

sub init () {
    if ( defined $ENV{'JROOT'} ) { $JROOT = $ENV{'JROOT'}; } else { e_error(); }
    $JROOT = addslash($JROOT);
    die "ERROR: Cannot find JROOT directory\n" unless (-d $JROOT);
    debug(1) and print "JROOT set to $JROOT\n";

    $JARCENTRAL = $JROOT . 'jarcentral/';
    die "ERROR: Cannot find JARCENTRAL directory\n" unless (-d $JARCENTRAL);
    debug(1) and print "JARCENTRAL set to $JARCENTRAL\n";

    chomp($CHMOD = `which chmod`);
    chomp($P7ZA  = `which 7za`);
    chomp($UNZIP  = `which unzip`);
    #print "External programs $CHMOD $P7ZA $UNZIP\n";
}

sub e_error () {
    die 'ERROR: jarextractor.perl requires value for the environment variable JROOT';
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
	if ($arg eq '-test') { run_test(); exit(0); }
	unless (-f $arg) {
	    debug(2) and print "Skip $arg: not a file\n";
	    next;
	}
	unless (substr($arg, -4) eq '.jar') {
	    debug(2) and print "Skip $arg: does not end with .jar\n";
	    next;
	}
	# only process jar files under $JROOT, exclude those under
	# jarcentral, and exclude under unmerged -BR directory
	unless ($arg =~ m|^$JROOT([0-9a-f]/){8}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/|) {
	    debug(2) and print "Skip $arg: not under jcorpus project directory\n";
	    next;
	}
	process_jar($UNZIP, $arg); # first try using the UNZIP program
    }
    debug(1) and print "Program has finished processing ARGV\n";
    exit(0);
}

##############################################################################
# Process/Extract a JAR file...also process/extract sub-jars
# Returns a count of total java, jar, and class files created

sub process_jar {
    my ($prog, $jar) = @_;
    debug(2) and print "Entering process_jar($prog, $jar)\n";
    debug(0) and print "Processing JAR file $jar\n";

    if (-l $jar) {
	debug(1) and print "Skip $jar, it is a symbolic link\n";
	return(0, 0, 0);
    }
    unless (-f $jar) {
	debug(1) and print "Skip $jar, cannot find jar file\n";
	return(0, 0, 0);
    }

    # .jar.DC, .jar.DC.NJ, .jar.DC.BAD, .jar.DC.WARN
    my ($target, $target_skip, $target_bad, $target_warn) = make_output_names($jar);

    if ((-l $target) or (-d $target)) {
	debug(1) and print "Skip $jar, target already exists\n";
	return(0, 0, 0);
    }
    if ((-l $target_skip) or (-f $target_skip) or (-d $target_skip)) {
	# backward compatibility-check for directory
	debug(1) and print "Skip $jar, skip file already exists\n";
	return(0, 0, 0);
    }
    if ((-l $target_bad) or (-f $target_bad) or (-d $target_bad)) {
	# backward compatibility-check for directory
	debug(1) and print "Skip $jar, error file exists\n";
	return(0, 0, 0);
    }
    # ignore the warning file, it may already exist for convmv cases

    my $jsize = -s $jar;
    if ($jsize == 0) {
	run_touch($target_skip);
	debug(1) and print "Skip $jar, file is zero bytes\n";
	return(0, 0, 0);
    }

    my $top_level = ($jar =~ m|\.jar\.DC/|) ? 0 : 1;
    my ($md5, $newpath, $newdir, $newjar);
    if ($top_level == 1) {
	# See if this jar is already in jarcentral
	$md5 = file_md5_hex($jar);
	$newpath = md5path($md5);
	$newdir = $JARCENTRAL . $newpath;
	$newjar = $newdir . '/' . $md5 . '.jar';
	if (-f $newjar) {
	    debug(2) and print "This jar already exists in jarcentral, linking\n";
	    if (-d $target) {
		print "ERROR: link jar to jarcentral, but $target exists\n";
		exit(1);
	    }
	    if (-f $target_bad) {
		print "ERROR: link jar to jarcentral, but $target_bad exists\n";
		exit(1);
	    }
	    if (-f $target_skip) {
		print "ERROR: link jar to jarcentral, but $target_skip exists\n";
		exit(1);
	    }
	    # If a warning was created, it should already exist in jarcentral.
	    # Forget this one and just link to that one.
	    if (-f $target_warn) {
		debug(2) and print "WARNING: file $target_warn should not exist here, removing\n";
		unlink($target_warn);
	    }
	    jarcentral_link($jar, $newjar);
	    return(-1, -1 -1);
	}
    }

    my @JARPATTERN;  # list of file patterns (e.g. *.java) given to the zip extractor program
    my @JARLIST;     # list of sub-jars found in this jar (for recursive extractions)

    my ($javacount, $jarcount, $classcount) = check_jar($prog, $jar, $target, $target_bad, $target_warn, \@JARPATTERN, \@JARLIST);

    if (-f $target_bad) {
	debug(1) and print "Skip $jar, error file now exists\n";
	return(0, 0, 0);
    }

    if (($javacount + $jarcount + $classcount) == 0) {
	run_touch($target_skip);
	debug(1) and print "Skip $jar, contains no extraction files\n";
	return(0, 0, 0);
    }

    # We found files to extract, but no extraction patterns...program error
    if (scalar(@JARPATTERN) == 0) {
	print "ERROR: No entries in JARPATTERN for $jar\n";
	exit(1);
    }

    debug(1) and print "Extract $jar\n";
    extract_jar($prog, $jar, $target, @JARPATTERN);

    if ($prog eq $UNZIP) {
	my $result = check_names($target);
	unless ($result == 0) {
	    if (-d $target) {
		debug(1) and print "Removing directory $target to try again\n";
		run_remove_tree($target);
	    }
	    if (-f $target_skip) {
		debug(1) and print "Removing file $target_skip to try again\n";
		unlink($target_skip);
	    }
	    if (-f $target_bad) {
		debug(1) and print "Removing file $target_bad to try again\n";
		unlink($target_bad);
	    }
	    debug(1) and print "Calling process_jar($P7ZA, $jar)\n";
	    process_error_files('', $target_bad, $target_warn, '', "convmv error: calling 7za on $jar");
	    return process_jar($P7ZA, $jar);
	}
    }

    # Every jar file counted in $jarcount should now be a file jar file
    # listed in @JARLIST...if not, program error
    unless (scalar(@JARLIST) == $jarcount) {
	print "ERROR: mismatch jarcount is $jarcount, JARLIST contains @JARLIST\n";
	exit(1);
    }

    foreach my $jarfile (@JARLIST) {
	my ($tjava, $tjar, $tclass) = process_jar($UNZIP, $jarfile); # try using UNZIP first on he subjar
	debug(2) and printf "SubJAR[%d, %d, %d] %s\n", $tjava, $tjar, $tclass, $jarfile;
	if ($tjava < 0) {
	    print "ERROR: sub-jar returned -1\n";
	    exit(1);
	}
	$javacount += $tjava;
	$jarcount += $tjar;
	$classcount += $tclass;
    }

    # top-level jar, fully extracted, now decide if going to jarcentral
    if ($top_level == 1) {
	if ($javacount == 0) {
	    if ($classcount > 0) {
		debug(2) and print "This jar is eligible to be in jarcentral\n";
		jarcentral_move($jar, $newdir, $newjar);
	    } else {
		debug(2) and print "This jar does not contain a class file, no jarcentral\n";
	    }
	} else {
	    debug(2) and print "This jar contains java files, no jarcentral\n";
	}
    } else {
	debug(2) and print "This is not a top-level jar file, no jarcentral\n";
    }
    return ($javacount, $jarcount, $classcount);
}

##############################################################################

sub check_names {
    my $target = shift;
    set_env('tmptarget', $target);
    my $cmd = "/usr/bin/convmv --parsable -r -f utf8 -t utf8 \"\$tmptarget\" 2>&1";
    open(PROG, "$cmd |") or die "Error trying to run $cmd\n";
    my $result = 0;
    while (<PROG>) {
	debug(1) and print "check_names($target) found problem\n";
	$result = 1;
	last;
    }
    close(PROG);
    return $result;
}

##############################################################################

sub extract_jar {
    my ($prog, $jar, $target, @JARPATTERN) = @_;
    debug(2) and print "Entering extract_jar($prog, $jar, $target, @JARPATTERN)\n";

    unless (-f $jar) {
	print "ERROR: TGZ file $jar does not exist\n";
	exit(1);
    }

    unless (-d $target) {
	run_make_path($target);
	unless (-d $target) {
	    print "ERROR: cannot create '$target'\n";
	    exit(1);
	}
    }

    if ($prog eq $UNZIP) {
	# e.g. /usr/bin/unzip -qq -n abc.jar *.java *.class -d abc.jar.DC
	my @cmd = ($UNZIP, '-qq', '-n', $jar);
	foreach my $e (@JARPATTERN) { push(@cmd, $e); }
	push(@cmd, '-d');
	push(@cmd, $target);
	run_command(@cmd);
    } elsif ($prog eq $P7ZA) {
	# e.g. /usr/bin/7za x abc.jar -ir!*.java -ir!*.class -oabc.jar.DC -aos
	my @cmd = ($P7ZA, 'x', $jar);
	foreach my $e (@JARPATTERN) { push(@cmd, '-ir!' . $e); }
	push(@cmd, '-o' . $target);
	push(@cmd, '-aos');
	run_command(@cmd);
    }

    my @cmd = ($CHMOD, '-R', 'u+rwX,go+rX,go-w', $target);
    run_command(@cmd);
}

##############################################################################

sub md5path {
    my $md5 = shift;
    debug(2) and print "Entering md5path($md5)\n";
    my $path = substr($md5, 0, 8);
    for (my $x = 7; $x > 0; $x--) { substr($path, $x, 0) = '/'; }
    return($path);
}

##############################################################################
# If you are running multiple copies of jarextractor on different parts
# of jcorpus, there is a chance two different jars are being moved to the
# same jarcentral location.

sub jarcentral_move {
    my ($jar, $newdir, $newjar) = @_;
    debug(2) and print "Entering jarcentral_move($jar, $newdir, $newjar)\n";

    if (debug(1)) {
	print "Moving from $jar\n";
	print "Moving to   $newjar\n";
    }

    unless (-d $newdir) {
	run_make_path($newdir);
    }

    run_rename($jar, $newjar);

    my ($oldd1, $oldd2, $oldd3, $oldd4) = make_output_names($jar);
    my ($newd1, $newd2, $newd3, $newd4) = make_output_names($newjar);

    if (-e $oldd1) { run_rename($oldd1, $newd1); }
    if (-e $oldd2) { run_rename($oldd2, $newd2); }
    if (-e $oldd3) { run_rename($oldd3, $newd3); }
    if (-e $oldd4) { run_rename($oldd4, $newd4); }
    jarcentral_link($jar, $newjar);
}

##############################################################################

sub jarcentral_link {
    my ($jar, $newjar) = @_;
    debug(2) and print "Entering jarcentral_link($jar, $newjar)\n";

    unless (-f $newjar) {
	print "ERROR: jarcentral_link cannot find jar $newjar\n";
	exit(1);
    }

    if (debug(1)) {
	print "Linking from $jar\n";
	print "Linking to   $newjar\n";
    }

    if (-f $jar) {
	debug(2) and print "jarcentral_link: remove original jar $jar\n";
	unlink($jar);
    }
    run_symlink($newjar, $jar);

    my ($oldd1, $oldd2, $oldd3, $oldd4) = make_output_names($jar);
    my ($newd1, $newd2, $newd3, $newd4) = make_output_names($newjar);

    if (-e $newd1) { run_symlink($newd1, $oldd1); }
    if (-e $newd2) { run_symlink($newd2, $oldd2); }
    if (-e $newd3) { run_symlink($newd3, $oldd3); }
    if (-e $newd4) { run_symlink($newd4, $oldd4); }
    update_original_files($jar, $newjar);
}

##############################################################################

sub update_original_files {
    my ($jar, $newjar) = @_;
    debug(2) and print "Entering update_original_files($jar, $newjar)\n";

    my $orig = $newjar . '.original-files';
    debug(2) and print "Adding $jar to $orig\n";
    open(OUT, '>>', $orig) or die "ERROR: Unable to open $orig for writing: $!\n";
    flock(OUT, LOCK_EX) or die "ERROR: Error getting exclusive lock on $orig: $!\n";
    seek(OUT, 0, SEEK_END) or die "ERROR: Seek failed on $orig: $!\n";
    print OUT "$jar\n";
    close(OUT);
}

##############################################################################

{
    sub make_output_names {
	my ($file) = @_;

	my $target = $file . '.DC';
	my $target_skip = $file . '.DC.NJ';
	my $target_bad = $file . '.DC.BAD';
	my $target_warn = $file . '.DC.WARN';

	if (debug(2)) {
	    print "make_output_names() -> $target\n";
	    print "                       $target_skip\n";
	    print "                       $target_bad\n";
	    print "                       $target_warn\n";
	}
	return($target, $target_skip, $target_bad, $target_warn);
    }
}

##############################################################################

{
    my $DULL = -99;
    my $getname_state;

    sub check_jar {
	my ($prog, $jar, $target, $target_bad, $target_warn, $patref, $listref) = @_;
	debug(2) and print "Entering check_jar($prog, $jar, $target, $target_bad, $target_warn)\n";

	my $javacount = 0;
	my $jarcount = 0;
	my $classcount = 0;

	my $stderrfile = $jar . '.stderr';
	unlink($stderrfile) if (-f $stderrfile);

	test_jar($prog, $jar, $stderrfile);
	process_error_files($stderrfile, $target_bad, $target_warn, '', '');

	if (-f $target_bad) {
	    debug(1) and print "Jar zip test errors in $target_bad\n";
	    return(0, 0, 0);
	}

	# listing the jar:
	# run the zip program listing, for each line of output:
	#   get the type (f or d) and name of the entry (or a line to skip)
	#   see if the entry is "interesting"
	#   run a test if there is an issue with this entry (using strings $error and $warning)
	#   check if this is a directory and is interesting, put message in warning
	#   if the entry is a jar file, get its full path and add to jarlist

	set_env('tmpjar', $jar, 'tmperr', $stderrfile);
	my $command;
	if ($prog eq $UNZIP) {
	    $command = sprintf("%s -lqq \"%s\" 2>\"%s\"", $UNZIP, '$tmpjar', '$tmperr');
	} elsif ($prog eq $P7ZA) {
	    $command = sprintf("%s l \"%s\" 2>\"%s\"", $P7ZA, '$tmpjar', '$tmperr');
	}
	debug(2) and print "Running: $command\n";
	open(CHECK, "$command |") or die "ERROR: Unable to run zip program listings: $!\n";
	my $error = '';
	my $warning = '';
	my %names;
	my %names_count;
	reset_getname($prog);
	while (my $entry = <CHECK>) {
	    chomp($entry);
	    debug(2) and print "Looking at jar listing: $entry\n";
	    my ($type, $filename) = getname($entry, \$error, \$warning);
	    next if ($type eq 'z');  # Zip listing artifact

	    my $interest = interesting($filename);
	    debug(2) and print "File $filename is $interest\n";

	    my ($severity, $msg) = badfilename($type, $interest, $filename);
	    if ($severity == 1) { $error .= $msg; next; }
	    if ($severity == 2) { $warning .= $msg; }

	    if (($type eq 'd') and ($interest != $DULL)) {
		$warning .= "Directory: $entry\n";
	    }

	    if (($type eq 'f') and ($interest == -2)) {
		# jar file
		my $jarfile = $target . '/' . $filename;
		if ($jarfile =~ m|\\|) {
		    $warning .= "Entry has backslashes: $filename\n";
		}
		$jarfile =~ s|\\|/|g;
		push(@$listref, $jarfile);
		debug(2) and print "Adding jar file $jarfile\n";
	    }

	    if ($type eq 'f') {
		next if ($interest == $DULL);
		$names{$filename} .= "$entry\n";
		$names_count{$filename} += 1;
		if ($interest == -1) { $javacount++;  next; }
		if ($interest == -2) { $jarcount++;   next; }
		if ($interest == -3) { $classcount++; next; }
		next;
	    }
	}
	close(CHECK);
	if (getname_done() == 0) {
	    $error .= "File ended before end-of-list marker\n";
	}

	foreach my $name (sort (keys %names_count)) {
	    my $count = $names_count{$name};
	    next if ($count == 1);
	    $warning .= "Duplicated name: $name\n";
	    $warning .= $names{$name};
	}

	process_error_files($stderrfile, $target_bad, $target_warn, $error, $warning);

	if (-f $target_bad) {
	    debug(1) and print "Jar errors saved in $target_bad\n";
	    return(0, 0, 0);
	}

	push(@$patref, '*.java')  if ($javacount > 0);
	push(@$patref, '*.jar')   if ($jarcount > 0);
	push(@$patref, '*.class') if ($classcount > 0);

	debug(1) and printf "INFO: [%d/%d/%d] \"%s\"\n", $javacount, $jarcount, $classcount, $jar;
	debug(2) and print "JARPATTERN: ->@$patref<-\n";

	return($javacount, $jarcount, $classcount);
    }

    sub interesting {
	my $filename = shift;
	return -1 if (substr($filename, -5) eq '.java');
	return -2 if (substr($filename, -4) eq '.jar');
	return -3 if (substr($filename, -6) eq '.class');
	return $DULL;
    }

    # severity 1 = fatal error, stop processing
    # severity 2 = warning only
    # severity 0 = no problem
    # fatal error is only when type file and interesting, and bad pattern
    # warning is bad pattern
    sub badfilename {
	my ($type, $interesting, $name) = @_;
	my $severity = 0;
	my $msg = '';
	if (substr($name, 0, 1) eq '/') {
	    $msg = "Name $name begins with /\n";
	    return(1, $msg) if (($type eq 'f') and ($interesting != $DULL));
	    return(2, $msg);
	}
	if (substr($name, 0, 3) eq '../') {
	    $msg = "Name  $name begins with ../\n";
	    return(1, $msg) if (($type eq 'f') and ($interesting != $DULL));
	    return(2, $msg);
	}
	if ($name =~ m|/\.\./|) {
	    $msg = "Name $name contains with /../\n";
	    return(1, $msg) if (($type eq 'f') and ($interesting != $DULL));
	    return(2, $msg);
	}
	return($severity, $msg);
    }

    # Try to get the file name and file type from a zip file listing.
    # Needs to be able to handle either unzip or 7za

    # The zip listings may have extra contents before the actual
    # list of files, the program will keep a state variable to
    # track where the program is looking.  The values for $getname_state are:
    # 0 = before file listings
    # 1 = inside file listings
    # 2 = after file listings
    # Now, because listings may be unzip of 7za, the actual state values
    # will be offset by 10 for unzip and 20 for 7za.
    sub reset_getname {
	my ($prog) = @_;
	$getname_state = 10 if ($prog eq $UNZIP);
	$getname_state = 20 if ($prog eq $P7ZA);
    }
    sub getname_done {
	return 0 if ($getname_state == 10);  # unzip file had no entries
	return 0 if ($getname_state == 20);  # 7za start-of-lising marker not seen
	return 0 if ($getname_state == 21);  # 7za end-of-listing marker not seen
	return 1;
    }

    sub getname {
	my ($fullpath, $errorref, $warnref) = @_;

	if ($getname_state == 10) {
	    # unzip starts in the file listings, change here are keep processing line
	    $getname_state = 11;
	}

	if ($getname_state == 11) {
	    return('z', '') if ($fullpath =~ m|^Archive|);
	    return('z', '') if ($fullpath =~ m|^------|);
	    return('z', '') if ($fullpath =~ m|Length +Date +Time +Name|);
	    return('z', '') if ($fullpath =~ m|\d+ +\d+ files|);

	    my $name = '';
	    my $size = 0;
	    if ($fullpath =~ /^ *(\d+) +(\d\d-\d\d-\d\d\d\d|\d\d\d\d-\d\d-\d\d) \d\d:\d\d +(.+)$/) {
		$size = $1;
		$name = $3;
	    }
	    if ($name eq '') {
		debug(1) and print "Error: Cannot match name: $fullpath\n";
		$$errorref .= "No file name match: $fullpath\n";
		return ('z', '');
	    }
	    if (($name eq '/') and ($size > 0)) {
		debug(1) and print "WARNING: unzip listing has file named /\n";
		$$warnref .= "unzip listing has file named /\n";
		return ('f', $name);
	    }
	    if (substr($name, -1) eq '/') {
		unless ($size == 0) {
		    debug(1) and print "ERROR: Directory with size > 0: $fullpath\n";
		    $$errorref .= "Directory with size > 0: $fullpath\n";
		}
		return ('d', $name);
	    }
	    return ('f', $name);
	}

	if ($getname_state == 20) {
	    $getname_state = 21 if ($fullpath eq '------------------- ----- ------------ ------------  ------------------------');
	    return ('z', '');
	}

	if ($getname_state == 21) {
	    if ($fullpath eq '------------------- ----- ------------ ------------  ------------------------') {
		$getname_state = 22;
		return ('z', '');
	    }
	    my $date = '';
	    my $name = '';
	    my $size = 0;
	    my $attr = '';
	    if ($fullpath =~ /^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d|                   ) (.).... +(\d+) +\d+  (.*)$/) {
		$date = $1;
		$attr = $2;
		$size = $3;
		$name = $4;
	    }
	    $name = '/' if (($attr eq 'D') && ($size == 0) && ($name eq ''));

	    if ($date eq '                   ') {
		debug(1) and print "WARNING: date field blank: $fullpath\n";
		$$warnref .= "Blank date field: $fullpath\n";
	    }
	    if ($name eq '') {
		debug(1) and print "Error: Cannot match name: $fullpath\n";
		$$errorref .= "No file name match: $fullpath\n";
		return ('z', '');
	    }
	    if ($attr eq 'D') {
		unless ($size == 0) {
		    debug(1) and print "ERROR: Attribute = D and size > 0: $fullpath\n";
		    $$errorref .= "Attribute = D and size > 0: $fullpath\n";
		}
		return ('d', $name);
	    }
	    return ('f', $name);
	}

	if ($getname_state == 22) {
	    return('z', '');
	}
    }
}

##############################################################################

sub process_error_files {
    my ($stderrfile, $errorfile, $warningfile, $error, $warning) = @_;
    debug(2) and print "Entering process_error_files($stderrfile, $errorfile, $warningfile, $error, $warning)\n";

    if (($stderrfile ne '') and (-f $stderrfile)) {
	open(IN, '<', $stderrfile) || die "ERROR: Unable to open $stderrfile: $!\n";
	while (<IN>) {
	    chomp;
	    $error .= "$_\n";
	}
	close(IN);
	unlink($stderrfile);
    }
    unless ($error eq '') {
	open(OUT, '>', $errorfile) || die "ERROR: Unable to open $errorfile: $!\n";
	print OUT $error;
	close(OUT);
    }
    unless ($warning eq '') {
    	open(OUT, '>>', $warningfile) || die "ERROR: Unable to open $warningfile: $!\n";
    	print OUT $warning;
    	close(OUT);
    }
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

sub run_symlink {
    my ($old, $new) = @_;
    debug(2) and print "Entering run_symlink($old, $new)\n";
    if (-l $new) {
	debug(1) and print "WARNING: run_symlink link $new already exists\n";
	return;
    }
    symlink $old, $new;
    return if (-l $new); # Seems like it worked.
    print "ERROR: run_symlink unable to create link $new\n";
    exit(1);
}

# Need to handle that the $new location may already exist.  Make
# sure $new is the same type as $old if that happens.
sub run_rename {
    my ($old, $new) = @_;
    debug(2) and print "Entering run_rename($old, $new)\n";
    unless (-e $old) {
	debug(1) and print "WARNING: run_rename old item $old does not exist\n";
	return;
    }
    if (-e $new) {
	if (same_type($old, $new)) {
	    debug(1) and print "WARNING: run_rename new $new already exists and same type\n";
	    run_remove_tree($old);
	    return;
	} else {
	    debug(0) and print "WARNING: run_rename new $new already exists and NOT same type\n";
	    my $temp = $old . '.DUP';
	    debug(0) and print "WARNING: look for $temp\n";
	    run_rename($old, $temp);
	    return;
	}
    }
    rename $old, $new;
    if (-e $old) {
	debug(0) and print "ERROR: item $old still exists after rename\n";
	exit(1);
    }
    unless (-e $new) {
	debug(0) and print "ERROR: item $new does not exist after rename\n";
	exit(1);
    }
}

sub run_remove_tree {
    my ($old) = @_;
    unless (-e $old) {
	debug(1) and print "WARNING: run_remove_tree old item $old does not exist\n";
	return;
    }
    if (-l $old) { unlink($old); }
    elsif (-d $old) { remove_tree($old); }
    else { unlink($old); }
    if (-e $old) {
	debug(0) and print "WARNING: run_remove item $old still exists after delete\n";
    }
}

sub same_type {
    my ($a, $b) = @_;
    if (-l $a) { return 1 if (-l $b); return 0; }
    if (-d $a) { return 1 if (-d $b); return 0; }
    if (-f $a) { return 1 if (-f $b); return 0; }
    if (-p $a) { return 1 if (-p $b); return 0; }
    if (-c $a) { return 1 if (-c $b); return 0; }
    if (-b $a) { return 1 if (-b $b); return 0; }
    return 0;
}

sub run_make_path {
    my $dir = shift;
    debug(2) and print "Entering run_make_path($dir)\n";
    return if (-d $dir);
    make_path($dir);
    return if (-d $dir); # Seems like it worked
    print "ERROR: run_make_path failed to create $dir\n";
    exit(1);
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
    return if (-e $file); # Seems link it worked
    print "ERROR: run_touch unable to create $file\n";
    exit(1);
}

##############################################################################

sub debug {
    my $level = shift;
    return 1 if ($VERBOSE >= $level);
    return 0;
}

##############################################################################

sub run_test {
    foreach my $d (qw/0 1 2 3 4 5 6 7 8 9 a b c d e f jarcentral/) {
	my $dir = $JROOT . $d;
	next unless (-d $dir);
	print "Looking through $dir for any jar files:\n";
	my $command = "find $dir -name '*.jar' -print";
	open(IN, "$command |") || die "Cannot run find: $!\n";
	while (<IN>) {
	    chomp;
	    my $jar = $_;
	    my $dir =  $jar . '.DC';
	    my $skip = $jar . '.DC.NJ';
	    my $bad =  $jar . '.DC.BAD';
	    my $warn = $jar . '.DC.WARN';

	    my $jar_type = gettype($jar);
	    my $dir_type = gettype($dir);
	    my $skip_type = gettype($skip);
	    my $bad_type = gettype($bad);
	    my $warn_type = gettype($warn);

	    my $result = $jar_type . $dir_type . $skip_type . $bad_type . $warn_type;
	    next if ($result eq 'fd___');  # locally extracted
	    next if ($result eq 'fd__f');  # locally extracted with warning
	    next if ($result eq 'f_f__');  # locally skipped
	    next if ($result eq 'f_f_f');  # locally skipped with warning
	    next if ($result eq 'f__f_');  # locally bad
	    next if ($result eq 'f__ff');  # locally bad with warning
	    if ($result eq 'll___') { check_linking($jar); next; }  # linked to jarcentral
	    if ($result eq 'll__l') { check_linking($jar); next; }  # linked to jarcentral with warning
	    next if ($result eq 'L____');  # not a jar to consider
	    next if ($result eq 'd____');  # not a jar to consider
	    if ($result eq 'f____') {
		print "ERROR: Found unprocessed $jar\n";
		next;
	    }
	    print "ERROR: Unknown result $result $jar\n";
	}
	close(IN);
    }
}

sub gettype {
    my $f = shift;
    if (-l $f) {
        my $l = readlink($f);
        if ($l =~ /^$JROOT/) {
            return 'l';
        }
        return 'L';
    }
    return 'l' if (-l $f);
    return 'f' if (-f $f);
    return 'd' if (-d $f);
    return '_';
}

sub check_linking {
    my $jar = shift;

    my $link = readlink($jar);
    my $orig = $link . '.original-files';
    unless (-f $orig) {
	print "ERROR: Cannot find original-files for $jar\n";
	return;
    }
    my $found = 0;
    open(OR, $orig) || die "Cannot open $orig: $!\n";
    while (my $f = <OR>) {
	chomp($f);;
	if ($f eq $jar) { $found = 1; last; }
    }
    close(OR);
    unless ($found == 1) {
	print "ERROR: Not in original-files $jar\n";
    }
}

##############################################################################
# Given a Jar file and a stderrfile, run the unzip test function and
# write into the stderrfile any "real" zip errors.

sub test_jar {
    my ($prog, $jar, $stderrfile) = @_;

    set_env('tmpjar', $jar, 'tmperr', $stderrfile);
    if ($prog eq $UNZIP) {
	my $cmd = sprintf("%s -tqq \"%s\" >\"%s\" 2>&1", $UNZIP, '$tmpjar', '$tmperr');
	run_scommand($cmd);
    } elsif ($prog eq $P7ZA) {
	my $command = sprintf("%s t \"%s\" -tzip >\"%s\" 2>&1", $P7ZA, '$tmpjar', '$tmperr');
	run_scommand($command);
	my $command = sprintf("if grep 'Everything is Ok' \"%s\" > /dev/null ; then /bin/cp /dev/null \"%s\" ; fi", '$tmperr', '$tmperr');
	run_scommand($command);
    }
}

##############################################################################
##############################################################################
##############################################################################
##############################################################################
##############################################################################

init();

main();

##############################################################################
