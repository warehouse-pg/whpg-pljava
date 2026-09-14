#!/bin/bash
# Container entrypoint: bring up sshd (gpdemo needs it) and hand over.
set -e

if [ "$(id -u)" = "0" ]; then
    /usr/sbin/sshd
fi

exec "$@"
