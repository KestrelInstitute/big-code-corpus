--------------------------------------------------------------------------------
gather-tarball-java-data
------------------------

To build the Docker image for gather-tarball-java-data,
do:

  docker build -f ./Dockerfile-gather-tarballs -t gather-tarballs .

To run it, you will need to know

1. a root prefix of all the tarball file names, e.g. /path/to/tarballs
   This directory will be mounted read-only by the docker container.

2. A way to generate the list of tarball file names.
   For example, using cat or find.

3. An output directory and filename where the results will be put.
   This directory will be mounted by the docker container so for
   safety you should not have anything else in it.

Example run:

  cat /tmp/list-of-tarballs  \
    | sed 's|^/muse/xtreemfs-V4_2/|/input/|'  \
    | docker run -i  \
      -v /muse/xtreemfs-V4_2:/input:ro  \
      -v /tmp/outputdir:/output  \
      gather-tarballs run-gather-tarballs output-file.csv

Example run explained:
* The tarballs are listed in /tmp/list-of-tarballs, one per line,
  and they all start with "/muse/xtreemfs-V4_2".
* The sed command replaces that prefix by the directory
  used in the docker container
* The docker command mounts read-only the host's "/muse/xtreemfs-V4_2"
  as the container's "/input"
* The docker command mounts the host's "/tmp/outputdir"
  as the container's "/output".  The container has write permission
  so for safety this host directory should not have much in it.
* The docker command runs the docker image "gather-tarballs",
  and in it, executes "run-gather-tarballs".
* The output file output-file.csv in the host directory
  /tmp/outputdir will be created.

Note that the tarball names in the output file will have the
docker container's mount point "/input" rather than the prefix
they have in the host OS.

See the header of gather-tarball-java-data for information on what it does.


--------------------------------------------------------------------------------
find-official-tarballs
------------------------
