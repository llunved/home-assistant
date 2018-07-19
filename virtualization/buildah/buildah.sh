#! /bin/bash

set -ex

FED_RELEASE=28

newcontainer_name="hass_fedora${FED_RELEASE}_base"
buildcontainer_name="hass_fedora${FED_RELEASE}_build"
hasscontainer_name="hass_fedora${FED_RELEASE}"

INSTALL_OPENALPR="${INSTALL_OPENALPR:-yes}"
INSTALL_LIBCEC="${INSTALL_LIBCEC:-yes}"
INSTALL_PHANTOMJS="${INSTALL_PHANTOMJS:-no}"
INSTALL_SSOCR="${INSTALL_SSOCR:-yes}"

# Required Fedora packages for running hass or components
PACKAGES=(
  # build-essential is required for python pillow module on non-x86_64 arch
    tar bzip2 xz2 rsync make automake gcc gcc-c++ kernel-devel redhat-rpm-config
  # homeassistant.components.image_processing.openalpr_local
    libXrandr-devel
  # homeassistant.components.device_tracker.nmap_tracker
    nmap net-tools libcurl-devel
  # homeassistant.components.device_tracker.bluetooth_tracker
    bluez glib2-devel python3-bluez
  # homeassistant.components.device_tracker.owntracks
    libsodium python3-libnacl
  # homeassistant.components.zwave
    python3-pyudev libgudev-devel
  # homeassistant.components.homekit_controller
    libmpc-devel mpfr-devel gmp-devel
  # homeassistant.components.ffmpeg
    ffmpeg 
  # homeassistant.components.sensor.iperf3
    iperf3
  # pillow dependencies
    libjpeg-turbo zlib libtiff freetype lcms2 libwebp openjpeg2 libimagequant libraqm
  # Not sure why we need this
  #  python3-lxml python3-pillow python3-gmpy2 python3-pycurl
  )

# Required Fedora packages for building dependencies
PACKAGES_DEV=(
  cmake git swig python3-devel
  libffi-devel openssl-devel libxml2-devel
  libjpeg-turbo-devel libtiff-devel zlib-devel openjpeg2-devel freetype-devel lcms2-devel libwebp-devel 
  libimagequant-devel libraqm-devel
  )

if [ "`buildah images | grep ${newcontainer_name}`" == "" ]; then
	exit 1
	echo "Building Fedora container from scratch"
	newcontainer=$(buildah from scratch)

	scratchmnt=$(buildah mount $newcontainer)

	dnf install --installroot $scratchmnt --release ${FED_RELEASE} bash coreutils microdnf --setopt='tsflags=nodocs' --setopt install_weak_deps=false -y
	# Install packages
	dnf install --installroot $scratchmnt --release ${FED_RELEASE} -y https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FED_RELEASE}.noarch.rpm

	#TODO - Copy rmpfusion key to host
	dnf install --installroot $scratchmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' ${PACKAGES[@]} ${PACKAGES_DEV[@]}

	buildah config --author "Daniel Riek <riek@llnvd.io>" --label name=hass_fedora${FED_RELEASE}_base $newcontainer
	buildah unmount $newcontainer
	buildah commit $newcontainer hass_fedora${FED_RELEASE}_base
fi

if [ "`buildah images | grep ${buildcontainer_name}`" == "" ]; then
	buildcontainer=$(buildah from --network=host --name=${buildcontainer_name} localhost/${newcontainer_name})

	buildmnt=$(buildah mount ${buildcontainer})

	dnf upgrade --installroot $buildmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' 

	mkdir -p ${buildmnt}/usr/src/app/

	buildah add ${buildcontainer} virtualization/buildah/ virtualization/buildah/

	# This is a list of scripts that install additional dependencies. If you only
	# need to install a package from the official debian repository, just add it
	# to the list above. Only create a script if you need compiling, manually
	# downloading or a 3rd party repository.
	if [ "$INSTALL_OPENALPR" == "yes" ]; then
		# Sets up openalpr.

		PACKAGES_OPENALPR=(
		  # homeassistant.components.image_processing.openalpr_local
		    opencv-devel opencv-python3 tesseract-devel leptonica-devel log4cplus-devel
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
fi

#install hass component dependencies

hasscontainer=$(buildah from --network=host --name=${hasscontainer_name} localhost/${buildcontainer_name})
hassmnt=$(buildah mount ${hasscontainer})

buildah add ${hasscontainer} requirements_all.txt requirements_all.txt

# Uninstall enum34 because some dependencies install it but breaks Python 3.4+.
# See PR #8103 for more info.

buildah run ${hasscontainer}  pip3 install --no-cache-dir -r requirements_all.txt && \
	    pip3 install --no-cache-dir mysqlclient psycopg2 uvloop cchardet cython

# BEGIN: Development additions

# Install nodejs
#buildah run ${hasscontainer} dnf install -y --setopt='tsflags=nodocs' nodejs
dnf install --installroot $hassmnt --release ${FED_RELEASE}  -y --setopt install_weak_deps=false --setopt='tsflags=nodocs' nodejs

# Install tox
buildah run ${hasscontainer} pip3 install --no-cache-dir tox

# Copy over everything required to run tox
buildah add ${hasscontainer} requirements_test_all.txt setup.cfg setup.py tox.ini ./
buildah add ${hasscontainer} homeassistant/const.py homeassistant/const.py

# Prefetch dependencies for tox
buildah add ${hasscontainer} homeassistant/package_constraints.txt homeassistant/package_constraints.txt
buildah run ${hasscontainer} tox -e py36 --notest

# END: Development additions

# Copy source
buildah add ${hasscontainer} . .

echo FIXME DIRECTORIES ? VOLUMES!!!! CMD [ "python3", "-m", "homeassistant", "--config", "/config" ]

