### Benchmarks

Huge file ziglang repo tar:
```sh
$ time gzip -kf ziglang.tar
gzip -kf ziglang.tar  2.50s user 0.03s system 99% cpu 2.532 total
24716226 ziglang.tar.gz

$ time zig-out/bin/gzip ziglang.tar
zig-out/bin/gzip ziglang.tar  2.11s user 0.07s system 99% cpu 2.179 total
24684593 ziglang.tar.gz
```

Big file Tolstoy's War and Peace:
```sh
$ time zig-out/bin/gzip book
zig-out/bin/gzip book  0.14s user 0.00s system 99% cpu 0.145 total
1218418 book.gz

$ time gzip -kf book
gzip -kf book  0.16s user 0.00s system 98% cpu 0.165 total
1225959 book.gz
```

Performance with gzip:
```sh
$ zig build -Doptimize=ReleaseSafe && hyperfine 'zig-out/bin/gzip ziglang.tar' 'gzip -kf ziglang.tar'

Benchmark 1: zig-out/bin/gzip ziglang.tar
  Time (mean ± σ):      2.164 s ±  0.006 s    [User: 2.081 s, System: 0.080 s]
  Range (min … max):    2.157 s …  2.177 s    10 runs

Benchmark 2: gzip -kf ziglang.tar
  Time (mean ± σ):      2.506 s ±  0.004 s    [User: 2.477 s, System: 0.028 s]
  Range (min … max):    2.501 s …  2.512 s    10 runs

Summary
  zig-out/bin/gzip ziglang.tar ran
    1.16 ± 0.00 times faster than gzip -kf ziglang.tar
```

With current std lib implementation:
```sh
$ zig build -Doptimize=ReleaseSafe && hyperfine --warmup 1 'zig-out/bin/deflate_bench' 'zig-out/bin/deflate_bench --std'

Benchmark 1: zig-out/bin/deflate_bench
  Time (mean ± σ):      2.097 s ±  0.004 s    [User: 2.089 s, System: 0.010 s]
  Range (min … max):    2.092 s …  2.104 s    10 runs

Benchmark 2: zig-out/bin/deflate_bench --std
  Time (mean ± σ):      2.396 s ±  0.014 s    [User: 2.389 s, System: 0.008 s]
  Range (min … max):    2.378 s …  2.425 s    10 runs

Summary
  zig-out/bin/deflate_bench ran
    1.14 ± 0.01 times faster than zig-out/bin/deflate_bench --std
```

Size with std lib:  

Huge file: 
```sh
zig-out/bin/deflate_bench -c | wc -c
24716214

zig-out/bin/deflate_bench -c --std | wc -c
24716129
```
Big:
```sh
zig-out/bin/deflate_bench -c | wc -c
1218406

zig-out/bin/deflate_bench -c --std | wc -c
1226277
```

### References:

[Bill Bird Video series](https://www.youtube.com/watch?v=SJPvNi4HrWQ&t)  
[RFC](https://datatracker.ietf.org/doc/html/rfc1951)  
[zlib algorithm  explained](https://github.com/madler/zlib/blob/643e17b7498d12ab8d15565662880579692f769d/doc/algorithm.txt)  
[Mark Adler on stackoverflow](https://stackoverflow.com/search?q=user%3A1180620+deflate)  
[Faster zlib/DEFLATE](https://dougallj.wordpress.com/2022/08/20/faster-zlib-deflate-decompression-on-the-apple-m1-and-x86/)  
[Reading bits with zero refill latency](https://dougallj.wordpress.com/2022/08/26/reading-bits-with-zero-refill-latency/)  
[the canterbury corpus](https://corpus.canterbury.ac.nz/descriptions/)  

### Notes:

Test files used in benchmarks:
```
mkdir -p src/benchdata
cd src/benchdata

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
