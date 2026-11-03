require 'tmpdir'

module ExecCost
  SAMPLES = 10
  # Apple M1 Max, 2026-11-03: 366ms exec versus 522ms forced fresh,
  # ten interleaved calls each; host scheduling also costs time outside SSH.
  BUDGET_MS = RUBY_PLATFORM.include?('darwin') ? 500 : 250
  REUSE_RATIO = 0.8

  def self.reused?(normal_ms, fresh_ms)
    normal_ms < fresh_ms * REUSE_RATIO
  end

  def self.measure(vm, environment)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    unless system(environment, vm, 'exec', 'true', in: File::NULL, out: File::NULL)
      abort 'exec cost: vm.sh exec true failed; timing is not a successful call'
    end
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  end

  def self.run(vm, scratch)
    real_ssh = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |path| File.join(path, 'ssh') }
                  .find { |path| File.file?(path) && File.executable?(path) }
    abort 'exec cost: ssh is required' unless real_ssh

    measure(vm, {})
    Dir.mktmpdir('exec-ssh-', scratch) do |directory|
      wrapper = File.join(directory, 'ssh')
      File.write(wrapper, <<~'SH')
        #!/bin/sh
        if [ "${FLTH_SMOKE_FRESH_SSH:-0}" = 1 ]; then
            case " $* " in *' -N '*) exit 0 ;; esac
            exec "$FLTH_SMOKE_REAL_SSH" -o ControlPath=none -o ControlMaster=no "$@"
        fi
        exec "$FLTH_SMOKE_REAL_SSH" "$@"
      SH
      File.chmod(0o755, wrapper)
      environment = {
        'PATH' => "#{directory}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}",
        'FLTH_SMOKE_REAL_SSH' => real_ssh,
        'FLTH_SMOKE_FRESH_SSH' => '0'
      }
      normal = []
      fresh = []
      SAMPLES.times do |sample|
        modes = sample.even? ? ['0', '1'] : ['1', '0']
        modes.each do |mode|
          elapsed = measure(vm, environment.merge('FLTH_SMOKE_FRESH_SSH' => mode))
          (mode == '0' ? normal : fresh) << elapsed
        end
      end
      normal_ms = normal.sum / SAMPLES
      fresh_ms = fresh.sum / SAMPLES
      puts format('  (exec: %.1fms per call; forced fresh SSH: %.1fms; %d calls each, interleaved)',
                  normal_ms, fresh_ms, SAMPLES)
      $stdout.flush
      within_budget = normal_ms < BUDGET_MS
      reused = reused?(normal_ms, fresh_ms)
      warn "exec cost: exceeds the #{BUDGET_MS}ms per-call budget" unless within_budget
      unless reused
        warn 'exec cost: not at least 20% faster than measured calls without SSH reuse'
      end
      within_budget && reused
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'usage: exec-cost.rb <vm.sh> <scratch directory>' unless ARGV.length == 2
  exit(ExecCost.run(*ARGV) ? 0 : 1)
end
