Overview
--------

A 'jcorpus' is a directory structure containing java code.
It starts out as a subset of the MUSE corpus, organized
by UUID.  We process it in three main steps:

1. expand the MUSE corpus tarballs and remove non-java-related code

2. deduplicate jar files

3. deduplicate class files


--------------------------------
Interface for building a jcorpus from all tarballs under
a set of locations.

  make-new-jcorpus JROOT SOURCE...

Builds a new jcorpus at JROOT (absolute path)
from the SOURCE locations, all of which must be absolute locations
that have the xtreemfs file structure (*1).
If no SOURCE locations are listed, it takes the source locations from stdin,
one per line.
If JROOT already exists, it must be an empty directory.

Each SOURCE must be a full source file name or directory name.
The highest directory (in the first SOURCE (*2)) that contains the substring
"xtreemfs" is the "xtreemfs directory".
SOURCE can be a regular tarball, a buildResults tarball, or a directory
that is recursively searched (not following symlinks) for regular and
buildResults tarballs.

The lists of regular and buildResults tarballs are written to
files in /tmp and then make-full-jcorpus is called.

(*1) An "xtreemfs directory" has this directory structure under it:
      x/x/x/x/x/x/x/x/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/buildResults/
    where "x" is a hex digit.
    Tarballs in x/x/x/x/x/x/x/x/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/
    with names
       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.tgz
       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx_metadata.tgz
       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx_code.tgz
    are "regular tarballs".
    The "buildResults" directory is optional; if it exists,
    tarballs with the name
       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx_UCI_build.tgz
    are "buildResults tarballs".

(*2) A current limitation is that all the SOURCE locations
     must be in the same xtreemfs directory.


--------------------------------
Interface for building a jcorpus from specific lists of tarballs.

  make-full-jcorpus <xroot> <jroot> <tarball-places-file> <buildresults-tarballs-file>

Creates a jcorpus-format directory tree at <jroot>.
Arguments:

* xroot (absolute path) is an ancestor directory containing all the tarballs

* jroot (absolute path) is where the jcorpus will be created.
  If it already exists, the script prompts you whether you want to add to it.
  This script contains a call to build-classcentral which iterates over all
  the class files.  It is many hours the first time, but if there is not much to
  do it only takes a few minutes.

* tarball-places-file is a file with a list of places to check for regular tarballs.
   Each line should be a directory or tarball file starting with xroot.
   buildResults tarballs under given directories or even separately listed
   are ignored.

* buildresults-tarballs-file is a file with a list of buildResults tarballs (absolute path) to add to jcorpus.


jar file handling
-----------------

jar files are expanded into a directory that has ".DC" appended to the name.
For example, "log4j.jar" is expanded into "log4j.jar.DC/".  The original jar
file is not deleted.

All jar files except those exceptions (*1) are considered library jars.
The directory "jarcentral" under <jcorpus root> stores these library jars.
Each library jar file and expanded jar directory are moved to "jarcentral",
given a new name based on its md5 hash, and replaced by symbolic links.

For example, in

  /muse/jcorpus/3/3/0/1/d/d/0/d/3301dd0d-506e-454b-bd7f-634c7f18acac/latest

there are these symbolic links:

  js.jar -> /muse/jcorpus/jarcentral/e/9/2/8/b/0/d/6/e928b0d625d1d03d24f77e282b56745f.jar
  js.jar.DC -> /muse/jcorpus/jarcentral/e/9/2/8/b/0/d/6/e928b0d625d1d03d24f77e282b56745f.jar.DC

If another project contains a jar with the same content, it is replaced by
symbolic links to the same jar and expanded jar directory in jarcentral.

In jarcentral, there for each jar file there is also a file containing
a list of original file locations of the jar file.  Using the same
example, the directory

  /muse/jcorpus/jarcentral/e/9/2/8/b/0/d/6

contains

  e928b0d625d1d03d24f77e282b56745f.jar
  e928b0d625d1d03d24f77e282b56745f.jar.DC
  e928b0d625d1d03d24f77e282b56745f.jar.original-files

