#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/resource_archive"

archive = ResourceArchive.new(ARGV.fetch(0))
patterns = ARGV.drop(1)
matches = archive.names.select { |name| patterns.empty? || patterns.any? { |pattern| name.downcase.include?(pattern.downcase) } }
puts "#{archive.path}: #{archive.names.length} arquivos"
puts matches.first(300)
