
Notes:

Test files used in benchmarks:
```
mkdir -p src/testdata
cd src/testdata

wget https://github.com/ziglang/zig/archive/bb0f7d55e8c50e379fa9bdcb8758d89d08e0cc1f.tar.gz
wget http://corpus.canterbury.ac.nz/resources/cantrbry.tar.gz
wget http://corpus.canterbury.ac.nz/resources/large.tar.gz
wget https://www.gutenberg.org/ebooks/2600.txt.utf-8
```

Remove gzip extra header:
```
gunzip -c large.tar.gz
gzip -9n large.tar
```

References:

[Bill Bird Video series](https://www.youtube.com/watch?v=SJPvNi4HrWQ&t)  
[RFC](https://datatracker.ietf.org/doc/html/rfc1951)  
[zlib algorithm  explained](https://github.com/madler/zlib/blob/643e17b7498d12ab8d15565662880579692f769d/doc/algorithm.txt)  
[Mark Adler on stackoverflow](https://stackoverflow.com/search?q=user%3A1180620+deflate)  
[Faster zlib/DEFLATE](https://dougallj.wordpress.com/2022/08/20/faster-zlib-deflate-decompression-on-the-apple-m1-and-x86/)  
[Reading bits with zero refill latency](https://dougallj.wordpress.com/2022/08/26/reading-bits-with-zero-refill-latency/)  
[the canterbury corpus](https://corpus.canterbury.ac.nz/descriptions/)  
