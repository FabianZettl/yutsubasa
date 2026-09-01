/*
 * sunshine-input-bridge - forward Sunshine's virtual input into the nested
 * headless Sway gaming session.
 *
 * Sunshine (inputtino) injects the streaming client's mouse / keyboard / touch
 * through GLOBAL uinput devices ("Mouse passthrough", "Keyboard passthrough",
 * ...).  A headless wlroots compositor has no libinput backend, so it never
 * sees them - instead the *physical* desktop compositor picks them up and the
 * client ends up driving the wrong screen.
 *
 * This daemon runs INSIDE the gaming session, reads the evdev nodes it is
 * handed on the command line (the launcher passes only the gaming Sunshine
 * instance's nodes) and replays every event through Sway's
 *   - zwlr_virtual_pointer_v1   (relative + absolute motion, buttons, wheel)
 *   - zwp_virtual_keyboard_v1   (keymap + key + modifiers)
 * so the input lands in the streamed session and nowhere else.
 *
 * The physical desktop is kept out of it separately: the launcher writes an
 * `hl.device{ enabled = false }` rule for the same passthrough devices.
 *
 * Deliberately single-threaded, no dynamic hotplug: the launcher starts one of
 * these per gaming stream and kills it on disconnect.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <linux/input-event-codes.h>
#include <libevdev/libevdev.h>
#include <xkbcommon/xkbcommon.h>
#include <wayland-client.h>

#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"

#ifndef REL_WHEEL_HI_RES
#define REL_WHEEL_HI_RES 0x0b
#endif
#ifndef REL_HWHEEL_HI_RES
#define REL_HWHEEL_HI_RES 0x0c
#endif

#define MAX_DEVS 16
#define MAX_BTN  32

static bool verbose = false;
static volatile sig_atomic_t running = 1;

static void logv(const char *fmt, ...) {
	if (!verbose) return;
	va_list ap; va_start(ap, fmt);
	fputs("[input-bridge] ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}
static void logw(const char *fmt, ...) {
	va_list ap; va_start(ap, fmt);
	fputs("[input-bridge] ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

static void on_signal(int s) { (void)s; running = 0; }

static uint32_t now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint32_t)(ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL);
}

/* ------------------------------------------------------------------ Wayland */
struct wl_state {
	struct wl_display  *dpy;
	struct wl_registry *reg;
	struct wl_seat     *seat;
	struct zwlr_virtual_pointer_manager_v1  *vpm;
	struct zwp_virtual_keyboard_manager_v1  *vkm;
	struct zwlr_virtual_pointer_v1  *vp;
	struct zwp_virtual_keyboard_v1  *vk;
	uint32_t vpm_ver;
};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t ver) {
	struct wl_state *w = data;
	if (!strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name)) {
		uint32_t v = ver < 2 ? ver : 2;
		w->vpm = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface, v);
		w->vpm_ver = v;
	} else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name)) {
		w->vkm = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
	} else if (!strcmp(iface, wl_seat_interface.name)) {
		uint32_t v = ver < 5 ? ver : 5;
		w->seat = wl_registry_bind(reg, name, &wl_seat_interface, v);
	}
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_global_remove };

/* --------------------------------------------------------------- keyboard */
static struct xkb_context *xkb_ctx;
static struct xkb_keymap  *xkb_km;
static struct xkb_state   *xkb_st;

