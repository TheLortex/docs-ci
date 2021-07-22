#!/bin/bash
set -e

ALLOW=${ALLOW:-192.168.0.0/16 172.16.0.0/12 127.0.0.1/32}
VOLUME=${VOLUME:-/data}


setup_sshd(){
	if [ -e "/root/.ssh/authorized_keys" ]; then
        chmod 400 /root/.ssh/authorized_keys
        chown root:root /root/.ssh/authorized_keys
    else
		mkdir -p /root/.ssh
		chown root:root /root/.ssh
    fi
    chmod 750 /root/.ssh
}

setup_rsyncd(){
	touch /etc/rsyncd.secrets
	rm -f /var/run/rsyncd.pid
    chmod 0400 /etc/rsyncd.secrets
	[ -f /etc/rsyncd.conf ] || cat > /etc/rsyncd.conf <<EOF
pid file = /var/run/rsyncd.pid
log file = /dev/stdout
timeout = 300
max connections = 10
port = 873
[volume]
	uid = root
	gid = root
	hosts deny = *
	hosts allow = ${ALLOW}
	read only = false
	path = ${VOLUME}
	comment = ${VOLUME} directory
	auth users = ${USERNAME}
	secrets file = /etc/rsyncd.secrets
EOF
}


if [ "$1" = 'rsync_server' ]; then
    setup_sshd
    exec /usr/sbin/sshd &
    mkdir -p $VOLUME
    setup_rsyncd
    exec /usr/bin/rsync --no-detach --daemon --config /etc/rsyncd.conf "$@"
else
	setup_sshd
	exec /usr/sbin/sshd &
fi

exec "$@"
