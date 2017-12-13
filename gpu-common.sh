#!/bin/bash
# (shebang for shellcheck)

# Common code for gpu-windows and gpu-linux scripts

# Configuration

config=${1:-${HOSTNAME/.*/}}

# shellcheck source=../../.config/vfio/home.sh
source "$HOME/.config/vfio/$config.sh"

# Configuration files should declare:
# WIN_VM - virsh name of VM
# DM - name of systemd unit that controls X11 (e.g. nodm.service or sddm.service)
# RAM - how much RAM to allocate to huge pages, in GiB
# PCI_ADDR - PCI device address without function, e.g. 0000:0b:00

# Functions

function insmod() { echo "Use modprobe!" ; exit 1 ; }
function rmmod() { echo "Use modprobe -r!" ; exit 1 ; }

function rmmod_if_loaded() {
	if lsmod | grep "$1"
	then
		sudo modprobe -r "$1"
	fi
}

# Variables

gpu_vendor=$(</sys/bus/pci/devices/$PCI_ADDR.0/vendor) ; gpu_vendor=${gpu_vendor:2}
gpu_device=$(</sys/bus/pci/devices/$PCI_ADDR.0/device) ; gpu_device=${gpu_device:2}
