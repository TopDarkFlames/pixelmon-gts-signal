# frozen_string_literal: true

require "zlib"

class ResourceArchive
  Entry = Data.define(:name, :method, :compressed_size, :size, :local_offset)

  EOCD_SIGNATURE = "PK\x05\x06".b
  CENTRAL_SIGNATURE = "PK\x01\x02".b
  LOCAL_SIGNATURE = "PK\x03\x04".b

  attr_reader :path

  def initialize(path)
    @path = File.expand_path(path)
    eocd = find_eocd
    @offset_shift = detect_offset_shift(eocd)
    @entries = load_entries(eocd)
  end

  def entries
    @entries.values
  end

  def names
    @entries.keys
  end

  def entry(name)
    @entries[name]
  end

  def read(name)
    metadata = entry(name)
    return unless metadata

    File.open(path, "rb") do |file|
      file.seek(metadata.local_offset + @offset_shift)
      header = file.read(30)
      raise "Cabeçalho local inválido em #{path}: #{name}" unless header&.start_with?(LOCAL_SIGNATURE)

      values = header.unpack("a4vvvvvVVVvv")
      file.seek(values[9] + values[10], IO::SEEK_CUR)
      compressed = file.read(metadata.compressed_size)
      case metadata.method
      when 0 then compressed
      when 8 then Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(compressed)
      else raise "Compressão ZIP não suportada (#{metadata.method}) em #{name}"
      end
    end
  end

  private

  def load_entries(eocd)
    central_size = eocd.byteslice(12, 4).unpack1("V")
    central_offset = eocd.byteslice(16, 4).unpack1("V") + @offset_shift
    directory = File.open(path, "rb") do |file|
      file.seek(central_offset)
      file.read(central_size)
    end

    result = {}
    position = 0
    while directory.byteslice(position, 4) == CENTRAL_SIGNATURE
      header = directory.byteslice(position, 46)
      values = header.unpack("a4vvvvvvVVVvvvvvVV")
      name_length, extra_length, comment_length = values.values_at(10, 11, 12)
      name = directory.byteslice(position + 46, name_length).force_encoding("UTF-8")
      result[name] = Entry.new(
        name: name,
        method: values[4],
        compressed_size: values[8],
        size: values[9],
        local_offset: values[16]
      )
      position += 46 + name_length + extra_length + comment_length
    end
    result
  end

  def detect_offset_shift(eocd)
    declared_offset = eocd.byteslice(16, 4).unpack1("V")
    signatures = File.open(path, "rb") do |file|
      file.seek(declared_offset)
      file.read(8)
    end
    return 0 if signatures&.start_with?(CENTRAL_SIGNATURE)
    return 4 if signatures&.byteslice(4, 4) == CENTRAL_SIGNATURE

    raise "Deslocamento do diretório ZIP inválido: #{path}"
  end

  def find_eocd
    file_size = File.size(path)
    tail_size = [file_size, 131_072].min
    tail = File.open(path, "rb") do |file|
      file.seek(-tail_size, IO::SEEK_END)
      file.read(tail_size)
    end
    position = tail.rindex(EOCD_SIGNATURE)
    raise "Diretório central ZIP não encontrado: #{path}" unless position

    tail.byteslice(position, 22)
  end
end
