require 'fileutils'
require 'open3'

def artifact_processes
  output, error, status = Open3.capture3('ps', '-eo', 'args=')
  raise "cannot read process table: #{error.strip}" unless status.success? && !output.strip.empty?

  output.lines.select { |line| line.split.first.to_s.match?(%r{(?:\A|/)(?:qemu-system-[^/]+|virtiofsd)\z}) }
end

def artifacts_named?(processes, paths)
  processes.any? do |process|
    paths.any? { |path| process.match?(/#{Regexp.escape(path)}(?=[,\s]|\z)/) }
  end
end

def artifact_open?(path)
  output, error, status = Open3.capture3('lsof', '-nP', '-Fpn', '--', path)
  return true unless output.empty?
  return false if status.exitstatus == 1 && error.empty?

  raise "cannot inspect #{File.basename(path)}: #{error.strip} (lsof #{status.exitstatus})"
end

def artifact_stamp(path)
  stat = File.lstat(path)
  return unless stat.file? && stat.uid == Process.euid

  [stat.dev, stat.ino, stat.size, stat.mtime, stat.ctime]
rescue Errno::ENOENT
  nil
end

def cleanup_artifacts(directory)
  groups = {}
  Dir.children(directory).each do |name|
    match = /\A(?:vagrant-qemu-(vq_[A-Za-z0-9_-]+)-mem|vqemu-(vq_[A-Za-z0-9_-]+)-virtiofs[0-9]+\.sock\.pid)\z/.match(name)
    next unless match

    path = File.join(directory, name)
    stamp = artifact_stamp(path)
    next unless stamp

    (groups[match[1] || match[2]] ||= {})[path] = stamp
  end
  return if groups.empty?

  processes = artifact_processes
  groups.each_value do |files|
    begin
      paths = files.keys.flat_map { |path| [path, path.sub(/\.pid\z/, '')] }
      next if artifacts_named?(processes, paths)
      next if files.keys.any? { |path| artifact_open?(path) }
      next if artifacts_named?(artifact_processes, paths)
      next unless files.all? { |path, stamp| artifact_stamp(path) == stamp }

      files.each_key { |path| File.unlink(path) }
    rescue SystemCallError, RuntimeError => error
      warn "[vm] QEMU artifacts kept: #{error.message}"
    end
  end
rescue SystemCallError, RuntimeError => error
  warn "[vm] QEMU artifacts kept: #{error.message}"
end

directory = ARGV.shift
FileUtils.mkdir_p(directory)
result = 127
File.open(File.join(directory, '.qemu-artifacts.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
  lock.flock(File::LOCK_EX)
  observer = nil
  begin
    cleanup_artifacts(directory)
    identity = ENV['VAGRANT_DOTFILE_PATH']
    if ARGV[1] == 'up' && identity && !identity.empty?
      observer = Thread.new do
        loop do
          sleep 0.2
          processes = artifact_processes
          next unless processes.any? { |process| process.split.first.include?('qemu-system-') && process.include?("#{identity}/") }

          lock.flock(File::LOCK_UN)
          break
        end
      rescue SystemCallError, RuntimeError => error
        warn "[vm] QEMU startup lock kept: #{error.message}"
      end
    elsif ARGV[1] != 'up'
      lock.flock(File::LOCK_UN)
    end
    if system(*ARGV).nil?
      warn "[vm] could not start #{ARGV.first}"
    else
      result = $?.exitstatus || 128 + $?.termsig
    end
  ensure
    if observer
      observer.kill
      observer.join
    end
    lock.flock(File::LOCK_EX)
    cleanup_artifacts(directory)
  end
end
exit result
