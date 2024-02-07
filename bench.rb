require 'json'

levels = [0] + (4..9).to_a

def bench
  `zig build bench -Doptimize=ReleaseSafe`
  levels.each do |level|
    `hyperfine --warmup 1 -r 3 'zig-out/bin/deflate_bench -l #{level}' 'zig-out/bin/deflate_bench -s -l #{level}' --export-json tmp/bench_#{level}.json`
    `zig-out/bin/deflate_bench -l #{level} 2>tmp/size_#{level}`
    `zig-out/bin/deflate_bench -s -l #{level} 2>tmp/size_std_#{level}`
  end
end

def size_from_file(fn)
  File.read(fn).split(" ")[1].to_i
end

data = []

levels.each do |level|
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


pp data


print "| level | time [ms] | std [ms] | time/std  |\n"
print "| :---  |     ---: |     ---: |      ---: |\n"
data.each do |d|
  std = d[:std][:mean]
  lib = d[:lib][:mean]
  print "|#{d[:level]} | #{'%.2f' %  lib} | #{'%.2f' %  std} | #{(std/lib).round( 2)} |\n"
end


print "| level | size | std [ms] | sizs/std  |\n"
print "| :---  |     ---: |     ---: |      ---: |\n"
data.each do |d|
  std = d[:std][:size]
  lib = d[:lib][:size]
  print "| #{d[:level]} | #{lib} #{std} | #{(std-lib)} | #{'%.4f' % (std.to_f/lib.to_f)} | \n"
end
