# Read-only probes for an external monitor on macOS (Apple Silicon).
# Needs only the Command Line Tools (swiftc, clang). `make` builds all seven.
SWIFTC ?= swiftc
CC     ?= clang

all: displayprobe edidprobe audioprobe camprobe usbdescprobe hidprobe hpvolume

%: %.swift
	$(SWIFTC) -O $< -o $@

usbdescprobe hidprobe: %: %.c
	$(CC) -O1 -Wall -o $@ $< -framework IOKit -framework CoreFoundation

clean:
	rm -f displayprobe edidprobe audioprobe camprobe usbdescprobe hidprobe hpvolume

.PHONY: all clean
