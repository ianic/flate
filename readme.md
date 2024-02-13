Zig deflate compression/decompression implementation. It supports compression and decompression of gzip, zlib and raw deflate format. Andrew [pushed](https://github.com/ziglang/zig/issues/18062) for the implementation from the first principles so I give it a try.

Zig's [implementation](https://github.com/ziglang/zig/tree/master/lib/std/compress/deflate) is ported from [Go](https://github.com/golang/go/tree/master/src/compress/flate) by huge effort of [hdorio](https://github.com/hdorio). Go implementation mainly follows original [zlib](https://github.com/madler/zlib) implementation.

Here I used all those three as reference, but mostly started from scratch. Inflate (decompression) and deflate tokenization are implemented from the first principles. For deflate block writer I started from current std code. 

## Benchmark

Comparing this implementation with the one we currently have in Zig's standard library (std).   
Std is roughly 1.2-1.4 times slower in decompression, and 1.1-1.2 times slower in compression. Compressed sizes are pretty much same in both cases.  

Benchmark are done on aarch64/Linux (Apple M1 cpu): 

### Compression

Compression examples are using Zig repository tar ~177M file.

Compression time in comparison with std (current Zig standard library implementation):
| level | time [ms] | std [ms] | time/std  |
| :---  |      ---: |     ---: |      ---: |
| store | 16.42 | 20.29 | 1.24 |
| huffman only | 442.32 | 587.74 | 1.33 |
| 4 | 912.58 | 1002.99 | 1.1 |
| 5 | 1258.05 | 1429.21 | 1.14 |
| 6 - default | 1824.60 | 2065.15 | 1.13 |
| 7 | 2291.04 | 2798.50 | 1.22 |
| 8 | 4158.42 | 4706.27 | 1.13 |
| 9 | 6268.29 | 7738.94 | 1.23 |

Compressed size in comparison with std:
| level | size | std size |  diff | size/std  |
| :---  | ---: |     ---: |  ---: |      ---: |
| store | 177257685 | 177257690 | 5 | 1.0000 |
| huffman only | 108397982 | 108397986 | 4 | 1.0000 |
| 4 | 26610356 | 26557083 | -53273 | 0.9980 |
| 5 | 25230832 | 25212703 | -18129 | 0.9993 |
| 6 - default | 24716132 | 24716123 | -9 | 1.0000 |
| 7 | 24571921 | 24562137 | -9784 | 0.9996 |
| 8 | 24419337 | 24425085 | 5748 | 1.0002 |
| 9 | 24370739 | 24389533 | 18794 | 1.0008 |

### Decompression

Decompression time for few different files in comparison with std:
| file | size |  time [ms] | std [ms] | time/std  |
| :--- | ---: |       ---: |     ---: |      ---: |
| ziglang.tar.gz | 177244160  | 364.36 | 451.88 | 1.24 |
| war_and_peace.txt.gz | 3359630  | 13.65 | 18.51 | 1.36 |
| large.tar.gz | 11162624  | 38.31 | 49.71 | 1.3 |
| cantrbry.tar.gz | 2821120  | 9.33 | 12.19 | 1.31 |

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
| store | 17.87 | 37.71 | 2.11 |
| huffman only | 536.96 | 712.69 | 1.33 |
|4 | 1298.81 | 1611.90 | 1.24 |
|5 | 1682.73 | 2181.59 | 1.3 |
|6 - default | 2328.75 | 3092.51 | 1.33 |
|7 | 2888.99 | 4220.92 | 1.46 |
|8 | 5100.41 | 7001.97 | 1.37 |
|9 | 7265.84 | 10723.13 | 1.48 |


| file | size |  time [ms] | std [ms] | time/std  |
| :--- | ---: |       ---: |     ---: |      ---: |
| ziglang.tar.gz | 177244160  | 538.45 | 680.66 | 1.26 |
| war_and_peace.txt.gz | 3359630  | 21.73 | 31.22 | 1.44 |
| large.tar.gz | 11162624  | 62.02 | 74.89 | 1.21 |
| cantrbry.tar.gz | 2821120  | 14.77 | 21.39 | 1.45 |


## Memory usage

This library uses static allocations for all structures, doesn't require allocator. That makes sense especially for deflate where all structures, internal buffers are allocated to the full size. Little less for inflate where we std version uses less memory by not preallocating to theoretical max size array which are usually not fully used. 

For deflate this library allocates 395K while std 779K.  
For inflate this library allocates 74.5K while std usually around 36K.  

Inflate difference is because we here use 64K history instead of 32K in std.

## Interface

Currently in std lib we have different wording for the same things. Type is called Decompressor, Decompress, DecompressStream (deflate, gzip, zlib). I'll suggest that we stick with Decompressor/Compressor and decompressor/compressor for initializers of that type. That will free compress/decompress word for one-shot action. Fn compress receives reader and writer, reads all plain data from reader and writes compressed data to the writer. I expect that many places can use this simple implementation.  

All gzip/zlib/flate will have same methods:
```Zig
/// Compress from reader and write compressed data to the writer.
fn compress(reader: anytype, writer: anytype, options: Options) !void 

/// Create Compressor which outputs the writer.
fn compressor(writer: anytype, options: Options) !Compressor(@TypeOf(writer))

/// Compressor type
fn Compressor(comptime WriterType: type) type 


/// Decompress from reader and write plain data to the writer.
fn decompress(reader: anytype, writer: anytype) !void

/// Create Decompressor which reads from reader.
fn decompressor(reader: anytype) Decompressor(@TypeOf(reader)

/// Decompressor type
fn Decompressor(comptime ReaderType: type) type
 
```

## References

Great materials for understanding deflate:

[Bill Bird Video series](https://www.youtube.com/watch?v=SJPvNi4HrWQ&t)  
[RFC 1951 - deflate](https://datatracker.ietf.org/doc/html/rfc1951)  
[RFC 1950 - zlib](https://datatracker.ietf.org/doc/html/rfc1950)  
[RFC 1952 - gzip](https://datatracker.ietf.org/doc/html/rfc1952)  
[zlib algorithm  explained](https://github.com/madler/zlib/blob/643e17b7498d12ab8d15565662880579692f769d/doc/algorithm.txt)  
[zlib manual](https://www.zlib.net/manual.html)  
[Mark Adler on stackoverflow](https://stackoverflow.com/search?q=user%3A1180620+deflate)  
[Faster zlib/DEFLATE](https://dougallj.wordpress.com/2022/08/20/faster-zlib-deflate-decompression-on-the-apple-m1-and-x86/)  
[Reading bits with zero refill latency](https://dougallj.wordpress.com/2022/08/26/reading-bits-with-zero-refill-latency/)  


