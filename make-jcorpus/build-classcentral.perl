#!/usr/bin/perl

# Usage: perl build-classcentral.perl [ options ] <class file> ... [options] <class file> ...
# options:
# -v        increase the level of debugging messages (default 0, quietest)
# -v#       set the level of debugging messages to #
#
# environment variables:
# JROOT     root of the jcorpus tree
#
# Expected usage example:
# export JROOT=....
# mkdir $JROOT/classcentral
# find $JROOT/[0-9a-f] $JROOT/jarcentral -type f -a -name '*.class' -print0 | xargs -0 perl build-classcentral.perl
#
# Move each class file to a central location in classcentral ($JROOT/classcentral).
# Each class file is stored to a path and name based in the MD5 hash of its
# contents.  Therefore, only a single copy of each unique class file exists.
# The original file is moved to classcentral (or removed if it already
# exists in classcentral) and a symbolic link pointing to the location in
# classcentral is placed at its original location.  A <class file>.original-files
# file in classcentral is updated with the original locations of class
# files pointing to this <class file>.  Only in the case the original
# class file is zero bytes is it not moved to class central.

use strict;
use File::Basename;
use File::Path qw( make_path remove_tree );
use Digest::MD5::File qw( file_md5_hex );
use Fcntl qw( :flock SEEK_END );

my $JROOT;
my $JARCENTRAL;
my $CLASSCENTRAL;

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

    $CLASSCENTRAL = $JROOT . 'classcentral/';
    die "ERROR: Cannot find CLASSCENTRAL directory $CLASSCENTRAL\n" unless (-d $CLASSCENTRAL);
    debug(1) and print "CLASSCENTRAL set to $CLASSCENTRAL\n";
}

sub e_error () {
    die 'ERROR: build-classcentral.perl requires value for the environment variable JROOT';
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
	if ($arg eq '-test') { run_test(); exit(); }
	unless (-f $arg) {
	    debug(2) and print "Skip $arg: not a file\n";
	    next;
	}
	unless (substr($arg, -6) eq '.class') {
	    debug(2) and print "Skip $arg: does not end with .class\n";
	    next;
	}
	# only process class files under $JROOT projects or jarcentral, exclude
	# classcentral, and exclude under unmerged -BR directory
	unless (($arg =~ m|^$JROOT(jarcentral/)|) or
		($arg =~ m|^$JROOT([0-9a-f]/){8}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/|)) {
	    debug(2) and print "Skip $arg: not under jcorpus project or jarcentral directory\n";
	    next;
	}
	process_class($arg);
    }
    debug(1) and print "Program has finished processing ARGV\n";
    exit(0);
}

##############################################################################
# Argument is an absolute path to a file ending in '.class'

# This file will be moved to CLASSCENTRAL.
# 1) calculate its new location in classcentral based on its md5 hash
# 2) move it to the new location (unless location already exists)
# 3) update original-files
#
# When multiple copies of this program are running, expect that a new
# directory path could "appear", and similarly a class file in
# classcentral.  Lock original-files during update.

sub process_class {
    my $class = shift;

    debug(0) and print "Processing class file $class\n";

    my $classsize = -s $class;
    if ($classsize == 0) {
	debug(2) and print "Class file $class is zero bytes\n";
	return;
    }

    my ($md5, $newpath, $newdir, $newclass);
    $md5 = file_md5_hex($class);
    $newpath = md5path($md5);
    $newdir = $CLASSCENTRAL . $newpath;
    $newclass = $newdir . '/' . $md5 . '.class';

    run_make_path($newdir);
    run_move_class($class, $newclass);
    run_link_class($class, $newclass);
    update_original_files($class, $newclass);
}

##############################################################################

sub run_make_path {
    my $dir = shift;
    debug(2) and print "Entering run_make_path($dir)\n";
    return if (-d $dir);
    make_path($dir);
    return if (-d $dir); # Seems like it worked
    print "ERROR: run_make_path failed to create $dir\n";
    exit(1);
}

##############################################################################

