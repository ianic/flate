require 'json'

$levels = [0, 1] + (4..9).to_a

def deflate_bench
  `mkdir -p tmp`
  # file="bin/bench_data/war_and_peace.txt"
  file="bin/bench_data/ziglang.tar"
  `zig build bench -Doptimize=ReleaseFast`
  $levels.each do |level|
    `hyperfine --warmup 1 -r 3 'zig-out/bin/deflate_bench -l #{level} #{file}' 'zig-out/bin/deflate_bench -s -l #{level} #{file}' --export-json tmp/bench_#{level}.json`
    `zig-out/bin/deflate_bench -l #{level} 2>tmp/size_#{level} #{file}`
    `zig-out/bin/deflate_bench -s -l #{level} 2>tmp/size_std_#{level} #{file}`
  end
end

def size_from_file(fn)
  File.read(fn).split(" ")[1].to_i
end

def print_deflate_bench
  data = []

  $levels.each do |level|
    j = JSON.parse(File.read("tmp/bench_#{level}.json"))

    r = j["results"]
    lib = 0
    std = 1
    if r[0]["command"].include?(" -s ")
      lib = 1
      std = 0
    end

    data << {
      :level => level,
      :std => {
        :mean => r[std]["mean"].to_f * 1000,
        :size => size_from_file("tmp/size_std_#{level}"),
      },
      :lib => {
        :mean => r[lib]["mean"].to_f * 1000,
        :size => size_from_file("tmp/size_#{level}"),
      },
    }
  end

  # pp data

  print "| level | time [ms] | std [ms] | time/std  |\n"
  print "| :---  |      ---: |     ---: |      ---: |\n"
  data.each do |d|
    std = d[:std][:mean]
    lib = d[:lib][:mean]
    print "|#{d[:level]} | #{'%.2f' %  lib} | #{'%.2f' %  std} | #{(std/lib).round( 2)} |\n"
  end
  print "\n"

  print "| level | size | std size |  diff | size/std  |\n"
  print "| :---  | ---: |     ---: |  ---: |      ---: |\n"
  data.each do |d|
    std = d[:std][:size]
    lib = d[:lib][:size]
    print "| #{d[:level]} | #{lib} | #{std} | #{(std-lib)} | #{'%.4f' % (std.to_f/lib.to_f)} | \n"
  end
  print "\n"
end


def inflate_bench
  data = []

  `zig build bench -Doptimize=ReleaseFast`
  (0..3).to_a.each do |input|
    `hyperfine --warmup 1 -r 3 'zig-out/bin/inflate_bench -i #{input}' 'zig-out/bin/inflate_bench -s -i #{input}' --export-json tmp/inflate_#{input}.json`

    j = JSON.parse(File.read("tmp/inflate_#{input}.json"))
    r = j["results"]
    lib = 0
    std = 1
    if r[0]["command"].include?(" -s ")
      lib = 1
      std = 0
    end
    data << {
      :input => input,
      :std => {
        :mean => r[std]["mean"].to_f * 1000,
      },
      :lib => {
        :mean => r[lib]["mean"].to_f * 1000,
      },
    }
  end

  print "| file | size |  time [ms] | std [ms] | time/std  |\n"
  print "| :--- | ---: |       ---: |     ---: |      ---: |\n"
  data.each do |d|
    std = d[:std][:mean]
    lib = d[:lib][:mean]
    f = $inputs[d[:input]]
    print "| #{f[:name]} | #{f[:bytes]}  | #{'%.2f' %  lib} | #{'%.2f' %  std} | #{(std/lib).round( 2)} |\n"
  end
  print "\n"
end

$inputs = ["ziglang.tar.gz", "war_and_peace.txt.gz"]

$inputs = [
   {
        :name => "ziglang.tar.gz",
        :bytes => 177244160,
    },
   {
        :name => "war_and_peace.txt.gz",
        :bytes => 3359630,
    },
    {
        :name => "large.tar.gz",
        :bytes => 11162624,
    },
    {
        :name => "cantrbry.tar.gz",
        :bytes => 2821120,
    },
];

inflate_bench

deflate_bench
print_deflate_bench
