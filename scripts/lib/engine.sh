# shellcheck shell=bash
#
# lib/engine.sh — the seam between the harness and the thing that runs
# the VM.
#
# Everything the harness decides — the slot, the hold, the reaper, the
# setup stamp, teardown confirmation — is written against the functions
# below and nothing else. Vagrant is the only engine today; replacing it
# means writing one file that defines these, and changing the line at
# the bottom.
#
#   engine_prepare             export whatever the engine reads; call
#                              after flth_load, before anything else
#   engine_identity            print a path unique to this machine. The
#                              slot records it, and a running VM's
#                              process names it on its command line.
#   engine_state               print exactly one of:
#                                running   the VM is up
#                                stopped   it exists and is not running
#                                absent    it does not exist
#                                unknown   the state could NOT be read
#                              `unknown` is never treated as stopped:
#                              a slot released on an unread state is how
#                              two VMs end up running at once.
#   engine_up                  boot (creating if needed); non-zero on
#                              failure. Engine chatter goes to stderr.
#   engine_down [--force]      ask the VM to stop. Its exit status is
#                              NOT trusted; callers confirm with
#                              engine_state.
#   engine_destroy             delete the VM and its disk
#   engine_run <script>        run a bash script as root in the guest;
#                              exit with the script's status. stdout is
#                              the script's stdout.
#   engine_copy <host-file>    make a host file visible to the guest;
#                              print its guest path
#   engine_alive <identity>    exit 0 when a VM process for that identity
#                              is running, 1 when none is, 2 when the
#                              process table could not be read. A
#                              process check with no engine call: the
#                              reaper runs it on every chore invocation.

# shellcheck source=engine-vagrant.sh
. "$FLTH_HARNESS/scripts/lib/engine-vagrant.sh"
