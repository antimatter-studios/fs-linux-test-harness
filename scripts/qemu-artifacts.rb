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

# WHAT A BOOT LEAVES RUNNING BELONGS TO THE VM, NOT TO THE CALLER (#130). A macOS
# provider starts `virtiofsd` and `notify-forwarder` from `vagrant up`, and they
# stay in its process group after it ends. A signal to a session goes to its
# command's process group (#117), so a boot in that group lost them under a VM
# that stayed up, and /share and /repo hung in the guest. QEMU daemonizes and was
# never touched. So the boot runs in a process group of its own, which nothing
# signals once the boot is over. `vagrant halt` stops the daemons, as it always did.
#
# While the boot runs it must still stop when its caller does:
#
#   - A signal to this process is passed to the group.
#   - KILL cannot be passed on, so a watcher in the group reads a pipe only this
#     process holds, and kills the group if that pipe closes with no word that the
#     boot ended. It is /bin/sh because no `setsid` can be assumed on a host.
#   - A boot that a signal reached is given no such word, so what it started goes
#     with it, even if that ignored the signal: there is no finished VM to serve.
#
# The boot's stdin is /dev/null: a process outside the terminal's foreground group
# that reads the terminal is stopped, and would wait for ever.
BOOT_WATCHER = <<~'SH'.freeze
  trap '' HUP INT TERM
  read -r _ || kill -KILL 0
SH

def signal_group(signal, group)
  Process.kill(signal, -group)
rescue Errno::ESRCH, Errno::EPERM
  nil
end

def run_boot(argv)
  pending = []
  %w[HUP INT TERM].each { |signal| Signal.trap(signal) { pending << signal } }
  reader, writer = IO.pipe
  group = Process.spawn('/bin/sh', '-c', BOOT_WATCHER, in: reader, out: File::NULL, err: File::NULL, pgroup: true)
  reader.close
  begin
    boot = Process.spawn(*argv, in: File::NULL, pgroup: group)
  rescue SystemCallError
    writer.puts 'ended'
    writer.close
    Process.wait(group)
    warn "[vm] could not start #{argv.first}"
    return 127
  end

  interrupted = false
  status = nil
  loop do
    # Asked first: a signal after the boot has ended has no boot to stop, and
    # passing it on would stop the daemons of the VM that boot just finished.
    _, status = Process.wait2(boot, Process::WNOHANG)
    break if status

    until pending.empty?
      signal_group(pending.shift, group)
      interrupted = true
    end
    sleep 0.05
  end

  writer.puts 'ended' unless interrupted
  writer.close
  Process.wait(group)
  status.exitstatus || 128 + status.termsig
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
    if ARGV[1] == 'up'
      result = run_boot(ARGV)
    elsif system(*ARGV).nil?
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
