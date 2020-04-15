#!/bin/bash

set -x #-e

# Chown a list of directories we always do GID 0
if [ -n "$CHOWN" ]; then
   for CUR_DIR in $CHOWN_DIRS
       do
          chown -vR $USER:0 $CUR_DIR
	  chmod -vR 775 $CUR_DIR
       done
fi  

# If a user was set exec as user
if [ "$USER" != "0" ]; then
    # Do we have gosu? Otherwise fall back to chroot
    if hash gosu 2>/dev/null; then
       exec gosu ${USER}:0 "$@"
    else
       exec chroot --userspec=${USER}:0 / "$@"
    fi
fi

# If user is 0 we want to be root
exec "$@"
