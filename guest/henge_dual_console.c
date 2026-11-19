/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Native zero-dependency Linux guest console & /dev/uinput HID bridge for henge-linux.
 *
 * Responsibilities:
 *  1. Spawns /sbin/agetty --autologin root on a PTY and mirrors output to both
 *     PL011 serial (stdout / ttyAMA0) and /dev/tty1 (Metal display) whenever tty1
 *     is the active virtual terminal.
 *  2. Emits "\x1b]9998;HENGE_HID_READY\x07" on stdout so the iOS host (HengeVMBridge)
 *     knows it is safe to send OSC 9999 HID frames (keeping UEFI and older guest
 *     images 100% free of OSC escape bytes).
 *  3. Runs a stateful byte-by-byte OSC 9999 parser on stdin (ttyAMA0) that cleanly
 *     strips "\x1b]9999;...\x07" frames even when split across UART reads, never
 *     leaking raw "9999;K ..." bytes into bash.
 *  4. Creates two separate /dev/uinput virtual devices (Keyboard + Absolute Tablet
 *     with wheel) so udev/libinput/Xorg classify them cleanly, and injects HID
 *     events into /dev/uinput whenever a non-tty1 VT (e.g., SDDM/LXQt on VT2) is active.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static uint16_t hid_usage_to_evdev(unsigned int usage) {
    static const uint16_t kTable[256] = {
        [0x04] = KEY_A, [0x05] = KEY_B, [0x06] = KEY_C, [0x07] = KEY_D,
        [0x08] = KEY_E, [0x09] = KEY_F, [0x0A] = KEY_G, [0x0B] = KEY_H,
        [0x0C] = KEY_I, [0x0D] = KEY_J, [0x0E] = KEY_K, [0x0F] = KEY_L,
        [0x10] = KEY_M, [0x11] = KEY_N, [0x12] = KEY_O, [0x13] = KEY_P,
        [0x14] = KEY_Q, [0x15] = KEY_R, [0x16] = KEY_S, [0x17] = KEY_T,
        [0x18] = KEY_U, [0x19] = KEY_V, [0x1A] = KEY_W, [0x1B] = KEY_X,
        [0x1C] = KEY_Y, [0x1D] = KEY_Z,
        [0x1E] = KEY_1, [0x1F] = KEY_2, [0x20] = KEY_3, [0x21] = KEY_4,
        [0x22] = KEY_5, [0x23] = KEY_6, [0x24] = KEY_7, [0x25] = KEY_8,
        [0x26] = KEY_9, [0x27] = KEY_0,
        [0x28] = KEY_ENTER, [0x29] = KEY_ESC, [0x2A] = KEY_BACKSPACE,
        [0x2B] = KEY_TAB, [0x2C] = KEY_SPACE, [0x2D] = KEY_MINUS,
        [0x2E] = KEY_EQUAL, [0x2F] = KEY_LEFTBRACE, [0x30] = KEY_RIGHTBRACE,
        [0x31] = KEY_BACKSLASH, [0x33] = KEY_SEMICOLON, [0x34] = KEY_APOSTROPHE,
        [0x35] = KEY_GRAVE, [0x36] = KEY_COMMA, [0x37] = KEY_DOT,
        [0x38] = KEY_SLASH, [0x39] = KEY_CAPSLOCK,
        [0x3A] = KEY_F1, [0x3B] = KEY_F2, [0x3C] = KEY_F3, [0x3D] = KEY_F4,
        [0x3E] = KEY_F5, [0x3F] = KEY_F6, [0x40] = KEY_F7, [0x41] = KEY_F8,
        [0x42] = KEY_F9, [0x43] = KEY_F10, [0x44] = KEY_F11, [0x45] = KEY_F12,
        [0x46] = KEY_SYSRQ, [0x47] = KEY_SCROLLLOCK, [0x48] = KEY_PAUSE,
        [0x49] = KEY_INSERT, [0x4A] = KEY_HOME, [0x4B] = KEY_PAGEUP,
        [0x4C] = KEY_DELETE, [0x4D] = KEY_END, [0x4E] = KEY_PAGEDOWN,
        [0x4F] = KEY_RIGHT, [0x50] = KEY_LEFT, [0x51] = KEY_DOWN, [0x52] = KEY_UP,
        [0x53] = KEY_NUMLOCK, [0x54] = KEY_KPSLASH, [0x55] = KEY_KPASTERISK,
        [0x56] = KEY_KPMINUS, [0x57] = KEY_KPPLUS, [0x58] = KEY_KPENTER,
        [0x59] = KEY_KP1, [0x5A] = KEY_KP2, [0x5B] = KEY_KP3, [0x5C] = KEY_KP4,
        [0x5D] = KEY_KP5, [0x5E] = KEY_KP6, [0x5F] = KEY_KP7, [0x60] = KEY_KP8,
        [0x61] = KEY_KP9, [0x62] = KEY_KP0, [0x63] = KEY_KPDOT,
        [0x65] = KEY_COMPOSE,
        [0xE0] = KEY_LEFTCTRL, [0xE1] = KEY_LEFTSHIFT, [0xE2] = KEY_LEFTALT,
        [0xE3] = KEY_LEFTMETA, [0xE4] = KEY_RIGHTCTRL, [0xE5] = KEY_RIGHTSHIFT,
        [0xE6] = KEY_RIGHTALT, [0xE7] = KEY_RIGHTMETA,
    };
    return usage < 256U ? kTable[usage] : 0U;
}

