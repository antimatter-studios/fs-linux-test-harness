# shellcheck shell=bash
#
# lib/engine.sh — the seam between the harness and the thing that runs
# the VM.
#
# Everything the harness decides — the hold, the reaper, the list of
# suites, the setup stamp, stop confirmation — is written against the functions
# below and nothing else. Vagrant is the only engine today; replacing it
# means writing one file that defines these, and changing the line at
# the bottom.
#
#   engine_prepare             export whatever the engine reads; call
#                              after flth_load, before anything else
#   engine_identity            print a path unique to this machine. A
#                              running VM's process names it on its
#                              command line.
#   engine_boot_identity       print the running VM process's PID and start
#                              time, stable across callers' locales and
#                              timezones. Exit 1 when absent, 2 when the
#                              process table could not be read.
#   engine_state               print exactly one of:
#                                running   the VM is up
#                                stopped   it exists and is not running
#                                absent    it does not exist
#                                unknown   the state could NOT be read
#                              `unknown` is never treated as stopped:
#                              a guest taken for stopped on an unread
#                              state is how two VMs end up running at once.
#   engine_up [--persist]      boot (creating if needed); non-zero on
#                              failure. Engine chatter goes to stderr.
#                              The boot is DISPOSABLE: everything it
#                              writes to the machine's disk is thrown
#                              away when it stops, however it stops.
#                              With --persist the writes are kept; that
#                              is for applying the setup script only.
#                              A consumer that declares a cache
#                              ([cache] size) has it at
#                              FLTH_CACHE_GUEST on EVERY boot, and what
#                              is written there is kept either way.
#   engine_box_failure         after a failed engine_up: exit 0 and print
#                              where the box comes from and what it
#                              answered, when no VM started because the
#                              box could not be fetched and a later try
#                              may succeed. Non-zero, and nothing, for
#                              any other failure.
#   engine_console_log        print the path of the file holding the
#                              console of the latest boot, failed or
#                              not. It may be missing or empty: a boot
#                              that never started a VM wrote nothing.
#   engine_down [--force]      ask the VM to stop. Its exit status is
#                              NOT trusted; callers confirm with
#                              engine_state.
#   engine_destroy             delete the VM, its disk and its cache
#   engine_stop_host_daemons   stop what a boot left running on the host
#                              beside a VM that has already gone
#   engine_keep_kernel         on a provisioning boot, before it stops:
#                              make the next boot run the newest kernel
#                              on the disk, on a host whose guest does
#                              not choose its own. Non-zero when it
#                              could not. Elsewhere it does nothing.
#   engine_kernel_known        exit 0 when a provisioning boot has done
#                              that for this disk, or none needs to
#   engine_forget_kernel       drop what engine_keep_kernel kept, when
#                              the disk it came from is gone
#   engine_attach_tree <run> <dir>
#                              attach a host directory to the running guest
#                              as the run's device, tagged with the run id,
#                              served by a virtiofsd of its own (#222)
#   engine_tree_attached <run> 0 attached, 1 not, 3 attached with its
#                              virtiofsd gone
#   engine_tree_slot <run>     the slot its device is on
#   engine_detach_tree <run>   remove the device, then stop its daemon; the
#                              guest has let go of the mount already
#   engine_attached_runs       the runs with a device, one a line
#   engine_run <script>        run a bash script as root in the guest;
#                              exit with the script's status. stdout is
#                              the script's stdout.
#   engine_run_held <script>   the same for a script that ends itself with
#                              `exit`. After the script, its stdin stays open
#                              until the caller or the connection has gone,
#                              however it went, and then reads end-of-file.
#   engine_copy <host-file>    make a host file visible to the guest;
#                              print its guest path
#   engine_alive <identity>    exit 0 when a VM process for that identity
#                              is running, 1 when none is, 2 when the
#                              process table could not be read. A
#                              process check with no engine call: the
#                              reaper runs it on every chore invocation.
#   engine_vm_status           what the VM's process says about the guest,
#                              within a limit: `VM status: <status>`, then
#                              `I/O status: <status>` when a disk's is not
#                              ok, then `overlay: <size>` when it is known.
#                              Non-zero, and nothing, when it does not answer.
#   engine_guest_answers       exit 0 when the guest answers a new connection
#                              within a limit
#   engine_guest_report        what vagrant/guest/watchdog-probe.sh says in the
#                              guest, within a limit. Non-zero when the guest
#                              did not answer in time.
#   engine_overlay_dir         print the directory holding a disposable
#                              boot's overlay

# shellcheck source=scripts/lib/engine-vagrant.sh
. "$FLTH_HARNESS/scripts/lib/engine-vagrant.sh"
