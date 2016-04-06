#!/usr/bin/env bash

BASE_OS=Fedora
NAME="CloudRouter"
VERSION="3.0"
ARCH=x86_64
TIMESTAMP=$(python -c 'import time; stamp="{:0.6f}".format(time.time()); print stamp.rstrip("0")')
ISOFILE=${NAME}-${VERSION}-${BASE_OS}.iso
ISONAME="${NAME} ${VERSION} ${BASE_OS}"

DVD_ISO_URL=http://fedora.uberglobalmirror.com/fedora/linux/releases/23/Server/x86_64/iso/Fedora-Server-DVD-x86_64-23.iso

KICKSTART_FILE=cloudrouter-ks.cfg
ISOLINUX_CFG_FILE=isolinux.cfg

BASE_DIR=$(pwd)
WORKING_DIR=${BASE_DIR}/working
ISO_MOUNT_DIR=${BASE_DIR}/iso_mount
ISO_SOURCE_DIR=${BASE_DIR}/iso_sources
PACKAGES_TEMP=${BASE_DIR}/packages_temp
WORKING_PACKAGES=${WORKING_DIR}/Packages
RPMDB=/tmp/testrpmdb
RPM_GPG_KEYS_DIR=/etc/pki/rpm-gpg

ISO_BUILD_DEPS=( wget createrepo isomd5sum genisoimage dnf-plugins-core rsync python )
HIDDEN_RPM_DEPS=( authconfig chrony firewalld grub2 )

SOURCE_ISO_FILE=${BASE_DIR}/$(basename ${DVD_ISO_URL})
COMPS_XML=${WORKING_PACKAGES}/comps.xml

# Install packages required to build a DVD ISO iamge
dnf updateinfo
dnf install -y "${ISO_BUILD_DEPS[@]}"  

# Download the official DVD ISO image
#wget "${DVD_ISO_URL}"

function clean_mkdir {
  dir_path=$1
  if [ -z ${dir_path} ]
  then
      rm -fR ${dir_path}
  fi
  mkdir -p "${dir_path}"
}

clean_mkdir "${ISO_MOUNT_DIR}"
clean_mkdir "${ISO_SOURCE_DIR}"
clean_mkdir "${PACKAGES_TEMP}"
clean_mkdir "${RPMDB}"
clean_mkdir "${WORKING_PACKAGES}"

# Mount the downloaded ISO and make a copy of its sources.
mount -o loop,ro "${SOURCE_ISO_FILE}" "${ISO_MOUNT_DIR}"
rsync -av "${ISO_MOUNT_DIR}/" "${ISO_SOURCE_DIR}/"
umount "${ISO_MOUNT_DIR}"
rm -fR "${ISO_MOUNT_DIR}"

# Create a Respin DVD ISO working directory
find "${ISO_SOURCE_DIR}/" -type d \
    -not -path "*Packages*" \
    -not -path "*repodata*" \
    -not -name "$(basename ${ISO_SOURCE_DIR})" | \
  sed -n "s|^${ISO_SOURCE_DIR}/||p" | \
  xargs -I {} mkdir -p "${WORKING_DIR}/{}"
find "${ISO_SOURCE_DIR}/" -type f \
    -not -path "*Packages*" \
    -not -path "*repodata*" \
    -not -name ".discinfo" \
    -not -name ".treeinfo" \
    -not -name "TRANS.TBL" | \
  sed -n "s|^"${ISO_SOURCE_DIR}"/||p" | \
  xargs -I {} cp "${ISO_SOURCE_DIR}/{}" "${WORKING_DIR}/{}"

# Add custom kickstart file to the DVD ISO working directory
cp -f "${KICKSTART_FILE}" "${WORKING_DIR}/"
cp -f "${ISOLINUX_CFG_FILE}" "${WORKING_DIR}/isolinux"

# Create a working folder for the packages
# Initially populate the RPM package set with all the RPMs from the DVD ISO source image
find "${ISO_SOURCE_DIR}/Packages/" -type f -name "*.rpm" | \
  xargs -I {} cp "{}" "${PACKAGES_TEMP}/"

# Retrieves all the package dependencies specified in the kickstart install file.
awk '/%packages/,/%end/ {if (!/^[-@%]/) print}' "${WORKING_DIR}/${KICKSTART_FILE}" | \
  xargs -n 1 -I {} dnf download --exclude="*.i386,*.i686" --destdir "${PACKAGES_TEMP}/" --resolve "{}"

# Download extra dependencies that are required but that don't show up in dependency resolution.
dnf download --exclude="*.i386,*.i686" --destdir "${PACKAGES_TEMP}/" --resolve "${HIDDEN_RPM_DEPS[@]}"

