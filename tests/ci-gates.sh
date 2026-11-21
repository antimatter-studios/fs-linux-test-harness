#!/usr/bin/env bash
#
# ci-gates.sh — every workflow job takes its runner from a gate job.
#
# A job that may run on our hardware has a gate job, `<job>-gate`, just
# before it, on the `antimatter-vps-gate` runner, whose one step,
# `runner-gate pick <class>`, answers the runner label the job then runs on.
# The gate accepts no other name than `gate` or `<job>-gate`, and no other
# shape. A gate has its job's `needs` and `if`, so it never picks a runner for
# a job that will not run; a job that runs whatever became of the jobs before
# it (`always()`) falls back to GitHub's runner when its gate answered
# nothing. A matrix job has one gate for every leg, so its runs-on names no
# matrix value. A job that only calls a reusable workflow (`uses:`) has no
# runner of its own and no gate.
#
# The class is the job's: a job that boots a VM needs KVM. Our runner's image
# carries less than GitHub's, so a Linux job installs on it what it calls.
# The per-run picker (scripts/pick-ci-runner.sh) and its reservation are gone.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tool ruby 'install ruby / brew install ruby' || { finish ci-gates; exit 1; }

# The checks read the workflows with Ruby's YAML (no aliases, so Ruby 2.6 and
# 3.x read them alike) and print one "ok"/"bad" line each.
# Our runner may have no locale (LANG unset), where Ruby reads files as
# US-ASCII; the test runs under that locale on every host, and reads the
# workflows as UTF-8 whatever the locale.
results="$(LC_ALL=C LANG=C ruby -E UTF-8:UTF-8 -ryaml - "$REPO/.github" <<'RUBY' 2>&1
github = ARGV[0]
GATE_LABEL = "antimatter-vps-gate"
OUTPUT = "${{ steps.pick.outputs.runner }}"
FALLBACK = "ubuntu-latest"
CLASSES = %w[linux-x64 linux-x64-kvm linux-arm64 macos-arm64 windows-x64 windows-arm64]
# The class each job asks for. A job added, renamed or moved to another class
# is added here, on purpose.
EXPECTED = {
  "ci.yml" => { "changes" => "linux-x64", "unit-linux" => "linux-x64", "unit-macos" => "macos-arm64",
                "smoke-x86_64" => "linux-x64-kvm", "ci-ok" => "linux-x64", "release" => "linux-x64" },
  "box-cache.yml" => { "save" => "linux-x64-kvm" },
  "kvm-probe.yml" => { "probe-arm64" => "linux-arm64", "probe-x64" => "linux-x64-kvm",
                       "debian-13-boot" => "linux-x64-kvm", "virtiofs-hotplug" => "linux-x64-kvm" },
  "macos-host.yml" => { "host" => "macos-arm64" },
  "branch-reap.yml" => {},
}
# What a job's own steps call that our runner's image may not carry.
TOOLS = { "ci.yml" => { "unit-linux" => %w[jq ruby shellcheck], "ci-ok" => %w[jq], "release" => %w[gh jq] } }
KVM = /ci-setup-linux\.sh|accel=kvm/

def ok(msg) puts "ok\t#{msg}" end
def bad(msg) puts "bad\t#{msg}" end
def check(cond, msg) cond ? ok(msg) : bad(msg) end
def needs(job) Array(job["needs"]) end
def gate?(job) job["runs-on"] == GATE_LABEL end

lint = File.join(github, "actionlint.yaml")
labels = File.exist?(lint) ? ((YAML.load_file(lint)["self-hosted-runner"] || {})["labels"] || []) : []
check labels.include?(GATE_LABEL), "actionlint.yaml declares the #{GATE_LABEL} label"

files = Dir[File.join(github, "workflows", "*.yml")].map { |f| File.basename(f) }.sort
check files == EXPECTED.keys.sort, "every workflow is listed here (#{files.join(' ')})"

