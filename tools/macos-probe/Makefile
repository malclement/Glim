# Probes for an external monitor on macOS (Apple Silicon). All read-only, except
# hpvolume (audio level), displaymode (resolution) and uacprobe with a value.
# Needs only the Command Line Tools (swiftc, clang). `make` builds all nine.
SWIFTC ?= swiftc
CC     ?= clang

all: displayprobe edidprobe audioprobe camprobe usbdescprobe hidprobe hpvolume displaymode uacprobe

%: %.swift
	$(SWIFTC) -O $< -o $@

usbdescprobe hidprobe uacprobe: %: %.c
	$(CC) -O1 -Wall -o $@ $< -framework IOKit -framework CoreFoundation

clean:
	rm -f displayprobe edidprobe audioprobe camprobe usbdescprobe hidprobe hpvolume displaymode uacprobe

.PHONY: all clean
