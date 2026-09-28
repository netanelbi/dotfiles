// pad-hotkey /dev/input/eventN — Guide + R3 on a gamepad toggles the MangoHud HUD.
//
// One instance per pad, started by udev (70-pad-hotkey.rules ->
// pad-hotkey@eventN.service) when the pad appears; it exits when the device
// goes away. Blocks in read(), so it costs nothing while idle. Build: ./build.
//
// It presses MangoHud's own toggle_hud combo (Shift_R+F12) on a virtual uinput
// keyboard, so it works in every game exactly like the keyboard does. Tried and
// dropped (2026-09-28): `mangohudctl` speaks mangoapp's (gamescope) protocol,
// which the in-game HUD ignores; and the in-game control socket (`:hud;` to
// @mangohud) was never accept()ed in pascube -- a second Vulkan instance takes
// the socket name, so the one drawing never services it.
// If toggle_hud ever changes (GOverlay owns MangoHud.conf), change KEYS below.
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static const int KEYS[] = { KEY_RIGHTSHIFT, KEY_F12 };
#define NKEYS (int)(sizeof KEYS / sizeof *KEYS)
static int kbd = -1;

static void emit(int type, int code, int value) {
    struct input_event e = { .type = type, .code = code, .value = value };
    (void)!write(kbd, &e, sizeof e);
}

static void press(int down) {
    for (int i = 0; i < NKEYS; i++) {
        emit(EV_KEY, KEYS[down ? i : NKEYS - 1 - i], down);
        emit(EV_SYN, SYN_REPORT, 0);
    }
}

static void toggle(void) {
    press(1);
    usleep(80000);  // MangoHud polls key state per frame; a zero-length tap is missed
    press(0);
}

static int make_keyboard(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    for (int i = 0; i < NKEYS; i++) ioctl(fd, UI_SET_KEYBIT, KEYS[i]);
    struct uinput_setup s = { .id = { .bustype = BUS_VIRTUAL } };
    strcpy(s.name, "pad-hotkey keyboard");
    if (ioctl(fd, UI_DEV_SETUP, &s) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) { close(fd); return -1; }
    usleep(200000);  // let the compositor pick the new keyboard up before its first key
    return fd;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: pad-hotkey /dev/input/eventN\n"); return 2; }
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0) { perror(argv[1]); return 1; }

    int guide = 0, r3 = 0;
    struct input_event ev;
    while (read(fd, &ev, sizeof ev) == sizeof ev) {
        if (ev.type != EV_KEY || ev.value == 2) continue;  // 2 = autorepeat
        int down = ev.value == 1;
        int chord = 0;
        if (ev.code == BTN_MODE) { chord = down && r3; guide = down; }
        else if (ev.code == BTN_THUMBR) { chord = down && guide; r3 = down; }
        if (!chord) continue;
        // Created on first use, so pads that never chord add no input device.
        if (kbd < 0 && (kbd = make_keyboard()) < 0) { perror("/dev/uinput"); continue; }
        toggle();
    }
    return 0;  // device gone
}