static void write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0U) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
}

static void emit_ev(int fd, uint16_t type, uint16_t code, int32_t value) {
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    ssize_t ignored = write(fd, &ev, sizeof(ev));
    (void)ignored;
}

static int create_uinput_keyboard(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 || ioctl(fd, UI_SET_EVBIT, EV_REP) < 0) {
        close(fd);
        return -1;
    }
    for (unsigned int u = 0U; u < 256U; ++u) {
        uint16_t code = hid_usage_to_evdev(u);
        if (code != 0U) {
            (void)ioctl(fd, UI_SET_KEYBIT, code);
        }
    }
    struct uinput_setup usetup;
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_VIRTUAL;
    usetup.id.vendor = 0x1234;
    usetup.id.product = 0x5678;
    usetup.id.version = 1;
    snprintf(usetup.name, sizeof(usetup.name), "HengeLinux Virtual Keyboard");
    if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int create_uinput_tablet(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        return -1;
    }
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_REL) < 0) {
        close(fd);
        return -1;
    }
    (void)ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
    (void)ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT);
    (void)ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE);
    (void)ioctl(fd, UI_SET_RELBIT, REL_WHEEL);
    (void)ioctl(fd, UI_SET_ABSBIT, ABS_X);
    (void)ioctl(fd, UI_SET_ABSBIT, ABS_Y);
    (void)ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

    struct uinput_abs_setup abs_x;
    memset(&abs_x, 0, sizeof(abs_x));
    abs_x.code = ABS_X;
    abs_x.absinfo.minimum = 0;
    abs_x.absinfo.maximum = 32767;
    struct uinput_abs_setup abs_y;
    memset(&abs_y, 0, sizeof(abs_y));
    abs_y.code = ABS_Y;
    abs_y.absinfo.minimum = 0;
    abs_y.absinfo.maximum = 32767;

    if (ioctl(fd, UI_ABS_SETUP, &abs_x) < 0 || ioctl(fd, UI_ABS_SETUP, &abs_y) < 0) {
        close(fd);
        return -1;
    }

    struct uinput_setup usetup;
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_VIRTUAL;
    usetup.id.vendor = 0x1234;
    usetup.id.product = 0x5679;
    usetup.id.version = 1;
    snprintf(usetup.name, sizeof(usetup.name), "HengeLinux Virtual Tablet");
    if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool tty1_is_active(void) {
    int fd = open("/sys/class/tty/tty0/active", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return true;
    }
    char buf[32];
    ssize_t n = read(fd, buf, sizeof(buf) - 1U);
    close(fd);
    if (n <= 0) {
        return true;
    }
    buf[n] = '\0';
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ')) {
        buf[--n] = '\0';
    }
    return (buf[0] == '\0' || strcmp(buf, "tty1") == 0);
}