# Create an RPM Database for resolving RPM package dependencies.
rpm --initdb --dbpath ${RPMDB}
rpm --import --dbpath ${RPMDB} ${RPM_GPG_KEYS_DIR}/*

OLD_PKG_COUNT=0
PKG_COUNT=$(ls ${PACKAGES_TEMP} | wc -l)
# debugging - echo "initial: OLD_PKG_COUNT=${OLD_PKG_COUNT} PKG_COUNT=${PKG_COUNT}"

while [ ${OLD_PKG_COUNT} -ne ${PKG_COUNT} ]; do
  OLD_PKG_COUNT=${PKG_COUNT}
  rpm --test --dbpath ${RPMDB} -ivh "${PACKAGES_TEMP}/*.rpm" 2>&1 \
    | grep -Eiv '(conflicts|error\:)' \
    | awk '/^(.+) is needed by/ {print $1}' | sort -u \
    | xargs -I {} dnf --exclude="*.i386,*.i686" provides "{}" \
    | grep -Evi "^(Last metadata expiration|Repo|Provides|Loaded|Loading|Matched|Filename)" \
    | cut -d ' ' -f1 | sed '/^$/d' | sort -u \
    | xargs -I {} dnf download --exclude="*.i386,*.i686" --destdir "${PACKAGES_TEMP}" {}

  PKG_COUNT=$(ls ${PACKAGES_TEMP} | wc -l)
  # debugging - echo "loop: OLD_PKG_COUNT=${OLD_PKG_COUNT} PKG_COUNT=${PKG_COUNT}"
done

# debugging - echo "loop terminated: package set built!"

# Create a new RPM Repository
SUBDIRS=( $(find "${PACKAGES_TEMP}/" -type f -name "*.rpm" | xargs -L1 basename \
  | cut -c1 | tr '[:upper:]' '[:lower:]' | sort | uniq) )

for letter in ${SUBDIRS[@]}; do
    mkdir -p "${WORKING_PACKAGES}/${letter}"
done

PACKAGES=( $(find "${PACKAGES_TEMP}/" -type f -name "*.rpm") )
for pkg in ${PACKAGES[@]}; do
    filename=$(basename "${pkg}")
    subdir=$(echo ${filename} | cut -c1 | tr '[:upper:]' '[:lower:]')
    cp "${pkg}" "${WORKING_PACKAGES}/${subdir}/${filename}"
done

find "${ISO_SOURCE_DIR}/" -type f -name "*comps.xml" \
  -exec cp "{}" "${COMPS_XML}" \;
pushd "${WORKING_PACKAGES}"
createrepo -g $(basename "${COMPS_XML}") --compress-type xz -o "${WORKING_DIR}" .
popd
rm -f "${COMPS_XML}"

# Create a new .discinfo file
cat << EOF >> "${WORKING_DIR}/.discinfo"
${TIMESTAMP}
${NAME} ${VERSION}
${ARCH}
EOF

# Create a new .treeinfo file
# Outstanding issue on boot.iso in .treeinfo, but not
# actually included in the DVD ISO.
# https://bugzilla.redhat.com/show_bug.cgi?id=691308
cat << EOF >> "${WORKING_DIR}/.treeinfo"
[general]
version = ${VERSION}
arch = ${ARCH}
family = Fedora
packagedir =
name = ${NAME}-${VERSION}
timestamp = ${TIMESTAMP}
variant = Server

[images-${ARCH}]
initrd = images/pxeboot/initrd.img
boot.iso = images/boot.iso
kernel = images/pxeboot/vmlinuz

[stage2]
mainimage = images/install.img

[images-xen]
initrd = images/pxeboot/initrd.img
kernel = images/pxeboot/vmlinuz

[checksums]
images/install.img = sha256:$(sha256sum "${WORKING_DIR}/images/install.img" | cut -d ' ' -f 1)
images/efiboot.img = sha256:$(sha256sum "${WORKING_DIR}/images/efiboot.img" | cut -d ' ' -f 1)
images/macboot.img = sha256:$(sha256sum "${WORKING_DIR}/images/macboot.img" | cut -d ' ' -f 1)
images/product.img = sha256:$(sha256sum "${WORKING_DIR}/images/product.img" | cut -d ' ' -f 1)
images/boot.iso = $(awk '/boot.iso/ && /sha256/ {print;}' ${ISO_SOURCE_DIR}/.treeinfo | cut -d' ' -f3)
images/pxeboot/vmlinuz = sha256:$(sha256sum "${WORKING_DIR}/images/pxeboot/vmlinuz" | cut -d ' ' -f 1)
images/pxeboot/initrd.img = sha256:$(sha256sum "${WORKING_DIR}/images/pxeboot/initrd.img" | cut -d ' ' -f 1)
repodata/repomd.xml = sha256:$(sha256sum "${WORKING_DIR}/repodata/repomd.xml" | cut -d ' ' -f 1)
EOF

# Clean up any TRANS.TBL files that were copied over into the working directory
find "${WORKING_DIR}" -type f -name "TRANS.TBL" -exec rm -f "{}" \;

# Generate the final DVD ISO Image
mkisofs -r -R -J -T -v \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -V "${ISONAME}" \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -o "${ISOFILE}" \
  "${WORKING_DIR}"

implantisomd5 "${ISOFILE}"