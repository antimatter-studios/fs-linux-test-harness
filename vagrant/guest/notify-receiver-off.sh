#!/bin/sh
#
# notify-receiver-off.sh -- what a macOS guest runs in place of the forwarder
# plugin's receiver (vagrant/Vagrantfile says why). The plugin installs it in the
# guest and starts it with `receive -p <port>`, and from 0.7.7 with the shares'
# guest paths after that, as a service. It reads no arguments and touches nothing:
# all it has to do is exit.
exit 0
