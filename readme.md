Zig deflate compression/decompression implementation. It supports compression and decompression of gzip, zlib and raw deflate format. Andrew [pushed](https://github.com/ziglang/zig/issues/18062) for the implementation from the first principles so I give it a try.

Zig's [implementation](https://github.com/ziglang/zig/tree/master/lib/std/compress/deflate) is ported from [Go](https://github.com/golang/go/tree/master/src/compress/flate) by huge effort of [hdorio](https://github.com/hdorio). Go implementation mainly follows original [zlib](https://github.com/madler/zlib) implementation.

Here I used all those three as reference, but mostly started from scratch. Inflate (decompression) and deflate tokenization are implemented from the first principles. For deflate block writer I started from current std code. 

## Benchmark

Comparing this implementation with the one we currently have in Zig's standard library (std).   
Std is roughly 1.5 times slower in decompression, and 1.17 times slower in compression. Compressed sizes are pretty much same in both cases.  

Benchmark are done on aarch64/Linux (Apple M1 cpu): 

### Compression

Compression examples are using Zig repository tar ~177M file.

Compression time in comparison with std (current Zig standard library implementation):
| level | time [ms] | std [ms] | time/std  |
| :---  |      ---: |     ---: |      ---: |
|0 | 472.83 | 543.02 | 1.15 |
|4 | 1019.52 | 1222.02 | 1.2 |
|5 | 1401.85 | 1673.52 | 1.19 |
|**6 - default** | 1994.97 | 2325.23 | 1.17 |
|7 | 2505.55 | 3141.31 | 1.25 |
|8 | 4491.72 | 5118.71 | 1.14 |
|9 | 6713.99 | 8243.63 | 1.23 |

Compressed size in comparison with std:
| level | size | std size |  diff | size/std  |
| :---  | ---: |     ---: |  ---: |      ---: |
| 0 | 108398793 | 108397986 | -807 | 1.0000 |
| 4 | 26610575 | 26557083 | -53492 | 0.9980 |
| 5 | 25231037 | 25212703 | -18334 | 0.9993 |
|**6 - default** | 24716324 | 24716123 | -201 | 1.0000 |
| 7 | 24572126 | 24562137 | -9989 | 0.9996 |
| 8 | 24419542 | 24425085 | 5543 | 1.0002 |
| 9 | 24370948 | 24389533 | 18585 | 1.0008 |

### Decompression

Decompression time for few different files in comparison with std:
| file | size |  time [ms] | std [ms] | time/std  |
| :--- | ---: |       ---: |     ---: |      ---: |
| ziglang.tar.gz | 177244160  | 353.34 | 519.44 | 1.47 |
| war_and_peace.txt.gz | 3359630  | 13.55 | 21.36 | 1.58 |
| large.tar.gz | 11162624  | 37.93 | 57.53 | 1.52 |
| cantrbry.tar.gz | 2821120  | 9.08 | 14.30 | 1.57 |

URLs from which tests files are obtained can be found [here](https://github.com/ianic/flate/blob/2dda0321a658e52e6b3978f7216744af696b69c0/get_bench_data.sh#L6).

### Note

I was also comparing with gzip/gunzip system tools and the results are pretty much similar.

To compare with gzip/gunzip: 

```
zig build -Doptimize=ReleaseSafe
export FILE=tmp/ziglang.tar.gz
hyperfine -r 5 'zig-out/bin/gunzip $FILE' 'gunzip -kf $FILE'

export FILE=tmp/ziglang.tar
hyperfine -r 5 'zig-out/bin/gzip $FILE' 'gzip -kf $FILE'
```

Running same benchmarks on x86_64 GNU/Linux (Intel(R) Core(TM) i7-3520M CPU @ 2.90GHz):

| level | time [ms] | std [ms] | time/std  |
| :---  |      ---: |     ---: |      ---: |
|0 | 602.97 | 740.39 | 1.23 |
|4 | 1434.57 | 1837.89 | 1.28 |
|5 | 1875.17 | 2454.04 | 1.31 |
|6 | 2581.49 | 3353.04 | 1.3 |
|7 | 3211.47 | 4749.88 | 1.48 |
|8 | 6444.44 | 7359.56 | 1.14 |
|9 | 8175.93 | 11447.38 | 1.4 |


| file | size |  time [ms] | std [ms] | time/std  |
| :--- | ---: |       ---: |     ---: |      ---: |
| ziglang.tar.gz | 177244160  | 567.85 | 858.50 | 1.51 |
| war_and_peace.txt.gz | 3359630  | 25.96 | 36.04 | 1.39 |
| large.tar.gz | 11162624  | 65.68 | 99.80 | 1.52 |
| cantrbry.tar.gz | 2821120  | 17.69 | 26.85 | 1.52 |

## Memory usage

This library uses static allocations for all structures, doesn't require allocator. That makes sense especially for deflate where all structures, internal buffers are allocated to the full size. Little less for inflate where we std version uses less memory by not preallocating to theoretical max size array which are usually not fully used. 

For deflate this library allocates 395K while std 779K.  
For inflate this library allocates 195K while std usually around 36K.  

Inflate difference is because we here use 64K history instead of 32K, and main reason because in huffman_decoder.zig we use lookup of 32K places for 286 or 30 symbols!


## References

Great materials for understanding deflate:

[Bill Bird Video series](https://www.youtube.com/watch?v=SJPvNi4HrWQ&t)  
[RFC 1951 - deflate](https://datatracker.ietf.org/doc/html/rfc1951)  
[RFC 1950 - zlib](https://datatracker.ietf.org/doc/html/rfc1950)  
[RFC 1952 - gzip](https://datatracker.ietf.org/doc/html/rfc1952)  
[zlib algorithm  explained](https://github.com/madler/zlib/blob/643e17b7498d12ab8d15565662880579692f769d/doc/algorithm.txt)  
[Mark Adler on stackoverflow](https://stackoverflow.com/search?q=user%3A1180620+deflate)  
[Faster zlib/DEFLATE](https://dougallj.wordpress.com/2022/08/20/faster-zlib-deflate-decompression-on-the-apple-m1-and-x86/)  
[Reading bits with zero refill latency](https://dougallj.wordpress.com/2022/08/26/reading-bits-with-zero-refill-latency/)  


