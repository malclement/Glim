CC      ?= clang
CFLAGS  ?= -O2 -Wall -Wextra
LDFLAGS += -framework IOKit -framework CoreFoundation

glim: src/glim.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f glim

.PHONY: clean
