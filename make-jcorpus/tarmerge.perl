#!/usr/bin/perl

# Usage: perl tarmerge.perl [ options ] <br dirs> ... [options] <br dirs> ...
# options:
# -v        increase the level of debugging messages (default 0, quietest)
# -v#       set the level of debugging messages to #
#
# environment variables:
# JROOT     root of the jcorpus tree
#
# Expected usage example:
# export JROOT=....
# find $JROOT/[0-9a-f] -type d -a -name '*-BR' -print0 | xargs -0 perl tarmerge.perl
#
# Given a buildResults extraction directory, e.g. a/b/c/d/abcd-BR/,
# move the top-level build/ directory into the associated project
# directory, a/b/c/d/abcd/.
#
# The program tries to find a location under the project directory where
# the buildResults tree "aligns" with the project tree.  The applied rule
# is that the path under build/ to EVERY class file has to match a similar
# path in the project subtree to a match java file.
#
# If no sub location can be found, then the build/ directory is put at the
# top-level of the project directory.
#
# Once a location is found in the project directory, the program checks
# whether the name 'build' already exists.  If it does, it tries an alternate
# name for the buildResults build directory.  The names, in order that are
# tried are: 'build', 'buildBR', 'buildBR2', and 'buildBR3'.  If none of those
# are available, the merge operation is aborted.

use strict;
use File::Basename;

my $JROOT;
my $VERBOSE = 0;

my $FIND;

##############################################################################

sub init () {
    if ( defined $ENV{'JROOT'} ) { $JROOT = $ENV{'JROOT'}; } else { e_error(); }
    $JROOT = addslash($JROOT);
    die "Cannot find JROOT directory\n" unless (-d $JROOT);
    debug(1) and print "JROOT set to $JROOT\n";

    chomp($FIND = `which find`);
    #print "External programs $FIND\n";
}

sub e_error () {
    die 'tarmerge.perl requires value for the environment variable JROOT';
}

sub addslash {
    my $d = shift;
    return $d if (substr($d, -1) eq '/');
    return $d . '/';
}

###########################################################################

sub main {
    foreach my $arg (@ARGV) {
	if ($arg eq '-v')   { $VERBOSE++; next; }
	if ($arg =~ m|^-v(\d+)$|) { $VERBOSE = $1; next; }
	if ($arg eq '-test') { run_test(); exit(0); }

	my ($pd, $bd) = find_project_and_buildResults($arg);
	next if ($pd eq '');
	merge($pd, $bd);
    }
}

###########################################################################

sub find_project_and_buildResults {
    my $arg = shift;
    if (-l $arg) {
	debug(2) and print "Skip, arg is a symbolic link\n";
	return('', '');
    }
    unless (-d $arg) {
	debug(2) and print "Skip, arg is not a directory\n";
	return('', '');
    }
    $arg =~ s|/$||;  # remove an ending slash if there
    unless (substr($arg, -3) eq '-BR') {
	debug(2) and print "Skip, arg does not end with BR\n";
	return('', '');
    }
    unless ($arg =~ m|^$JROOT([0-9a-f]/){8}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-BR$|) {
	debug(2) and print "Skip, arg is not a valid jcorpus directory path\n";
	return('', '');
    }
    my $project = substr($arg, 0, -3);
    unless (-d $project) {
	debug(2) and print "Skip, cannot find associated project directory\n";
	return('', '');
    }
    return($project, $arg);
}

###########################################################################

sub merge {
    my ($pd, $bd) = @_;
    unless (-d $pd) {
	debug(2) and print "Skipping: no project directory $pd\n";
	return;
    }
    unless (-d $bd) {
	debug(2) and print "Skipping: no buildResults directory $bd\n";
	return;
    }
    unless (-d $bd . '/build') {
	debug(1) and print "Skipping: no build directory $bd/build\n";
	return;
    }

    debug(1) and print "Merging $pd $bd\n";

    my %BUILD;
    listclass($bd, \%BUILD);
    my %PROJECT;
    listjava($pd, \%PROJECT);

    if ((scalar(keys %BUILD) == 0) or (scalar(keys %PROJECT) == 0)) {
	# No files to try to match, move to top-level
	debug(2) and print "Either no class or no java files were found to compare\n";
	mergemove($bd, $pd, '.');
	return;
    }

    # For every class file, there hopefully is one or more corresponding
    # java files.  Each corresponding java file may led to a possible
    # location for the build directory.  The goal is to find one (or
    # more) target directories that is valid for every class file.
    #
    # For the first class file, we find all the corresponding java
    # files, and for each java file, the possbile target location
    # for the build directory.  This set of possible locations is
    # the %result for that class file.  On the first class file
    # this %result creates the inital set of %candidate locations for
    # final build directory.
    #
    # For each of the remaining class files, we first build its set of
    # possible %result locations.  Now, all %candidate locations are
    # eliminated unless the location is in %result.
    #
    # If at any time all the %candidate locations are eliminated,
    # then there is no common location for build for all class files.

    my %candidate;
    my $first_entry = 1;
    foreach my $bfn (sort (keys %BUILD)) {
	my $brfn = $BUILD{$bfn}{filename};
	debug(2) and print "Processing class file $bfn\n";
	my %result;
	foreach my $pfn (keys %PROJECT) {
	    my $prfn = $PROJECT{$pfn}{filename};
	    next unless ($brfn eq $prfn);
	    my $bdir = $BUILD{$bfn}{directory};
	    my $pdir = $PROJECT{$pfn}{directory};
	    my $target = findlevel($bdir, $pdir, $brfn);
	    unless ($target eq '') {
		$result{$target} = 1;
	    }
	}
	combine(\%candidate, \%result, $first_entry);
	$first_entry = 0;
	my $count = scalar(keys %candidate);
	last if ($count == 0);
    }

    my $count = scalar(keys %candidate);
    if ($count == 0) {
	debug(2) and print "No common target location found, using '.'\n";
	mergemove($bd, $pd, '.');
	return;
    }

    if ($count == 1) {
	my ($target) = (keys %candidate);
	debug(2) and print "Single target directory $target found\n";
	mergemove($bd, $pd, $target);
	return;
    }

    if ($count > 1) {
	if (debug(2)) {
	    foreach my $target (sort (keys %candidate)) {
		print "Target: $target\n";
	    }
	}
	debug(2) and print "Multiple target directories found, using '.'\n";
	mergemove($bd, $pd, '.');
	return;
    }
}

