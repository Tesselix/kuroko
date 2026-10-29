# Shortcuts around `zig build`. The build itself lives in build.zig.
# The root Makefile is a copy of tools/ubuntu/Makefile.in:  cp tools/ubuntu/Makefile.in Makefile
#
#   make test            all unit tests (on the Mac)
#   make run             the simulator on the Mac
#   make ubuntu          build for the Ubuntu ARM VM into ubuntu-share/kuroko
#   make ubuntu OPTIMIZE=Debug    the same, as a Debug build
#   make vm              print the commands to run on the VM
#   make clean-ubuntu    remove the VM build from ubuntu-share
#
# ubuntu-share/ is the UTM shared folder; the VM mounts it (read-only) at
# VM_SHARE. On the VM:
#
#   sh /mnt/shared/kuroko/check.sh     before the first run: is the VM ready?
#   sh /mnt/shared/kuroko/setup.sh     once: libSDL3, Mesa, groups
#   sh /mnt/shared/kuroko/run.sh       Kuroko full screen on the VM's screen

SHARE    ?= ubuntu-share
VM_SHARE ?= /mnt/shared
TARGET   ?= aarch64-linux-gnu
OPTIMIZE ?= ReleaseSafe
OUT      := $(SHARE)/kuroko

.PHONY: all test run ubuntu vm clean-ubuntu

all: test

test:
	zig build test --summary all

run:
	zig build run

ubuntu:
	SHARE=$(SHARE) VM_SHARE=$(VM_SHARE) TARGET=$(TARGET) OPTIMIZE=$(OPTIMIZE) sh tools/ubuntu/build.sh

vm:
	@echo "On the VM (shared folder at $(VM_SHARE)):"
	@echo "  sh $(VM_SHARE)/kuroko/check.sh"
	@echo "  sh $(VM_SHARE)/kuroko/setup.sh     (once)"
	@echo "  sh $(VM_SHARE)/kuroko/run.sh"

clean-ubuntu:
	rm -rf $(OUT)
