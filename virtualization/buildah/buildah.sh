#! /bin/bash

set -e -x

FED_RELEASE=31

newcontainer_name="hass_fedora${FED_RELEASE}_base"
buildcontainer_name="hass_fedora${FED_RELEASE}_build"
build2container_name="hass_fedora${FED_RELEASE}_build2"
hasscontainer_name="hass_fedora${FED_RELEASE}"

INSTALL_OPENALPR="${INSTALL_OPENALPR:-no}" #yes
INSTALL_LIBCEC="${INSTALL_LIBCEC:-no}" #yes
INSTALL_PHANTOMJS="${INSTALL_PHANTOMJS:-no}"
INSTALL_SSOCR="${INSTALL_SSOCR:-no}" #yes

# Required Fedora packages for running hass or components
PACKAGES=(
  # build-essential is required for python pillow module on non-x86_64 arch
    tar bzip2 xz rsync make automake gcc gcc-c++ kernel-devel redhat-rpm-config nano
  # homeassistant.components.image_processing.openalpr_local
    libXrandr-devel
  # device_tracker - ping
    iputils
  # homeassistant.components.device_tracker.nmap_tracker
    nmap net-tools libcurl-devel
  # homeassistant.components.device_tracker.bluetooth_tracker
    bluez glib2-devel python3-bluez
  # homeassistant.components.device_tracker.owntracks
    libsodium python3-libnacl
  # homeassistant.components.zwave
    libgudev-devel systemd-devel doxygen openzwave libopenzwave libopenzwave-devel
  # homeassistant.components.homekit_controller
    libmpc-devel mpfr-devel gmp-devel
  # homeassistant.components.ffmpeg
    ffmpeg mariadb postgresql
  # homeassistant.components.sensor.iperf3
    iperf3
  # pillow dependencies
    libjpeg-turbo zlib libtiff freetype lcms2 libwebp openjpeg2 libimagequant libraqm
  # DTLSSocket dependencies
    libxml2 libxslt
  # Not sure why we need this
  #  python3-lxml python3-pillow python3-gmpy2 python3-pycurl python3-pyudev
  )

# Required Fedora packages for building dependencies
PACKAGES_DEV=(
  cmake git swig python3-devel
  libffi-devel openssl-devel libxml2-devel libxslt-devel
  libjpeg-turbo-devel libtiff-devel zlib-devel openjpeg2-devel freetype-devel lcms2-devel libwebp-devel 
  libimagequant-devel libraqm-devel mariadb-devel postgresql-devel python3-Cython
  )

if [ "`buildah images | grep ${newcontainer_name}`" == "" ]; then
	echo "Building Fedora container from scratch"
	newcontainer=$(buildah from scratch)

	scratchmnt=$(buildah mount $newcontainer)

	dnf install --installroot $scratchmnt --release ${FED_RELEASE} --setopt='tsflags=nodocs' --setopt install_weak_deps=false -y bash coreutils microdnf 

	# Install Freshrpms
	dnf install --installroot $scratchmnt --release ${FED_RELEASE} -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FED_RELEASE}.noarch.rpm

	#Copy rmpfusion key to host
	cp ${scratchmnt}/etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-* /etc/pki/rpm-gpg/

	# Install packages	
	dnf install --installroot $scratchmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' ${PACKAGES[@]}
	dnf install --installroot $scratchmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' ${PACKAGES_DEV[@]}

	dnf --installroot $scratchmnt --release ${FED_RELEASE} -y clean all 

	buildah config --author "Daniel Riek <riek@llnvd.io>" --label name=hass_fedora${FED_RELEASE}_base $newcontainer
	buildah unmount $newcontainer
	buildah commit $newcontainer hass_fedora${FED_RELEASE}_base
	buildah rm $newcontainer
fi


if [ "`buildah images | grep ${buildcontainer_name}`" == "" ]; then
	buildcontainer=$(buildah from --network=host --name=${buildcontainer_name} localhost/${newcontainer_name})

	buildmnt=$(buildah mount ${buildcontainer})

	dnf upgrade --installroot $buildmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' 

	mkdir -p ${buildmnt}/usr/src/app/

	buildah add ${buildcontainer} virtualization/buildah/ virtualization/buildah/

	# This is a list of scripts that install additional dependencies. If you only
	# need to install a package from the official fedora repository, just add it
	# to the list above. Only create a script if you need compiling, manually
	# downloading or a 3rd party repository.
	if [ "$INSTALL_OPENALPR" == "yes" ]; then
		# Sets up openalpr.

		PACKAGES_OPENALPR=(
		  # homeassistant.components.image_processing.openalpr_local
		    opencv-devel tesseract-devel leptonica-devel log4cplus-devel
		    )

		dnf install --installroot $buildmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' ${PACKAGES_OPENALPR[@]}

		buildah run ${buildcontainer} virtualization/buildah/scripts/openalpr
	fi

	if [ "$INSTALL_LIBCEC" == "yes" ]; then
		dnf install --installroot $buildmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' libcec python3-libcec
	fi

	if [ "$INSTALL_PHANTOMJS" == "yes" ]; then
		buildah run ${buildcontainer} virtualization/buildah/scripts/phantomjs
	fi

	if [ "$INSTALL_SSOCR" == "yes" ]; then

		dnf install --installroot $buildmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' imlib2 imlib2-devel

		buildah run ${buildcontainer} virtualization/buildah/scripts/ssocr
	fi

	# Remove packages and clean up

	#dnf remove --installroot $buildmnt --release ${FED_RELEASE} -y ${PACKAGES_DEV[@]} 
	#dnf --installroot $buildmnt --release ${FED_RELEASE} -y autoremove
	dnf --installroot $buildmnt --release ${FED_RELEASE} -y clean all 
	#buildah run ${buildcontainer} rm -rf /var/lib/dnf/transaction* /tmp/* /var/tmp/* /usr/src/app/build/
	

	buildah unmount $buildcontainer
	buildah commit $buildcontainer ${buildcontainer_name}
	buildah rm $buildcontainer
