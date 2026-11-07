# frozen_string_literal: true

# Check that a change to gag matching leaves what the user sees alone. See
# README.md.
#
# Feeds every line of each INPUT through the real LineFilter of CODE_DIR,
# with the gags of a settings file, and writes one line of output per input
# line: the pass, whether the line was gagged, and the line the filter kept
# (inspect, so nil is visible). Every input is fed twice, so the second
# pass shows lines the filter has seen before (memos, caches). Run it on
# two checkouts and compare the outputs with cmp.
#
# INPUT is a fixture (.jsonl from stream_fixture.rb), or a Lich log,
# record.rb recording or plain stream, read as stream_fixture.rb reads it.
#
# Lines go to the filter as the server sent them. The client first carries
# bold across lines (GameTextProcessor#carry_bold, which adds <pushBold/> or
# <popBold/>), so a gag written against those tags could see different
# input here; both checkouts get the same input, so the comparison holds.
#
# usage: ruby script/bench/filter_dump.rb CODE_DIR SETTINGS.xml OUT INPUT...
#   e.g. ruby script/bench/filter_dump.rb ../pfe-main templates/default.xml main.txt crafting.jsonl
#        ruby script/bench/filter_dump.rb .            templates/default.xml mine.txt crafting.jsonl
#        cmp main.txt mine.txt

require 'json'
require 'rexml/document'
require_relative 'stream_fixture'

code, settings, out, *inputs = ARGV
abort File.read(__FILE__)[/^# usage:.*?\n(?:#.*\n)*/] unless code && settings && out && !inputs.empty?

# The filter logs gags only with --log-gags; nothing is logged here.
module ProfanityLog
  # @return [nil]
  def self.write(*) = nil
end
require File.join(File.expand_path(code), 'lib', 'gag_patterns')
require File.join(File.expand_path(code), 'lib', 'line_filter')

# The settings the filter reads (SharedState#log_gags only).
FilterState = Struct.new(:log_gags)

# The same entity table Application passes the filter (lib/application.rb).
XML_ESCAPES = { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' }.freeze

# Read the gags as SettingsLoader does (lib/settings_loader.rb).
gags = { general: [], multiline: [], combat: [] }
REXML::Document.new(File.read(settings)).root.each_element do |e|
  case e.name
  when 'gag' then gags[:general] << e.text if e.text && !e.text.strip.empty?
  when 'combat_gag' then gags[:combat] << e.text if e.text && !e.text.strip.empty?
  when 'multiline_gag'
    start = e.attributes['start']
    gags[:multiline] << { start: start, end: e.attributes['end'] } if start && !start.strip.empty?
  end
end
GagPatterns.replace_custom(**gags)

lines = inputs.flat_map do |file|
  chunks = if file.end_with?('.jsonl')
             File.readlines(file).reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
           else
             StreamFixture.new.convert(File.readlines(file, mode: 'rb'))
           end
  chunks.flat_map { |chunk| chunk['data'].split("\n", -1)[0..-2] }
end

filter = LineFilter.new(shared_state: FilterState.new(false), xml_escapes: XML_ESCAPES)
gagged = 0
File.open(out, 'w') do |file|
  2.times do |pass|
    lines.each do |line|
      # ServerReader treats socket bytes as UTF-8 and scrubs them first.
      kept = filter.filter(line.dup.force_encoding(Encoding::UTF_8).scrub)
      gagged += 1 if filter.gagged?
      file.puts "#{pass} #{filter.gagged? ? 'G' : '-'} #{kept.inspect}"
    end
  end
end
warn "#{out}: #{lines.size} lines x 2, #{gagged} gagged; gags: #{gags[:general].size} general, " \
     "#{gags[:multiline].size} multi-line, #{gags[:combat].size} combat"
