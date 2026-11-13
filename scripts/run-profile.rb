#!/usr/bin/env ruby
# A strict string-only TOML subset, matching the consumer config's notation.
# Resolution snapshots the preparation script and hashes values, never host paths.
require "digest"
require "base64"
require "json"

begin
  mode, file, arch = ARGV
  case mode
  when "seal"
    digest = Digest::SHA256.new
    names = %w[release]
    names += File.read(File.join(file, "release")).empty? ? %w[guest-release] : %w[vmlinuz initrd.img cmdline]
    names.each do |name|
      bytes = File.binread(File.join(file, name))
      raise "empty profile boot artifact: #{name}" if bytes.empty? && name != "release"
      digest << [bytes.bytesize].pack("Q>") << bytes
    end
    puts digest.hexdigest
  when "cmdline"
    line = STDIN.read.chomp
    raise "invalid guest kernel command line" unless line.match?(/\A[ -~]+\z/)
    words = line.split.reject { |word| word.start_with?("BOOT_IMAGE=", "initrd=") }
    raise "guest kernel command line has no root=" unless words.any? { |word| word.start_with?("root=") }
    puts words.join(" ")
  when "resolve"
    raise "unsupported architecture #{arch.inspect}" unless %w[x86_64 aarch64].include?(arch)
    sections = {}
    section = nil
    File.readlines(file, encoding: "UTF-8").each_with_index do |line, index|
      where = "#{file}:#{index + 1}"
      line = line.strip
      next if line.empty? || line.start_with?("#")
      if (match = /\A\[([a-z0-9_]+)\]\s*(?:#.*)?\z/.match(line))
        section = match[1]
        raise "#{where}: unknown section [#{section}]" unless %w[profile x86_64 aarch64].include?(section)
        raise "#{where}: duplicate section [#{section}]" if sections.key?(section)
        sections[section] = {}
        next
      end
      match = /\A([a-z_][a-z0-9_]*)\s*=\s*(?:"([^"\\]*)"|'([^']*)')\s*(?:#.*)?\z/.match(line)
      raise "#{where}: expected key = quoted string inside a section" unless match && section
      key, value = match[1], match[2] || match[3]
      raise "#{where}: unknown key #{key}" unless %w[guest release setup setup_sha256 modules].include?(key)
      raise "#{where}: duplicate key #{key}" if sections[section].key?(key)
      raise "#{where}: control character in #{key}" if value.match?(/[\x00-\x1f\x7f]/)
      sections[section][key] = value
    end
    raise "#{file}: [profile] is required" unless sections.key?("profile")
    values = sections["profile"].merge(sections.fetch(arch, {}))
    guest = values.fetch("guest", "debian-12")
    release = values.fetch("release", "")
    raise "#{file}: guest must be debian-12 or debian-13" unless %w[debian-12 debian-13].include?(guest)
    if sections.values.any? { |fields| fields.key?("release") }
      raise "#{file}: release must name an exact kernel release for #{arch}" unless release.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._+\-]{0,127}\z/)
    end
    modules = values.fetch("modules", "").split.sort.uniq
    raise "#{file}: invalid module name" unless modules.all? { |name| name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_\-]*\z/) }
    setup = values.fetch("setup", "")
    checksum = values.fetch("setup_sha256", "")
    bytes = ""
    if setup.empty?
      raise "#{file}: setup_sha256 requires setup" unless checksum.empty?
    else
      raise "#{file}: setup must be a relative path inside the profile directory" unless setup.match?(/\A[a-zA-Z0-9_.\/-]+\z/) && !setup.start_with?("/") && !setup.split("/").include?("..")
      root = File.realpath(File.dirname(file))
      path = File.realpath(File.join(root, setup))
      raise "#{file}: setup leaves the profile directory" unless path.start_with?(root + "/")
      raise "#{file}: setup exceeds 64 KiB" if File.size(path) > 65_536
      bytes = File.binread(path)
      raise "#{file}: setup_sha256 must be the preparation script's SHA-256" unless checksum.match?(/\A[0-9a-f]{64}\z/)
      raise "#{file}: setup_sha256 mismatch for #{setup}" unless Digest::SHA256.hexdigest(bytes) == checksum
    end
    fingerprint = Digest::SHA256.hexdigest(JSON.generate(["run-profile-v1", arch, guest, release, modules, Digest::SHA256.hexdigest(bytes)]))
    {"guest" => guest, "release" => release, "modules" => modules.join(" "),
     "payload" => Base64.strict_encode64(bytes), "fingerprint" => fingerprint}.each do |key, value|
      puts "#{key}\t#{value}"
    end
  else
    raise "usage: run-profile.rb resolve MANIFEST ARCH | seal DIR | cmdline"
  end
rescue StandardError => e
  warn "run-profile: #{e.message}"
  exit 1
end
