# big-code-corpus
Big code tools for Java bytecode corpus

These tools assume you have tarballs of the form
created by Two Six Labs.

## Background
This code was used for research purposes---it is not production-ready.
It is released in case someone might find it useful, and to enable
experiment repeatability.  For some good thoughts on this concept, see
[Matt Might's CRAPL](http://matt.might.net/articles/crapl/).

## Tools

### utilities/gather-tarball-java-data

Find sizes of corpus tarballs and expanded sizes, as well as sizes of java-related files
and numbers of java-related files.

### utilities/find-official-tarballs

For checking that every tarball in a list of tarballs is accounted for.
The list of tarballs in in the form of cksum outputs.

### make-jcorpus
[README.txt](make-jcorpus/README.txt)

Expands tarballs, deduplicates and expands jar files, and deduplicates class files.
