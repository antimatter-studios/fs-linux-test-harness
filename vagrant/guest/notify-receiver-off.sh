#!/bin/sh
#
# notify-receiver-off.sh -- what a macOS guest runs in place of the forwarder
# plugin's receiver (vagrant/Vagrantfile says why). The plugin uploads it to
# /tmp/notify-forwarder and starts it with `receive -p <port>`. It takes no
# arguments and touches nothing: all it has to do is exit.
exit 0