files.each do |wf|
  text = File.read(File.join(github, "workflows", wf))
  jobs = YAML.load(text)["jobs"]
  order = jobs.keys
  expected = EXPECTED[wf] || {}
  check text !~ /pick-ci-runner|runner-gate\.antimatter-studios\.com|linux_runner/, "#{wf}: no old per-run picker remains"

  jobs.each do |id, job|
    if gate?(job)
      check id == "gate" || (id.end_with?("-gate") && jobs.key?(id.sub(/-gate\z/, "")) && !gate?(jobs[id.sub(/-gate\z/, "")])),
            "#{wf}: #{id} is named for the job it gates"
      next
    end
    check !(id == "gate" || id.end_with?("-gate")), "#{wf}: #{id} is not named as a gate"
    if job.key?("uses")
      check !jobs.key?("#{id}-gate"), "#{wf}: #{id} only calls a reusable workflow, and has no gate"
      next
    end
    g = jobs["#{id}-gate"]
    unless g
      bad "#{wf}: #{id} has a #{id}-gate"
      next
    end
    check order.index("#{id}-gate") + 1 == order.index(id), "#{wf}: #{id}-gate sits just before #{id}"
    check (g.keys - %w[needs if runs-on timeout-minutes outputs steps]).empty?, "#{wf}: #{id}-gate has only the keys the gate accepts"
    check g["timeout-minutes"] == 1, "#{wf}: #{id}-gate has one minute"
    check g["outputs"] == { "runner" => OUTPUT }, "#{wf}: #{id}-gate outputs the pick as runner"
    steps = g["steps"] || []
    run = steps.size == 1 && steps[0].keys.sort == %w[id run] && steps[0]["id"] == "pick" ? steps[0]["run"].to_s : ""
    asked = run[/\Arunner-gate pick ([\w-]+)\z/, 1]
    check CLASSES.include?(asked), "#{wf}: #{id}-gate's one step is `runner-gate pick <class>` (#{run.inspect})"
    check asked == expected[id], "#{wf}: #{id}-gate asks for #{expected[id].inspect} (#{asked.inspect})"
    check g.to_s !~ /secrets\.|github\.token|_TOKEN/, "#{wf}: #{id}-gate is handed no secret"
    check needs(g) + ["#{id}-gate"] == needs(job), "#{wf}: #{id} needs what #{id}-gate needs, then #{id}-gate"
    check g["if"] == job["if"], "#{wf}: #{id}-gate runs when #{id} would"
    answer = "needs.#{id}-gate.outputs.runner"
    if job["if"].to_s.include?("always()")
      check job["runs-on"] == "${{ #{answer} || '#{FALLBACK}' }}", "#{wf}: #{id} runs where its gate answered, or on #{FALLBACK}"
    else
      check job["runs-on"] == "${{ #{answer} }}", "#{wf}: #{id} runs where its gate answered"
    end
    check !g.key?("strategy") && job["runs-on"].to_s !~ /matrix/, "#{wf}: #{id} has one gate for every matrix leg" if job.key?("strategy")
    body = (job["steps"] || []).map { |s| s["run"].to_s }.join("\n")
    check asked == "linux-x64-kvm", "#{wf}: #{id} boots a VM, so its gate asks for KVM" if body =~ KVM
    ((TOOLS[wf] || {})[id] || []).each do |tool|
      ours = (job["steps"] || []).select { |s| s["if"].to_s.include?("runner.environment == 'self-hosted'") }
      check ours.any? { |s| s["run"].to_s =~ /apt-get install[^\n]*\b#{tool}\b/ }, "#{wf}: #{id} installs #{tool} on our runner"
    end
  end
  check (expected.keys - jobs.keys).empty?, "#{wf}: every job listed here exists (#{(expected.keys - jobs.keys).join(' ')})"
end

ci = YAML.load_file(File.join(github, "workflows", "ci.yml"))
jobs = ci["jobs"]
judged = jobs.keys.reject { |id| %w[ci-ok ci-ok-gate].include?(id) || needs(jobs[id]).include?("ci-ok") || needs(jobs[id]).include?("ci-ok-gate") }
check (judged - needs(jobs["ci-ok"])).empty?, "ci-ok judges every job before it (#{(judged - needs(jobs['ci-ok'])).join(' ')})"
check jobs["ci-ok"]["if"] == "always()", "ci-ok runs whatever became of the jobs before it"
check File.read(File.join(github, "workflows", "ci.yml")) =~ /^  merge_group:$/, "ci.yml runs for the merge queue"
RUBY
)"
while IFS="$(printf '\t')" read -r verdict what; do
    case "$verdict" in
        ok) ok "$what" ;;
        bad) bad "$what" ;;
        *) bad "ruby: $verdict $what" ;;
    esac
done <<<"$results"

if [ -e "$REPO/scripts/pick-ci-runner.sh" ]; then
    bad 'scripts/pick-ci-runner.sh is gone'
else
    ok 'scripts/pick-ci-runner.sh is gone'
fi

finish ci-gates
