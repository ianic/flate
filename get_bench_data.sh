#!/bin/bash

mkdir -p bench_data
cd bench_data

wget -nc -O ziglang.tar.gz https://github.com/ziglang/zig/archive/bb0f7d55e8c50e379fa9bdcb8758d89d08e0cc1f.tar.gz
wget -nc -O war_and_peace.txt https://www.gutenberg.org/ebooks/2600.txt.utf-8
wget -nc https://corpus.canterbury.ac.nz/resources/cantrbry.tar.gz
wget -nc https://corpus.canterbury.ac.nz/resources/large.tar.gz

gunzip -kf ziglang.tar.gz
gunzip -kf cantrbry.tar.gz
gunzip -kf large.tar.gz