fi


hasscontainer=$(buildah from --network=host --name=${hasscontainer_name} localhost/${buildcontainer_name})
hassmnt=$(buildah mount ${hasscontainer})

dnf upgrade --installroot $hassmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' 

# Install nodejs
dnf install --installroot $hassmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' nodejs

# Install virtualenv
dnf install --installroot $hassmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' python3-virtualenv

buildah run ${hasscontainer} groupadd -r homeassistant -g 989 
buildah run ${hasscontainer} useradd -u 989 -r -g homeassistant -G dialout -d /var/lib/homeassistant -s /sbin/nologin -c "Homeassistant User" homeassistant

buildah run ${hasscontainer} mkdir -p /etc/homeassistant
buildah run ${hasscontainer} chown -R homeassistant:homeassistant /etc/homeassistant
buildah run ${hasscontainer} mkdir -p /var/lib/homeassistant
buildah run ${hasscontainer} chown -R homeassistant:homeassistant /var/lib/homeassistant
buildah run ${hasscontainer} mkdir -p /srv/homeassistant
buildah run ${hasscontainer} chown -R homeassistant:homeassistant /srv/homeassistant

buildah config --workingdir /srv/homeassistant ${hasscontainer} 

buildah config --port 8143 ${hasscontainer}
buildah config --cmd "/bin/bash -c \"source bin/activate && /srv/homeassistant/bin/python3 -m homeassistant --config /etc/homeassistant --log-file /var/lib/homeassistant/home-assistant.log\"" ${hasscontainer} 

buildah config --volume /etc/homeassistant:/etc/homeassistant ${hasscontainer} 
buildah config --volume /var/lib/homeassistant:/var/lib/homeassistant ${hasscontainer}

buildah config --user homeassistant:homeassistant ${hasscontainer} 

buildah run ${hasscontainer} /usr/bin/virtualenv -p /usr/bin/python3 --system-site-packages /srv/homeassistant

#install hass component dependencies
buildah add ${hasscontainer} requirements_all.txt /srv/homeassistant/requirements_all.txt

# Uninstall enum34 because some dependencies install it but breaks Python 3.4+.
# See PR #8103 for more info.

# Make sure openzwave uses system libraries
# Create symlinks for https://github.com/OpenZWave/open-zwave/pull/1448
# TODO shouldn't pkconfig sort this?
# Only needed pre F31?
#buildah run --user 0:0 ${hasscontainer} find /usr/include/openzwave/ -mindepth 1 -name \*.h -exec ln -sv {} /usr/include/openzwave/ \;

#buildah run ${hasscontainer}  /bin/bash -c "source bin/activate && pip3 install --no-cache-dir python_openzwave --no-deps  --install-option='--flavor=shared'"
# TODO figure out how to put the shared option into the requirements

# Install requirements
buildah run ${hasscontainer}  /bin/bash -c "source bin/activate && pip3 install --no-cache-dir -r requirements_all.txt"
buildah run ${hasscontainer}  /bin/bash -c "source bin/activate && pip3 install --no-cache-dir mysqlclient psycopg2 uvloop cchardet"

## BEGIN: Development additions
#
## Install tox
#buildah run ${hasscontainer} pip3 install --no-cache-dir tox
#
## Copy over everything required to run tox
#buildah add ${hasscontainer} requirements_test_all.txt setup.cfg setup.py tox.ini ./
#buildah add ${hasscontainer} homeassistant/const.py homeassistant/const.py
#
## Prefetch dependencies for tox
#buildah add ${hasscontainer} homeassistant/package_constraints.txt homeassistant/package_constraints.txt
#buildah run ${hasscontainer} tox -e py36 --notest
#
# END: Development additions
# Copy source
buildah add --chown homeassistant:homeassistant ${hasscontainer} . /srv/homeassistant

# TODO RUN HASS WITH DEFAULT CONFIG
#buildah run ${hasscontainer} 

buildah unmount ${hasscontainer}
buildah commit ${hasscontainer} ${hasscontainer_name}
buildah rm ${hasscontainer}