typedef struct {
    int kbd_fd;
    int ptr_fd;
    unsigned int prev_buttons;
    time_t last_open_attempt;
} UinputState;

static void ensure_uinput_open(UinputState *u) {
    if (u->kbd_fd >= 0 && u->ptr_fd >= 0) {
        return;
    }
    time_t now = time(NULL);
    if (now == u->last_open_attempt) {
        return;
    }
    u->last_open_attempt = now;
    if (u->kbd_fd < 0) {
        u->kbd_fd = create_uinput_keyboard();
    }
    if (u->ptr_fd < 0) {
        u->ptr_fd = create_uinput_tablet();
    }
}

static void handle_hid_frame(UinputState *u, const char *body, bool on_tty1) {
    if (on_tty1) {
        /* On tty1 text console, bash receives normal serial bytes; skip uinput injection. */
        return;
    }
    ensure_uinput_open(u);
    if (body[0] == 'P' && body[1] == ' ') {
        int x = 0, y = 0, wheel = 0;
        unsigned int buttons = 0U;
        if (sscanf(body + 2, "%d %d %u %d", &x, &y, &buttons, &wheel) == 4 && u->ptr_fd >= 0) {
            if (x < 0) x = 0;
            if (x > 32767) x = 32767;
            if (y < 0) y = 0;
            if (y > 32767) y = 32767;
            emit_ev(u->ptr_fd, EV_ABS, ABS_X, x);
            emit_ev(u->ptr_fd, EV_ABS, ABS_Y, y);
            static const struct { unsigned int bit; uint16_t btn; } kBtns[3] = {
                {1U, BTN_LEFT}, {2U, BTN_RIGHT}, {4U, BTN_MIDDLE}
            };
            for (size_t i = 0U; i < 3U; ++i) {
                bool was = (u->prev_buttons & kBtns[i].bit) != 0U;
                bool now = (buttons & kBtns[i].bit) != 0U;
                if (was != now) {
                    emit_ev(u->ptr_fd, EV_KEY, kBtns[i].btn, now ? 1 : 0);
                }
            }
            u->prev_buttons = buttons;
            if (wheel != 0) {
                emit_ev(u->ptr_fd, EV_REL, REL_WHEEL, wheel);
            }
            emit_ev(u->ptr_fd, EV_SYN, SYN_REPORT, 0);
        }
    } else if (body[0] == 'K' && body[1] == ' ') {
        unsigned int usage = 0U;
        int pressed = 0;
        if (sscanf(body + 2, "%x %d", &usage, &pressed) == 2 && u->kbd_fd >= 0) {
            uint16_t code = hid_usage_to_evdev(usage);
            if (code != 0U) {
                emit_ev(u->kbd_fd, EV_KEY, code, pressed ? 1 : 0);
                emit_ev(u->kbd_fd, EV_SYN, SYN_REPORT, 0);
            }
        }
    }
}

typedef enum {
    ST_NORMAL = 0,
    ST_ESC,
    ST_OSC_PREFIX,
    ST_OSC_BODY
} OscState;

static int open_pty_pair(int *master_out, int *slave_out) {
    int mfd = posix_openpt(O_RDWR | O_NOCTTY);
    if (mfd < 0) {
        return -1;
    }
    if (grantpt(mfd) < 0 || unlockpt(mfd) < 0) {
        close(mfd);
        return -1;
    }
    const char *sname = ptsname(mfd);
    if (sname == NULL) {
        close(mfd);
        return -1;
    }
    int sfd = open(sname, O_RDWR | O_NOCTTY);
    if (sfd < 0) {
        close(mfd);
        return -1;
    }
    *master_out = mfd;
    *slave_out = sfd;
    return 0;
}

