# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "thread"
require_relative "resource_archive"

module GTSAssets
  Asset = Data.define(:archive, :entry, :kind)
  Rule = Data.define(:archive, :custom_texture, :lore_id, :model, :texture, :directory)

  class Catalog
    attr_reader :minecraft_root

    def initialize(minecraft_root)
      @minecraft_root = File.expand_path(minecraft_root)
      @sprites = open_latest("resourcepacks/*sprites*.zip")
      @hd = open_latest("resourcepacks/*hd*.zip")
      @cosmetic_archives = [
        open_latest("resourcepacks/*cosmeticos*.zip"),
        open_latest("resourcepacks/*extras*.zip")
      ].compact
      @pixelmon = open_latest("mods/Pixelmon*.jar")
      @species = build_species_index
      @custom_sprites = build_sprite_index(@sprites, %r{/sprites/custom-([^/]+)/([0-9]{3,4})([^/]*)\.png$}i)
      @hd_sprites = build_sprite_index(@hd, %r{/sprites/pokemon/([0-9]{3,4})([^/]*)\.png$}i, default: true)
      @default_sprites = build_sprite_index(@pixelmon, %r{/sprites/pokemon/([0-9]{3,4})([^/]*)\.png$}i, default: true)
      @cosmetic_rules = build_cosmetic_rules
    end

    def resolve(row)
      pokemon_asset(row) || cosmetic_asset(row)
    rescue StandardError => e
      warn "Falha ao resolver imagem GTS: #{e.message}"
      nil
    end

    def cache(row, directory)
      cache_asset(resolve(row), directory)
    end

    def cache_asset(asset, directory)
      return unless asset

      key = Digest::SHA256.hexdigest("#{asset.archive.path}\0#{File.mtime(asset.archive.path).to_i}\0#{asset.entry}")
      path = File.join(directory, "#{key}.png")
      return path if File.file?(path) && File.size?(path)

      FileUtils.mkdir_p(directory)
      temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.binwrite(temporary, asset.archive.read(asset.entry))
      File.rename(temporary, path)
      path
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    private

    def open_latest(pattern)
      path = Dir[File.join(minecraft_root, pattern)].max_by { |candidate| File.mtime(candidate) }
      ResourceArchive.new(path) if path
    end

    def fold(value)
      value.to_s.unicode_normalize(:nfkd).encode("ASCII", invalid: :replace, undef: :replace, replace: "")
           .downcase.gsub(/[^a-z0-9]+/, " ").strip
    end

    def build_species_index
      return [] unless @pixelmon

      species = @pixelmon.names.filter_map do |name|
        match = name.match(%r{assets/pixelmon/stats/([0-9]{3,4})\.json$})
        next unless match

        data = JSON.parse(@pixelmon.read(name))
        display_name = data["pixelmonName"] || data["pokemon"]
        normalized = fold(display_name)
        [normalized, match[1].to_i] unless normalized.empty?
      rescue JSON::ParserError
        nil
      end
      species.uniq.sort_by { |name, _dex| -name.length }
    end

    def build_sprite_index(archive, pattern, default: false)
      return {} unless archive

      archive.names.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |name, result|
        match = name.match(pattern)
        next unless match

        if default
          key = ["original", match[1].to_i]
          suffix = match[2]
        else
          key = [fold(match[1]).delete(" "), match[2].to_i]
          suffix = match[3]
        end
        result[key] << [name, suffix.to_s]
      end
    end

    def pokemon_asset(row)
      return unless row["is_pokemon"].to_i == 1 || custom_texture_listing?(row)

      item = fold(row["item"])
      species = @species.find { |name, _dex| item.match?(/(?:^| )#{Regexp.escape(name)}(?: |$)/) }
      return unless species

      dex = species[1]
      texture = fold(row["texture"]).delete(" ")
      texture = "original" if texture.empty? || texture == "original"
      if texture == "original"
        candidates = @hd_sprites.fetch([texture, dex], [])
        archive = @hd
        if candidates.empty?
          candidates = @default_sprites.fetch([texture, dex], [])
          archive = @pixelmon
        end
      else
        candidates = @custom_sprites.fetch([texture, dex], [])
        candidates = fallback_custom_sprites(texture, dex, item) if candidates.empty?
        archive = @sprites
      end
      return if candidates.empty?

      entry = choose_sprite(candidates, item)
      Asset.new(archive: archive, entry: entry, kind: "pokemon")
    end

    def fallback_custom_sprites(texture, dex, item)
      texture = texture.to_s
      item = item.to_s
      dex = dex.to_i
      best_key = nil

      @custom_sprites.each_key do |candidate|
        texture_key, candidate_dex = candidate
        texture_key = texture_key.to_s
        next unless candidate_dex.to_i == dex
        next unless texture.start_with?(texture_key) || item.include?(texture_key)
        next if @custom_sprites.fetch(candidate, []).empty?
        next if best_key && best_key[0].to_s.length >= texture_key.length

        best_key = candidate
      end

      best_key ? @custom_sprites.fetch(best_key, []) : []
    end

    def custom_texture_listing?(row)
      texture = fold(row["texture"]).delete(" ")
      !texture.empty? && texture != "original"
    end

    def choose_sprite(candidates, item)
      candidates.min_by do |name, suffix|
        normalized_suffix = fold(suffix)
        form_match = !normalized_suffix.empty? && item.include?(normalized_suffix)
        priority = if form_match then 0
                   elsif suffix.empty? then 1
                   elsif normalized_suffix == "normal" then 2
                   elsif normalized_suffix == "hero" then 3
                   elsif normalized_suffix.match?(/shiny|gmax|zombie/) then 8
                   else 5
                   end
        [priority, name]
      end&.first
    end

    def build_cosmetic_rules
      @cosmetic_archives.flat_map do |archive|
        archive.names.grep(/\.properties$/i).filter_map do |name|
          body = archive.read(name).to_s.force_encoding("UTF-8").scrub
          custom = body[/^nbt\.CustomTexture\s*=\s*(.+?)\s*$/i, 1]
          lore = body[/^nbt\.display\.Lore\.\*\s*=.*?\[([A-Za-z]?\d+)\]/i, 1]
          next unless custom || lore

          Rule.new(
            archive: archive,
            custom_texture: custom&.strip,
            lore_id: lore&.upcase,
            model: body[/^model\s*=\s*(.+?)\s*$/i, 1]&.strip,
            texture: body[/^texture(?:\.\w+)?\s*=\s*(.+?)\s*$/i, 1]&.strip,
            directory: File.dirname(name)
          )
        end
      end
    end

    def cosmetic_asset(row)
      return if @cosmetic_rules.empty?

      payload = row["hover_payload"].to_s
      return if payload.empty?

      custom = payload[/(?:CustomTexture|TextureTokenID)\s*:\s*"([^"\\]+)"/i, 1]
      lore_ids = payload.scan(/\[([A-Za-z]?\d+)\]/).flatten.map(&:upcase)
      rule = if custom
               @cosmetic_rules.find { |candidate| candidate.custom_texture.to_s.casecmp?(custom) }
             end
      rule ||= @cosmetic_rules.find { |candidate| lore_ids.include?(candidate.lore_id) }
      return unless rule

      entry = texture_entry_for_rule(rule)
      Asset.new(archive: rule.archive, entry: entry, kind: "cosmetic") if entry
    end

    def texture_entry_for_rule(rule)
      if rule.texture
        entry = resolve_texture_path(rule.texture, rule.directory, rule.archive)
        return entry if rule.archive.entry(entry)
      end
      return unless rule.model

      model_name = rule.model.end_with?(".json") ? rule.model : "#{rule.model}.json"
      model_entry = File.join(rule.directory, model_name)
      model_entry = "assets/minecraft/models/#{model_name}" unless rule.archive.entry(model_entry)
      texture_from_model(model_entry, rule.archive)
    end

    def texture_from_model(model_entry, archive, visited = [])
      return if visited.include?(model_entry) || !archive.entry(model_entry)

      model = JSON.parse(archive.read(model_entry))
      texture = model.fetch("textures", {}).values.find { |value| value.is_a?(String) && !value.start_with?("#") }
      return resolve_texture_path(texture, File.dirname(model_entry), archive) if texture

      parent = model["parent"].to_s
      return if parent.empty? || parent.start_with?("item/") || parent.start_with?("block/")

      parent_entry = parent.include?(":") ? parent.split(":", 2).last : parent
      parent_entry = "assets/minecraft/models/#{parent_entry}.json" unless parent_entry.start_with?("assets/")
      texture_from_model(parent_entry, archive, visited + [model_entry])
    rescue JSON::ParserError
      nil
    end

    def resolve_texture_path(value, directory, archive)
      clean = value.to_s.sub(/^minecraft:/, "").sub(/\.png$/i, "")
      candidates = [
        "assets/minecraft/textures/#{clean}.png",
        File.expand_path("#{clean}.png", "/#{directory}").delete_prefix("/")
      ]
      candidates.find { |candidate| archive.entry(candidate) } || candidates.first
    end
  end

  @mutex = Mutex.new
  @catalogs = {}

  module_function

  def catalog(minecraft_root)
    @mutex.synchronize { @catalogs[minecraft_root] ||= Catalog.new(minecraft_root) }
  end
end
