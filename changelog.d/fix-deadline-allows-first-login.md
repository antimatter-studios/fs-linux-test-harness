### Fixed

- A `[vm] deadline_minutes` of five or less no longer refuses the harness's first login after a boot, and a longer one no longer refuses a new connection in its last five minutes. The guest's sshd stops consulting `pam_nologin`, and the guest still powers off on schedule.
- The setup call re-arms the guest's poweroff as it starts and as it ends, as `run` and `exec` do.