sub run_move_class {
    my ($class, $newclass) = @_;
    debug(2) and print "Entering run_move_class($class, $newclass)\n";

    if (-l $class) {
	print "ERROR: in run_move_class, original class $class is a link\n";
	exit(1);
    }
    unless (-f $class) {
	print "ERROR: cannot find original class file $class\n";
	exit(1);
    }
    if (-e $newclass) {
	if ((-l $newclass) or (! -f $newclass)) {
	    print "WARNING: new class file $newclass exists, but not a file, not linking\n";
	    return;
	}
	if (-f $newclass) {
	    my $classsize = -s $class;
	    my $newclasssize = -s $newclass;
	    unless ($classsize == $newclasssize) {
		if (debug(0)) {
		    print "WARNING: class file and new class file not same size (not linking):\n";
		    print "WARNING: class $class size $classsize\n";
		    print "WARNING: new class $newclass size $newclasssize\n";
		}
	    }
	    unlink($class);
	    if (-e $class) {
		print "ERROR: Unable to unlink original class $class\n";
		exit(1);
	    }
	    return;
	}
    }
    rename $class, $newclass;
    unless (-f $newclass) {
	print "ERROR: new class file $newclass does not exist after rename\n";
	exit(1);
    }
    if (-f $class) {
	if (debug(1)) {
	    print "WARNING: attempted rename of original class $class failed to remove original class file\n";
	    print "WARNING: unlinking original class $class since new class file exists\n";
	}
	unlink($class);
	if (-e $class) {
	    print "ERROR: Unable to unlink original class $class after rename\n";
	    exit(1);
	}
    }
}

##############################################################################
# Normally, the original class should not exist, and the new class should
# exist.  If there was an earlier problem, and the move to classcentral
# was cancelled, then we cannot complete the linking here.

sub run_link_class {
    my ($class, $newclass) = @_;
    debug(2) and print "Entering run_link_class($class, $newclass)\n";

    if (-e $class) {
	print "WARNING: original class $class still exists, cannot link\n";
	return;
    }
    unless (-f $newclass) {
	print "WARNING: new class $newclass does not exist, cannot link\n";
	return;
    }
    if (debug(1)) {
	print "Linking from $class\n";
	print "Linking to   $newclass\n";
    }
    symlink $newclass, $class;
    return if (-l $class);  #  Seems link it worked
    print "ERROR: run_link_class unable to create link $class\n";
    exit(1);
}

##############################################################################

sub update_original_files {
    my ($class, $newclass) = @_;
    debug(2) and print "Entering update_original_files($class, $newclass)\n";

    my $orig = $newclass . '.original-files';
    debug(2) and print "Adding $class to $orig\n";
    open(OUT, '>>', $orig) or die "ERROR: Unable to open $orig for writing: $!\n";
    flock(OUT, LOCK_EX) or die "ERROR: Error getting exclusive lock on $orig: $!\n";
    seek(OUT, 0, SEEK_END) or die "ERROR: Seek failed on $orig: $!\n";
    print OUT "$class\n";
    close(OUT);
}

##############################################################################
# take some md5 string, e.g. 0123456789abcdef0123456789abcdef
# and turn it into a new directory path of length $L
# 0123456789abcdef0123456789abcdef -> 0123
# 0123 -> 012/3 -> 01/2/3 -> 0/1/2/3

sub md5path {
    my $md5 = shift;
    my $L = 4;
    my $path = substr($md5, 0, $L);
    for (my $x = $L-1; $x > 0; $x--) { substr($path, $x, 0) = '/'; }
    return($path);
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
	print "Looking through $dir for any class files:\n";
	my $command = "find $dir -name '*.class' -print";
	open(IN, "$command |") || die "Cannot run find: $!\n";
	while (<IN>) {
	    chomp;
	    if (-l $_) { check_link($_); next; }
	    if (-f $_) { check_file($_); next; }
	    # anything other than file or link would normally be skipped anyway
	}
	close(IN);
    }
}

sub check_file {
    my $f = shift;
    my $size = -s $f;
    return if ($size == 0);
    print "ERROR: unprocessed class file $f\n";
}

sub check_link {
    my $f = shift;

    my $link = readlink($f);
    return unless ($link =~ m|^$JROOT(classcentral/)|); # not our link
    if (-l $link) {
	print "ERROR: link points to link $f\n";
	return;
    }
    unless (-f $link) {
	print "ERROR: link does not point to file $f\n";
	return;
    }

    # Seems to be OK, now check original-files
    check_linking($f, $link);
}

sub check_linking {
    my ($f, $link) = @_;

    my $orig = $link . '.original-files';
    unless (-f $orig) {
	print "ERROR: Cannot find original-files for $f\n";
	return;
    }
    my $found = 0;
    open(OR, $orig) || die "Cannot open $orig: $!\n";
    while (my $e = <OR>) {
	chomp($e);
	if ($e eq $f) { $found = 1; last; }
    }
    close(OR);
    unless ($found == 1) {
	print "ERROR: Not in original-files $f\n";
    }
}

##############################################################################

init();

main();

##############################################################################