##############################################################################

sub combine {
    my ($cref, $rref, $first) = @_;

    if ($first == 1) {
	foreach my $target (keys %$rref) {
	    debug(2) and print "Adding candidate $target\n";
	    $cref->{$target} = 1;
	}
	return;
    }

    foreach my $target (keys %$cref) {
	unless ($rref->{$target} == 1) {
	    debug(2) and print "Removing candidate $target\n";
	    delete $cref->{$target};
	}
    }
}

##############################################################################
# if $target is '.', then we want $pd . 'build'
# if $target is a/b/c, then we want $pd . $target . '/' . 'build'

sub mergemove {
    my ($bd, $pd, $target) = @_;

    my $extension = '';
    $extension = $target . '/' unless ($target eq '.');
    debug(2) and print "target is $target, extension is '$extension'\n";

    my $uuiddir = basename($pd);
    debug(2) and print "uuiddir is $uuiddir\n";

    my $source = $bd . '/' . 'build';
    unless (-d $source) {
	print "Cannot find source directory $source\n";
	exit(1);
    }
    debug(2) and print "source is $source\n";

    my $link = '';

    my $final;
    foreach my $build ('build', 'buildBR', 'buildBR2', 'buildBR3') {
	$final = $pd . '/' . $extension . $build;
	next if (-d $final);
	$link = $uuiddir . '/' . $extension . $build;
	last;
    }
    if ($link eq '') {
	debug(1) and print "Unable to find suitable destination\n";
	return;
    }

    debug(1) and print "rename $source $final\n";
    rename $source, $final or die "Rename failed: $!\n";
    debug(1) and print "rmdir $bd\n";
    rmdir $bd or die "Rmdir failed: $!\n";
    debug(1) and print "ln -s $link $bd\n";
    symlink $link, $bd or die "Symlink failed: $!\n";
}

##############################################################################

sub findlevel {
    my ($bd, $pd, $fn) = @_;
    my $pat = '';
    if ($bd eq '.') { $pat = dirname($pd); goto done; }
    if ($bd eq $pd) { $pat = '.'; goto done; }
    if ($pd =~ m|^(.*)/$bd$|) { $pat = dirname($1); goto done; }

  done:
    debug(2) and print "Findlevel($bd, $pd, $fn) returns $pat\n";
    return $pat;
}

##############################################################################

sub listclass {
    my ($bd, $aref) = @_;

    my $target = addslash($bd) . 'build';
    debug(1) and print "Listing class files in $target\n";
    my @cmd = ($FIND, $target, '-type', 'f', '-a', '-name', '*.class', '-printf', '%P\n');
    open(IN, '-|', @cmd) || die "Cannot run find: $!\n";
    while (<IN>) {
	chomp;
	my $filename = basename($_);
	next if ($filename =~ m|\$|);
	my $filename = substr($filename, 0, -6);  # remove .class
	my $directory = dirname($_);
	$aref->{$_}{filename} = $filename;
	$aref->{$_}{directory} = $directory;
	debug(2) and print "$_ -> $directory $filename\n";
    }
    close(IN);
}

##############################################################################

sub listjava {
    my ($pd, $aref) = @_;

    my $target = $pd;
    debug(1) and print "Listing java files in $target\n";
    my @cmd = ($FIND, $target, '-type', 'f', '-a', '-name', '*.java', '-printf', '%P\n');
    open(IN, '-|', @cmd) || die "Cannot run find: $!\n";
    while (<IN>) {
	chomp;
	my $filename = basename($_);
	my $filename = substr($filename, 0, -5);  # remove .java
	my $directory = dirname($_);
	$aref->{$_}{filename} = $filename;
	$aref->{$_}{directory} = $directory;
	debug(2) and print "$_ -> $directory $filename\n";
    }
    close(IN);
}

##############################################################################

sub debug {
    my $level = shift;
    return 1 if ($VERBOSE >= $level);
    return 0;
}

###########################################################################

sub run_test {
    foreach my $d (qw/0 1 2 3 4 5 6 7 8 9 a b c d e f/) {
	my $dir = $JROOT . $d;
	next unless (-d $dir);
	print "Looking through $dir for any unprocessed buildResults directories:\n";
	my $command = "find $dir -type d -a -name '*-BR' -print";
	open(IN, "$command |") || die "Cannot run find: $!\n";
	while (<IN>) {
	    chomp;
	    my $project = substr($_, -3);
	    unless (-d $project) {
		print "WARNING: Found $_, but no match project directory\n";
		next;
	    }
	    print "ERROR: Found $_\n";
	}
	close(IN);
    }
}

###########################################################################

init();

main();

###########################################################################
