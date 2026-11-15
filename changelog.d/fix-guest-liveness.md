### Fixed

- A `vm.sh run` or `exec` outside any session, running when the watchdog ends the guest, fails with the watchdog's status 75 and names the reason, instead of exiting 143 with no reason when the watchdog's TERM reached it first (#190).
