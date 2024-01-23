### Benchmarks

Huge file ziglang repo tar:
```sh
$ time zig-out/bin/gzip ziglang.tar
zig-out/bin/gzip ziglang.tar  2.11s user 0.07s system 99% cpu 2.179 total
24684593 ziglang.tar.gz


$ time gzip -kf ziglang.tar
gzip -kf ziglang.tar  2.50s user 0.03s system 99% cpu 2.532 total
24716226 ziglang.tar.gz
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

### Compression levels

Compression levels are in range 4-9, 4 = fast, 6 = default, 9 = best.
They have same compression parameters as [zlib](https://github.com/madler/zlib/blob/develop/deflate.c#L106) implementation. In zlib level 0 is store only, no compression. Levels 1-3 are using different algorithm, deflate_fast, without lazy matching.  
For now only default lazy matching algorithm is implemented, so here compression levels start from 4. 
 

```
zig build -Doptimize=ReleaseSafe && hyperfine -r 1 --parameter-scan level 4 9 'zig-out/bin/deflate_bench -l {level}'
Benchmark 1: zig-out/bin/deflate_bench -l 4
  Time (abs ≡):         1.051 s               [User: 1.043 s, System: 0.008 s]

Benchmark 2: zig-out/bin/deflate_bench -l 5
  Time (abs ≡):         1.419 s               [User: 1.411 s, System: 0.008 s]

Benchmark 3: zig-out/bin/deflate_bench -l 6
  Time (abs ≡):         2.014 s               [User: 2.010 s, System: 0.004 s]

Benchmark 4: zig-out/bin/deflate_bench -l 7
  Time (abs ≡):         2.509 s               [User: 2.509 s, System: 0.000 s]

Benchmark 5: zig-out/bin/deflate_bench -l 8
  Time (abs ≡):         4.522 s               [User: 4.509 s, System: 0.012 s]

Benchmark 6: zig-out/bin/deflate_bench -l 9
  Time (abs ≡):         6.771 s               [User: 6.758 s, System: 0.012 s]

Summary
  zig-out/bin/deflate_bench -l 4 ran
    1.35 times faster than zig-out/bin/deflate_bench -l 5
    1.92 times faster than zig-out/bin/deflate_bench -l 6
    2.39 times faster than zig-out/bin/deflate_bench -l 7
    4.30 times faster than zig-out/bin/deflate_bench -l 8
    6.44 times faster than zig-out/bin/deflate_bench -l 9
```

```
$ for level in {4..9}; do; echo "\nlevel $level" && zig-out/bin/deflate_bench -l $level ; done

level 4
bytes: 26610463

level 5
bytes: 25230903

level 6
bytes: 24716208

level 7
bytes: 24572027

level 8
bytes: 24419444

level 9
bytes: 24370812
```



[Zlib compression levels](https://github.com/madler/zlib/blob/develop/deflate.c#L106)  
[Go compression levels](https://github.com/ziglang/zig/blob/993a83081a975464d1201597cf6f4cb7f6735284/lib/std/compress/deflate/compressor.zig#L78)  
