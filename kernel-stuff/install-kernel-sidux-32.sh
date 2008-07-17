#!/bin/bash

# install-kernel-sidux.sh - installer for archived 32 bit sidux kernels
# Script is based on kelmo and slh's kernel installer from the
# old sidux kernel installer zips. Copyright belongs to them
# license: GPL 2
# NOTE: relevant paths and kernel names are upgraded automatically for each new archive
# zip file created, this is only the working template.
# Changes and modifications are by Harald Hope, and neither slh nor kelmo should be blamed
# for any mistakes I make.

VER="2.6.24-2.6.24.3.slh.11-sidux-686"

if [ "$(id -u)" -ne 0 ]; then
	[ -x "$(which su-to-root)" ] && exec su-to-root -c "$0"
	printf "ERROR: $0 needs root capabilities, please start it as root.\n\n" >&2
	exit 1
fi

if [ -e "/boot/vmlinuz-${VER}" ]; then
	echo "ERROR: /boot/vmlinuz-${VER} already exist, terminate abnormally" >&2
	exit 2
fi

# ensure /etc/kernel-img.conf is configured with correct settings
# - fix path to update-grub
# - make sure "do_initrd = Yes"
if [ -w /etc/kernel-img.conf ]; then
	echo -n "Checking /etc/kernel-img.conf..."

	sed -i	-e "s/\(postinst_hook\).*/\1\ \=\ \\/usr\\/sbin\\/update-grub/" \
		-e "s/\(postrm_hook\).*/\1\ \=\ \\/usr\\/sbin\\/update-grub/" \
		-e "s/\(do_initrd\).*/\1\ \=\ Yes/" \
		-e "/ramdisk.*mkinitrd\\.yaird/d" \
			/etc/kernel-img.conf
	
	if ! grep -q do_initrd /etc/kernel-img.conf; then
		echo "do_initrd = Yes" >> /etc/kernel-img.conf
	fi

	echo "done."
else
	echo "WARNING: /etc/kernel-img.conf is missing, creating file with defaults..."
	cat > /etc/kernel-img.conf <<EOF
do_bootloader = No
postinst_hook = /usr/sbin/update-grub
postrm_hook   = /usr/sbin/update-grub
do_initrd     = Yes
EOF
fi

# install important dependencies before attempting to install kernel
INSTALL_DEP=
[ -x /usr/bin/gcc-4.2 ]           || INSTALL_DEP="$INSTALL_DEP gcc-4.2"
[ -x /usr/sbin/update-initramfs ] || INSTALL_DEP="$INSTALL_DEP initramfs-tools"

# take care to install b43-fwcutter, if bcm43xx-fwcutter is already installed
if dpkg -l bcm43xx-fwcutter 2>/dev/null | grep -q '^[hi]i' || [ -e /lib/firmware/bcm43xx_pcm4.fw ]; then
	dpkg -l b43-fwcutter 2>/dev/null | grep -q '^[hi]i' || INSTALL_DEP="$INSTALL_DEP b43-fwcutter"
fi

# make sure udev-config-sidux is up to date
# - do not blacklist b43, we need it for kernel >= 2.6.23
# - make sure to install the IEEE1394 vs. FireWire "Juju" blacklist
if [ -r /etc/modprobe.d/sidux ] || [ -r /etc/modprobe.d/ieee1394 ] || [ -r /etc/modprobe.d/mac80211 ]; then
	VERSION=$(dpkg -l udev-config-sidux 2>/dev/null | awk '/^[hi]i/{print $3}')
	dpkg --compare-versions ${VERSION:-0} lt 0.4.3
	if [ "$?" -eq 0 ]; then
		INSTALL_DEP="$INSTALL_DEP udev-config-sidux"
	fi
else
	INSTALL_DEP="$INSTALL_DEP udev-config-sidux"
fi

# check resume partition configuration is valid
if [ -x /usr/sbin/get-resume-partition ]; then
	VERSION=$(dpkg -l sidux-scripts 2>/dev/null | awk '/^[hi]i/{print $3}')
	dpkg --compare-versions ${VERSION:-0} ge 0.1.38
	if [ "$?" -eq 0 ]; then
		get-resume-partition
	fi
fi

# install kernel, headers, documentation and any extras that were detected
if [ -n "$INSTALL_DEP" ]; then
	apt-get update
	apt-get --assume-yes install $INSTALL_DEP
fi

# add linux-image and linux-headers to the install lists
# the order here is critical, common is a dependency
LIMAGE=$( ls linux-image-${VER}*.deb 2> /dev/null )
LHEADERS_COMMON=$( ls linux-headers-*-common*.deb 2> /dev/null )
LHEADERS_SIDUX=$( ls linux-headers-*-sidux*.deb 2> /dev/null )
LHEADERS_ALL_ARCH=$( ls linux-headers-*-all-*.deb 2> /dev/null )
LHEADERS_ALL=$( ls linux-headers-*-all_*.deb 2> /dev/null )
LKBUILD=$( ls linux-kbuild-2.6*.deb 2> /dev/null )

