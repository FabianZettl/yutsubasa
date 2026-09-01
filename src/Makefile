# Builds sunshine-input-bridge: forwards Sunshine's virtual input devices into
# the nested headless Sway session via Wayland virtual-pointer / -keyboard.
#
#   make            build ./sunshine-input-bridge
#   make install    -> $(PREFIX)/bin  (PREFIX defaults to ~/.local)
#   make clean

PREFIX ?= $(HOME)/.local
BIN    := sunshine-input-bridge

PKGS   := wayland-client libevdev xkbcommon
CFLAGS ?= -O2 -g -Wall -Wextra
CFLAGS += $(shell pkg-config --cflags $(PKGS))
LDLIBS += $(shell pkg-config --libs $(PKGS))

SCANNER    := $(shell pkg-config --variable=wayland_scanner wayland-scanner 2>/dev/null || echo wayland-scanner)
PROTO_DIR  := protocols
GEN_H      := wlr-virtual-pointer-unstable-v1-client-protocol.h \
              virtual-keyboard-unstable-v1-client-protocol.h
GEN_C      := wlr-virtual-pointer-unstable-v1-protocol.c \
              virtual-keyboard-unstable-v1-protocol.c

.PHONY: all install clean
all: $(BIN)

%-client-protocol.h: $(PROTO_DIR)/%.xml
	$(SCANNER) client-header $< $@

%-protocol.c: $(PROTO_DIR)/%.xml
	$(SCANNER) private-code $< $@

$(BIN): sunshine-input-bridge.c $(GEN_C) $(GEN_H)
	$(CC) $(CFLAGS) -o $@ sunshine-input-bridge.c $(GEN_C) $(LDLIBS)

install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN) $(GEN_H) $(GEN_C)