and the file

  e928b0d625d1d03d24f77e282b56745f.jar.original-files

contains the content

  /muse/jcorpus/3/3/0/1/d/d/0/d/3301dd0d-506e-454b-bd7f-634c7f18acac/latest/js.jar
  /muse/jcorpus/6/6/f/b/f/4/4/2/66fbf442-cd80-11e4-ade2-cbb329362c65/content/trunk/QuantDesk_UI/lib/js.jar
  /muse/jcorpus/d/c/3/e/0/3/3/7/dc3e0337-f4fd-4078-9838-c27fbf7b750c/latest/js.jar

Note that this jar file appears in three different projects.  Some jar files
appear in hundreds of projects, so turning them into links saves a lot of space.


(*1)
The class of exceptions:
* the jar file has at least one .java source file
  Note that this can result in failure to deduplicate jar files when they
  have a .java file in them.  We have not yet quantified this risk.
  However, we did notice that all the jars in this directory have this problem:
    /muse/jcorpus/0/1/4/5/7/7/0/0/01457700-1e67-42fb-a1ee-a89b99d11f23/latest/lib



class file handling
-------------------

After jar files have been expanded and uniquified to jarcentral, all
class files are uniquified to "classcentral" in a manner similar to
how jar files are handled.

Each class file is moved to classcentral, given a new name based on
its md5 hash, and replaced by a symbolic link to the file in
classcentral.

For example, in
  /muse/jcorpus/jarcentral/e/9/2/8/b/0/d/6/e928b0d625d1d03d24f77e282b56745f.jar.DC/org/mozilla/classfile
there is
  ByteCode.class -> /muse/jcorpus/classcentral/8/0/0/5/8005dc27e0c4a3ad11c88a9b13113643.class

Every other instance of this class file is also replaced by a symbolic
link to the file in classcentral.

In classcentral, parallel to each class file is a file showing where
that class file occurred.  Using the same example, the directory

  /muse/jcorpus/classcentral/8/0/0/5

contains

  8005dc27e0c4a3ad11c88a9b13113643.class
  8005dc27e0c4a3ad11c88a9b13113643.class.original-files

and the file

  8005dc27e0c4a3ad11c88a9b13113643.class.original-files

contains 154 lines, the first 3 of which are

  /muse/jcorpus/1/8/1/b/9/c/8/0/181b9c80-dcf1-11e4-b34a-f761f3d5dc2a/1.7R2/jar.jar.DC/org/mozilla/classfile/ByteCode.class
  /muse/jcorpus/1/a/c/2/e/b/e/8/1ac2ebe8-dce5-11e4-b462-fbe00d02a2e6/1.7R2_3/jar.jar.DC/org/mozilla/classfile/ByteCode.class
  /muse/jcorpus/2/2/2/6/4/5/e/e/222645ee-aaae-4383-8b45-2c6f8a58d61a/latest/lib/shindig/caja-r3164.jar.DC/java/rhino/js.jar.DC/org/mozilla/classfile/ByteCode.class

Replacing all 154 class files by symbolic links saves a considerable
amount of space.

The downstream analysis tools generally operate on classes from classcentral
to avoid redundant effort.



jarring unjarred class files
----------------------------

Some downstream tools prefer to see jar files rather than class files,
but some class files did not arrive packaged in a jar file.  To satisfy
tools that only operate on jar files, we jar up the unjarred class files.
By "unjarred" we really mean "not in jarcentral."  More details below.

It would be most natural to jar related unjarred class files together
in their project directories before creating jarcentral.  However, there
are complications with this idea so for expediency we decided to build from
classcentral at the end of make-jcorpus.

We create a directory structure parallel to classcentral, called

  classjars/

so that each unjarred class file in classcentral/ has a corresponding
jar file in classjars/ that contains it.  We ignore packages and
create each jar file from the directory containing the class file.

Note: an "unjarred" class file is defined as a class file that is not
in any jar file in jarcentral.  If a jar file has a java source file
in it, then the jar file is not put in jarcentral, and its class files
will be considered "unjarred" and they will be put in individual jar
files in classjars/.
