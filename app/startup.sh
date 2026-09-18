#!/bin/sh
set -e
cd /var/run
exec supervisord -c /etc/supervisor/supervisord.conf