static bool keyboard_setup(struct wl_state *w, const char *layout) {
	if (!w->vkm || !w->seat) {
		logw("no virtual-keyboard manager or seat - keyboard input disabled");
		return false;
	}
	xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	if (!xkb_ctx) return false;
	struct xkb_rule_names names = {
		.rules = NULL, .model = NULL,
		.layout = (layout && *layout) ? layout : "us",
		.variant = NULL, .options = NULL,
	};
	xkb_km = xkb_keymap_new_from_names(xkb_ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
	if (!xkb_km && names.layout != NULL) {
		logw("xkb layout '%s' failed - falling back to 'us'", names.layout);
		names.layout = "us";
		xkb_km = xkb_keymap_new_from_names(xkb_ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
	}
	if (!xkb_km) { logw("could not compile any xkb keymap"); return false; }
	xkb_st = xkb_state_new(xkb_km);
	if (!xkb_st) return false;

	char *str = xkb_keymap_get_as_string(xkb_km, XKB_KEYMAP_FORMAT_TEXT_V1);
	if (!str) return false;
	size_t len = strlen(str) + 1;
	int fd = memfd_create("gl-keymap", MFD_CLOEXEC);
	if (fd < 0) { free(str); logw("memfd_create: %s", strerror(errno)); return false; }
	if (write(fd, str, len) != (ssize_t)len) { free(str); close(fd); return false; }
	free(str);

	w->vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(w->vkm, w->seat);
	zwp_virtual_keyboard_v1_keymap(w->vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)len);
	close(fd);
	logv("virtual keyboard ready (layout %s)", names.layout);
	return true;
}

static void keyboard_key(struct wl_state *w, uint16_t code, int32_t value) {
	if (!w->vk) return;
	if (value == 2) return;                     /* drop autorepeat; the compositor makes its own */
	uint32_t state = value ? 1u : 0u;          /* wl_keyboard.key_state */
	zwp_virtual_keyboard_v1_key(w->vk, now_ms(), code, state);
	if (xkb_st) {
		xkb_state_update_key(xkb_st, code + 8,
		                     value ? XKB_KEY_DOWN : XKB_KEY_UP);
		uint32_t dep = xkb_state_serialize_mods(xkb_st, XKB_STATE_MODS_DEPRESSED);
		uint32_t lat = xkb_state_serialize_mods(xkb_st, XKB_STATE_MODS_LATCHED);
		uint32_t loc = xkb_state_serialize_mods(xkb_st, XKB_STATE_MODS_LOCKED);
		uint32_t grp = xkb_state_serialize_layout(xkb_st, XKB_STATE_LAYOUT_EFFECTIVE);
		zwp_virtual_keyboard_v1_modifiers(w->vk, dep, lat, loc, grp);
	}
}

/* ---------------------------------------------------------------- pointer */
enum { ROLE_KBD = 1, ROLE_REL = 2, ROLE_ABS = 4 };

struct pending {
	int32_t dx, dy;
	bool    have_abs;
	int32_t abs_x, abs_y;
	int32_t wheel, hwheel;             /* discrete notches */
	int32_t wheel_hi, hwheel_hi;       /* 1/120 units */
	int     nbtn;
	uint16_t bcode[MAX_BTN];
	int32_t  bval[MAX_BTN];
};

struct dev {
	int fd;
	struct libevdev *ev;
	const char *path;
	int roles;
	int32_t amin_x, amax_x, amin_y, amax_y;
	struct pending p;
};

static bool is_pointer_button(uint16_t c) {
	return c == BTN_LEFT || c == BTN_RIGHT || c == BTN_MIDDLE ||
	       c == BTN_SIDE || c == BTN_EXTRA || c == BTN_FORWARD ||
	       c == BTN_BACK  || c == BTN_TASK;
}

static void flush_pending(struct wl_state *w, struct dev *d) {
	struct pending *p = &d->p;
	bool dirty = false;

	if (p->dx || p->dy) {
		zwlr_virtual_pointer_v1_motion(w->vp, now_ms(),
		    wl_fixed_from_int(p->dx), wl_fixed_from_int(p->dy));
		dirty = true;
	}
	if (p->have_abs && (d->roles & ROLE_ABS)) {
		int32_t rx = d->amax_x - d->amin_x;
		int32_t ry = d->amax_y - d->amin_y;
		if (rx > 0 && ry > 0) {
			int32_t x = p->abs_x - d->amin_x;
			int32_t y = p->abs_y - d->amin_y;
			if (x < 0) x = 0;
			if (x > rx) x = rx;
			if (y < 0) y = 0;
			if (y > ry) y = ry;
			zwlr_virtual_pointer_v1_motion_absolute(w->vp, now_ms(),
			    (uint32_t)x, (uint32_t)y, (uint32_t)rx, (uint32_t)ry);
			dirty = true;
		}
	}
	for (int i = 0; i < p->nbtn; i++) {
		zwlr_virtual_pointer_v1_button(w->vp, now_ms(), p->bcode[i],
		    p->bval[i] ? WL_POINTER_BUTTON_STATE_PRESSED
		               : WL_POINTER_BUTTON_STATE_RELEASED);
		dirty = true;
	}
	/* wheel: prefer hi-res when the device sends it */
	int32_t wv = p->wheel_hi  ? p->wheel_hi  : p->wheel  * 120;
	int32_t hv = p->hwheel_hi ? p->hwheel_hi : p->hwheel * 120;
	if (wv) {
		zwlr_virtual_pointer_v1_axis_source(w->vp, WL_POINTER_AXIS_SOURCE_WHEEL);
		zwlr_virtual_pointer_v1_axis(w->vp, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL,
		    wl_fixed_from_double(-wv / 120.0 * 15.0));
		zwlr_virtual_pointer_v1_axis_discrete(w->vp, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL,
		    wl_fixed_from_double(-wv / 120.0 * 15.0), -(wv / 120));
		dirty = true;
	}
	if (hv) {
		zwlr_virtual_pointer_v1_axis_source(w->vp, WL_POINTER_AXIS_SOURCE_WHEEL);
		zwlr_virtual_pointer_v1_axis(w->vp, now_ms(), WL_POINTER_AXIS_HORIZONTAL_SCROLL,
		    wl_fixed_from_double(hv / 120.0 * 15.0));
		zwlr_virtual_pointer_v1_axis_discrete(w->vp, now_ms(), WL_POINTER_AXIS_HORIZONTAL_SCROLL,
		    wl_fixed_from_double(hv / 120.0 * 15.0), hv / 120);
		dirty = true;
	}
	if (dirty)
		zwlr_virtual_pointer_v1_frame(w->vp);

	memset(p, 0, sizeof(*p));
}

static void handle_event(struct wl_state *w, struct dev *d, const struct input_event *e) {
	struct pending *p = &d->p;
	switch (e->type) {
	case EV_SYN:
		if (e->code == SYN_REPORT)
			flush_pending(w, d);
		break;
	case EV_REL:
		switch (e->code) {
		case REL_X:            p->dx += e->value; break;
		case REL_Y:            p->dy += e->value; break;
		case REL_WHEEL:        p->wheel   += e->value; break;
		case REL_HWHEEL:       p->hwheel  += e->value; break;
		case REL_WHEEL_HI_RES: p->wheel_hi  += e->value; break;
		case REL_HWHEEL_HI_RES:p->hwheel_hi += e->value; break;
		}
		break;
	case EV_ABS:
		if (e->code == ABS_X) { p->abs_x = e->value; p->have_abs = true; }
		else if (e->code == ABS_Y) { p->abs_y = e->value; p->have_abs = true; }
		break;
	case EV_KEY:
		if ((d->roles & (ROLE_REL | ROLE_ABS)) && is_pointer_button(e->code)) {
			if (p->nbtn < MAX_BTN) { p->bcode[p->nbtn] = e->code; p->bval[p->nbtn] = e->value; p->nbtn++; }
		} else if ((d->roles & ROLE_ABS) && e->code == BTN_TOUCH) {
			if (p->nbtn < MAX_BTN) { p->bcode[p->nbtn] = BTN_LEFT; p->bval[p->nbtn] = e->value; p->nbtn++; }
		} else if ((d->roles & ROLE_KBD) && e->code < BTN_MISC) {
			keyboard_key(w, e->code, e->value);   /* keys go out immediately */
		}
		break;
	}
}

static void drain_dev(struct wl_state *w, struct dev *d) {
	struct input_event e;
	int rc;
	for (;;) {
		rc = libevdev_next_event(d->ev, LIBEVDEV_READ_FLAG_NORMAL, &e);
		if (rc == LIBEVDEV_READ_STATUS_SUCCESS) {
			handle_event(w, d, &e);
		} else if (rc == LIBEVDEV_READ_STATUS_SYNC) {
			while (libevdev_next_event(d->ev, LIBEVDEV_READ_FLAG_SYNC, &e)
			       == LIBEVDEV_READ_STATUS_SUCCESS)
				handle_event(w, d, &e);
		} else if (rc == -EAGAIN) {
			break;
		} else {
			logw("%s: read error (%s) - dropping device", d->path, strerror(-rc));
			libevdev_free(d->ev); close(d->fd);
			d->ev = NULL; d->fd = -1;
			break;
		}
	}
}

static int classify(struct libevdev *ev) {
	/* never touch a real gamepad - Steam Input grabs the js node directly */
	if (libevdev_has_event_code(ev, EV_KEY, BTN_GAMEPAD) ||
	    libevdev_has_event_code(ev, EV_KEY, BTN_SOUTH))
		return 0;

	int roles = 0;
	if (libevdev_has_event_code(ev, EV_KEY, KEY_ENTER) ||
	    libevdev_has_event_code(ev, EV_KEY, KEY_A))
		roles |= ROLE_KBD;
	if (libevdev_has_event_code(ev, EV_REL, REL_X) &&
	    libevdev_has_event_code(ev, EV_REL, REL_Y))
		roles |= ROLE_REL;
	if (libevdev_has_event_code(ev, EV_ABS, ABS_X) &&
	    libevdev_has_event_code(ev, EV_ABS, ABS_Y) &&
	    (libevdev_has_event_code(ev, EV_KEY, BTN_LEFT) ||
	     libevdev_has_event_code(ev, EV_KEY, BTN_TOUCH) ||
	     libevdev_has_event_code(ev, EV_KEY, BTN_MOUSE)))
		roles |= ROLE_ABS;
	return roles;
}

int main(int argc, char **argv) {
	const char *layout = NULL;
	const char *wl_name = NULL;
	const char *nodes[MAX_DEVS];
	int nnodes = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--verbose") || !strcmp(argv[i], "-v")) verbose = true;
		else if (!strcmp(argv[i], "--layout") && i + 1 < argc) layout = argv[++i];
		else if (!strcmp(argv[i], "--display") && i + 1 < argc) wl_name = argv[++i];
		else if (!strncmp(argv[i], "--layout=", 9)) layout = argv[i] + 9;
		else if (!strncmp(argv[i], "--display=", 10)) wl_name = argv[i] + 10;
		else if (argv[i][0] == '-') { fprintf(stderr, "unknown option: %s\n", argv[i]); return 1; }
		else if (nnodes < MAX_DEVS) nodes[nnodes++] = argv[i];
	}
	if (nnodes == 0) {
		fprintf(stderr,
		    "usage: %s [--verbose] [--layout XKB] [--display NAME] /dev/input/eventN ...\n",
		    argv[0]);
		return 1;
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);

	struct wl_state w = {0};
	w.dpy = wl_display_connect(wl_name);
	if (!w.dpy) {
		logw("cannot connect to Wayland display '%s': %s",
		     wl_name ? wl_name : getenv("WAYLAND_DISPLAY"), strerror(errno));
		return 3;
	}
	w.reg = wl_display_get_registry(w.dpy);
	wl_registry_add_listener(w.reg, &reg_listener, &w);
	wl_display_roundtrip(w.dpy);

	if (!w.vpm) {
		logw("compositor has no zwlr_virtual_pointer_manager_v1 - cannot forward input");
		return 2;
	}
	w.vp = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(w.vpm, w.seat);

	/* open the evdev nodes we were handed */
	struct dev devs[MAX_DEVS];
	int ndev = 0;
	bool want_kbd = false;
	for (int i = 0; i < nnodes; i++) {
		int fd = open(nodes[i], O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) { logw("open %s: %s", nodes[i], strerror(errno)); continue; }
		struct libevdev *ev = NULL;
		if (libevdev_new_from_fd(fd, &ev) < 0) { logw("libevdev %s failed", nodes[i]); close(fd); continue; }
		int roles = classify(ev);
		if (!roles) { logv("%s: no usable role, skipped", nodes[i]); libevdev_free(ev); close(fd); continue; }
		struct dev *d = &devs[ndev++];
		memset(d, 0, sizeof(*d));
		d->fd = fd; d->ev = ev; d->path = nodes[i]; d->roles = roles;
		if (roles & ROLE_ABS) {
			d->amin_x = libevdev_get_abs_minimum(ev, ABS_X);
			d->amax_x = libevdev_get_abs_maximum(ev, ABS_X);
			d->amin_y = libevdev_get_abs_minimum(ev, ABS_Y);
			d->amax_y = libevdev_get_abs_maximum(ev, ABS_Y);
		}
		if (roles & ROLE_KBD) want_kbd = true;
		logv("%s: %s (%s%s%s )", nodes[i], libevdev_get_name(ev),
		     roles & ROLE_KBD ? "kbd " : "", roles & ROLE_REL ? "rel " : "",
		     roles & ROLE_ABS ? "abs" : "");
	}
	if (ndev == 0) { logw("no usable input devices - nothing to forward"); return 4; }
	if (want_kbd) keyboard_setup(&w, layout);
	wl_display_flush(w.dpy);

	logw("forwarding %d device(s) into %s", ndev,
	     wl_name ? wl_name : (getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "?"));

	struct pollfd fds[1 + MAX_DEVS];
	while (running) {
		wl_display_flush(w.dpy);
		int nf = 0;
		fds[nf].fd = wl_display_get_fd(w.dpy);
		fds[nf].events = POLLIN; fds[nf].revents = 0; nf++;
		int map[MAX_DEVS];
		for (int i = 0; i < ndev; i++) {
			if (devs[i].fd < 0) continue;
			fds[nf].fd = devs[i].fd;
			fds[nf].events = POLLIN; fds[nf].revents = 0;
			map[nf] = i; nf++;
		}
		if (nf == 1) { logw("all devices gone - exiting"); break; }

		if (poll(fds, nf, -1) < 0) {
			if (errno == EINTR) continue;
			logw("poll: %s", strerror(errno));
			break;
		}
		if (fds[0].revents & (POLLERR | POLLHUP)) { logw("compositor hung up"); break; }
		if (fds[0].revents & POLLIN) {
			if (wl_display_dispatch(w.dpy) < 0) { logw("wayland dispatch failed - session gone"); break; }
		}
		for (int k = 1; k < nf; k++) {
			if (fds[k].revents & POLLIN)
				drain_dev(&w, &devs[map[k]]);
		}
	}

	for (int i = 0; i < ndev; i++)
		if (devs[i].ev) { libevdev_free(devs[i].ev); close(devs[i].fd); }
	if (w.vk) zwp_virtual_keyboard_v1_destroy(w.vk);
	if (w.vp) zwlr_virtual_pointer_v1_destroy(w.vp);
	if (xkb_st) xkb_state_unref(xkb_st);
	if (xkb_km) xkb_keymap_unref(xkb_km);
	if (xkb_ctx) xkb_context_unref(xkb_ctx);
	wl_display_flush(w.dpy);
	wl_display_disconnect(w.dpy);
	return 0;
}