INSTALL_KERNEL="$LIMAGE $LHEADERS_COMMON $LHEADERS_SIDUX $LHEADERS_ALL_ARCH $LHEADERS_ALL $LKBUILD"
echo 'Installing dpkg based local kernel components now...'
echo 'Install directory: ' $(pwd)
for PACKAGE in $INSTALL_KERNEL
do
	echo 'Sidux archived kernel installing kernel package: '$PACKAGE
	dpkg -i $PACKAGE
done

# something went wrong, allow apt an attempt to fix it
if [ "$?" -ne 0 ]; then
	if [ -e "/boot/vmlinuz-${VER}" ]; then 
		apt-get --fix-broken install
	else
		[ -x /usr/sbin/update-grub ] && update-grub
		echo "kernel image not install, terminate abnormally!"
		exit 3
	fi

fi

# we do need an initrd
if [ ! -f "/boot/initrd.img-${VER}" ]; then
	update-initramfs -k "${VER}" -c
fi

# set new kernel as default
[ -L /boot/vmlinuz ] &&		rm -f /boot/vmlinuz
[ -L /boot/initrd.img ] &&	rm -f /boot/initrd.img
[ -L /boot/System.map ] &&	rm -f /boot/System.map
[ -L /vmlinuz ] &&		ln -fs "boot/vmlinuz-${VER}" /vmlinuz
[ -L /initrd.img ] &&		ln -fs "boot/initrd.img-${VER}" /initrd.img

# in case we just created an initrd, update menu.lst
if [ -x /usr/sbin/update-grub ]; then
	update-grub
fi

# set symlinks to the kernel headers
ln -fs "linux-headers-${VER}" /usr/src/linux >/dev/null 2>&1

# try to install external dfsg-free module packages
for i in acer_acpi acerhk acx atl2 aufs av5100 btrfs eeepc_acpi et131x fsam7400 gspca kqemu ndiswrapper omnibook qc_usb quickcam r5u870 rfswitch sfc sqlzma squashfs tp_smapi vboxadd vboxdrv; do
	MODULE_PATH="$(/sbin/modinfo -k $(uname -r) -F filename "${i}" 2>/dev/null)"
	if [ -n "${MODULE_PATH}" ]; then
		MODULE_PACKAGE="$(dpkg -S ${MODULE_PATH} 2>/dev/null)"
		if [ -n "${MODULE_PACKAGE}" ]; then
			MODULE_PACKAGE="$(echo ${MODULE_PACKAGE} | sed s/$(uname -r).*/${VER}/g)"
			#if grep-aptavail -PX "${MODULE_PACKAGE}" >/dev/null 2>&1; then
			MPACKAGE=$( ls ${MODULE_PACKAGE}*.deb 2> /dev/null )
			if [ -n "$MPACKAGE" -a -f "$MPACKAGE" ]
			then
				echo 'Sidux archive kernel module installing: '$MPACKAGE
				dpkg -i $MPACKAGE
				#apt-get --assume-yes install "${MODULE_PACKAGE}"
				if [ "$?" -ne 0 ]; then
					#apt-get --fix-broken install
					:
				else
					# ignore error cases for now, apt will do the "right" thing to get 
					# into a consistent state and worst that could happen is some external
					# module not getting installed
					:
				fi
			fi
		fi
	fi
done

# hints for madwifi
if /sbin/modinfo -k $(uname -r) -F filename ath_pci >/dev/null 2>&1; then
	if [ -f /usr/src/madwifi.tar.bz2 ] && which m-a >/dev/null; then
		# user setup madwifi with module-assistant already
		# we may as well do that for him again now
		if [ -d /usr/src/modules/madwifi/ ]; then
			rm -rf /usr/src/modules/madwifi/
		fi

		m-a --text-mode --non-inter -l "${VER}" a-i madwifi
	else
		echo
		echo "Atheros Wireless Network Adaptor will not work until"
		echo "the non-free madwifi driver is reinstalled."
		echo
	fi
fi

# grub notice
echo
echo "Now you can simply reboot when using GRUB (default). If you use the LILO"
echo "bootloader you will have to configure it to use the new kernel."
echo 
echo "Make sure that /etc/fstab and /boot/grub/menu.lst use UUID or LABEL"
echo "based mounting, which is required for classic IDE vs. lib(p)ata changes!"
echo
echo "For more details about UUID or LABEL fstab usage see the sidux manual:"
echo "   http://manual.sidux.com/en/part-cfdisk-en.htm#disknames"
echo
echo "Have fun!"
echo

