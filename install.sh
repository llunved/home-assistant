#!/bin/bash


set -x

SERVICE=$IMAGE

env

# Make sure the host is mounted
if [ ! -d /host/etc -o ! -d /host/proc -o ! -d /host/var/run ]; then
	    echo "cockpit-run: host file system is not mounted at /host" >&2
	        exit 1
fi

# Make sure that we have required directories in the host
for CUR_DIR in /host/${LOGDIR}/${NAME} /host/${DATADIR}/${NAME} /host/${DATADIR}/${NAME}/zwave2mqtt /host/${DATADIR}/${NAME}/openzwave  ; do
    if [ -n $CUR_DIR ]; then
        mkdir -p $CUR_DIR
	if [ "$CUR_DIR" == "/host/${DATADIR}/${NAME}/openzwave" ] ; then
	    cp -Rv /etc/openzwave.default /host/${DATADIR}/${NAME}/openzwave
	fi
        chmod -R 775 $CUR_DIR
	chgrp -R 0 $CUR_DIR
    fi
done    


chroot /host /usr/bin/podman create --name ${NAME} -p 8091:8091 --net=host --device /dev/ttyACM0 --entrypoint /sbin/entrypoint.sh -v ${DATADIR}/${NAME}/zwave2mqtt:/zwave2mqtt/store -v ${DATADIR}/${NAME}/openzwave:/etc/openzwave -v ${LOGDIR}/${NAME}:/var/log/zwave2mqtt ${IMAGE} /bin/start.sh
chroot /host sh -c "/usr/bin/podman generate systemd --restart-policy=always -t 1 ${NAME} > /etc/systemd/system/zwave2mqtt.service"