static void exec_root_shell(void) {
    setenv("HOME", "/root", 1);
    setenv("USER", "root", 1);
    setenv("LOGNAME", "root", 1);
    setenv("SHELL", "/bin/bash", 1);
    setenv("TERM", "linux", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin", 1);
    if (chdir("/root") != 0 && chdir("/") != 0) {
        /* Continue in inherited working directory if neither exists. */
    }
    static const char kBanner[] = "\r\nArch Linux ARM (HengeLinux) — root@hengelinux\r\n\r\n";
    write_all(STDOUT_FILENO, kBanner, sizeof(kBanner) - 1U);
    execl("/bin/bash", "-bash", "-i", (char *)NULL);
    execl("/bin/sh", "-sh", "-i", (char *)NULL);
    _exit(127);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    int tty1_fd = open("/dev/tty1", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    int master_fd = -1;
    int slave_fd = -1;
    if (open_pty_pair(&master_fd, &slave_fd) != 0) {
        if (tty1_fd >= 0) {
            close(tty1_fd);
        }
        exec_root_shell();
        return 127;
    }

    if (tty1_fd >= 0) {
        struct winsize ws;
        if (ioctl(tty1_fd, TIOCGWINSZ, &ws) == 0) {
            (void)ioctl(slave_fd, TIOCSWINSZ, &ws);
        }
    }

    pid_t pid = fork();
    if (pid == 0) {
        signal(SIGPIPE, SIG_DFL);
        if (tty1_fd >= 0) {
            close(tty1_fd);
        }
        close(master_fd);
        setsid();
        (void)ioctl(slave_fd, TIOCSCTTY, 0);
        dup2(slave_fd, STDIN_FILENO);
        dup2(slave_fd, STDOUT_FILENO);
        dup2(slave_fd, STDERR_FILENO);
        if (slave_fd > STDERR_FILENO) {
            close(slave_fd);
        }
        exec_root_shell();
    }
    close(slave_fd);

    struct termios old_attrs;
    bool have_termios = (tcgetattr(STDIN_FILENO, &old_attrs) == 0);
    if (have_termios) {
        struct termios raw = old_attrs;
        cfmakeraw(&raw);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        (void)tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }

    UinputState uinput = {-1, -1, 0U, 0};
    ensure_uinput_open(&uinput);

    /* Announce to iOS HengeVMBridge that this console cleanly parses OSC 9999 HID frames. */
    static const char kReadyBanner[] = "\x1b]9998;HENGE_HID_READY\x07";
    write_all(STDOUT_FILENO, kReadyBanner, sizeof(kReadyBanner) - 1U);

    OscState st = ST_NORMAL;
    static const char kPrefix[] = "9999;";
    const size_t kPrefixLen = sizeof(kPrefix) - 1U;
    size_t prefix_len = 0U;
    char osc_body[128];
    size_t osc_len = 0U;

    uint8_t in_buf[1024];
    uint8_t out_buf[4096];

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(STDIN_FILENO, &rfds);
        FD_SET(master_fd, &rfds);
        int max_fd = (STDIN_FILENO > master_fd ? STDIN_FILENO : master_fd) + 1;

        struct timeval tv;
        struct timeval *tvp = NULL;
        if (st == ST_ESC) {
            tv.tv_sec = 0;
            tv.tv_usec = 50000; /* 50 ms standalone ESC flush */
            tvp = &tv;
        }

        int rc = select(max_fd, &rfds, NULL, NULL, tvp);
        if (rc < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (rc == 0 && st == ST_ESC) {
            if (tty1_is_active()) {
                uint8_t esc = 0x1BU;
                write_all(master_fd, &esc, 1U);
            }
            st = ST_NORMAL;
            continue;
        }

        if (FD_ISSET(STDIN_FILENO, &rfds)) {
            ssize_t n = read(STDIN_FILENO, in_buf, sizeof(in_buf));
            if (n <= 0) {
                if (n < 0 && errno == EINTR) {
                    continue;
                }
                break;
            }
            bool on_tty1 = tty1_is_active();
            uint8_t pty_out[1024];
            size_t pty_len = 0U;

            for (ssize_t i = 0; i < n; ++i) {
                uint8_t b = in_buf[i];
                if (st == ST_NORMAL) {
                    if (b == 0x1BU) {
                        st = ST_ESC;
                    } else if (on_tty1 && pty_len < sizeof(pty_out)) {
                        pty_out[pty_len++] = b;
                    }
                } else if (st == ST_ESC) {
                    if (b == (uint8_t)']') {
                        st = ST_OSC_PREFIX;
                        prefix_len = 0U;
                    } else if (b == 0x1BU) {
                        if (on_tty1 && pty_len < sizeof(pty_out)) {
                            pty_out[pty_len++] = 0x1BU;
                        }
                    } else {
                        if (on_tty1 && pty_len + 2U <= sizeof(pty_out)) {
                            pty_out[pty_len++] = 0x1BU;
                            pty_out[pty_len++] = b;
                        }
                        st = ST_NORMAL;
                    }
                } else if (st == ST_OSC_PREFIX) {
                    if (b == (uint8_t)kPrefix[prefix_len]) {
                        prefix_len++;
                        if (prefix_len == kPrefixLen) {
                            st = ST_OSC_BODY;
                            osc_len = 0U;
                        }
                    } else {
                        if (on_tty1 && pty_len + 3U + prefix_len <= sizeof(pty_out)) {
                            pty_out[pty_len++] = 0x1BU;
                            pty_out[pty_len++] = (uint8_t)']';
                            for (size_t k = 0U; k < prefix_len; ++k) {
                                pty_out[pty_len++] = (uint8_t)kPrefix[k];
                            }
                            pty_out[pty_len++] = b;
                        }
                        st = ST_NORMAL;
                    }
                } else { /* ST_OSC_BODY */
                    if (b == 0x07U) {
                        osc_body[osc_len] = '\0';
                        handle_hid_frame(&uinput, osc_body, on_tty1);
                        st = ST_NORMAL;
                    } else if (osc_len + 1U < sizeof(osc_body)) {
                        osc_body[osc_len++] = (char)b;
                    } else {
                        st = ST_NORMAL;
                    }
                }
            }

            if (on_tty1 && pty_len > 0U) {
                write_all(master_fd, pty_out, pty_len);
            }
        }

        if (FD_ISSET(master_fd, &rfds)) {
            ssize_t n = read(master_fd, out_buf, sizeof(out_buf));
            if (n <= 0) {
                if (n < 0 && errno == EINTR) {
                    continue;
                }
                break;
            }
            write_all(STDOUT_FILENO, out_buf, (size_t)n);
            if (tty1_fd >= 0 && tty1_is_active()) {
                write_all(tty1_fd, out_buf, (size_t)n);
            }
        }
    }

    if (have_termios) {
        (void)tcsetattr(STDIN_FILENO, TCSADRAIN, &old_attrs);
    }
    if (uinput.kbd_fd >= 0) {
        (void)ioctl(uinput.kbd_fd, UI_DEV_DESTROY);
        close(uinput.kbd_fd);
    }
    if (uinput.ptr_fd >= 0) {
        (void)ioctl(uinput.ptr_fd, UI_DEV_DESTROY);
        close(uinput.ptr_fd);
    }
    close(master_fd);
    if (tty1_fd >= 0) {
        close(tty1_fd);
    }
    int status = 0;
    if (pid > 0 && waitpid(pid, &status, 0) > 0 && WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 0;
}
