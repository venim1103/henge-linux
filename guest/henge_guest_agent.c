/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * HengeLinux Unified Zero-Dependency Static Guest Agent (henge-guest-agent)
 *
 * Single-binary multi-call agent (compiles cleanly with glibc or musl -static)
 * consolidating all optional Linux guest integrations for HengeLinux iOS:
 *
 *   1. dual-console  (symlink: henge-dual-console)
 *      Spawns a root login shell on a PTY, mirrors PL011 ttyAMA0 <-> /dev/tty1,
 *      announces "\x1b]9998;HENGE_HID_READY\x07", parses stateful OSC 9999 HID
 *      frames, and injects /dev/uinput Virtual Keyboard + Virtual Tablet events.
 *
 *   2. xdg-open      (symlink: henge-xdg-open, or xdg-open when absent)
 *      Routes http:// and https:// URLs to http://10.0.2.4/.henge/open-url
 *      (SFSafariViewController on iOS), auto-exposing loopback OAuth callback
 *      ports via PUT /.henge/expose-port, and delegates non-HTTP(S) URIs to
 *      /usr/bin/xdg-open with HENGE_XDG_FALLBACK=1 recursion protection.
 *
 *   3. clipboard     (symlink: henge-clipboard)
 *      Subcommands: get | set [text] | watch
 *      Bridges guest clipboard with http://10.0.2.4/.henge/clipboard.
 */
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define HENGE_AGENT_VERSION "0.2.0"
#define HENGE_DEFAULT_GATEWAY "10.0.2.4"
#define HENGE_GATEWAY_PORT 80

/* =========================================================================
 * Common I/O & Minimal HTTP/1.1 Client (10.0.2.4:80)
 * ========================================================================= */

static const char *gateway_host(void) {
    const char *env = getenv("HENGE_GATEWAY");
    return (env != NULL && env[0] != '\0') ? env : HENGE_DEFAULT_GATEWAY;
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

static int send_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0U) {
        ssize_t n = send(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (n == 0) {
            return -1;
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
    return 0;
}

static int connect_gateway(int timeout_sec) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct timeval tv;
    tv.tv_sec = timeout_sec;
    tv.tv_usec = 0;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(HENGE_GATEWAY_PORT);
    if (inet_pton(AF_INET, gateway_host(), &sa.sin_addr) != 1) {
        close(fd);
        return -1;
    }
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

typedef struct {
    int status_code;
    unsigned long henge_seq;
    char *body;
    size_t body_len;
} HttpResponse;

static int gateway_http(const char *method,
                        const char *path,
                        const char *body,
                        size_t body_len,
                        int timeout_sec,
                        HttpResponse *out) {
    memset(out, 0, sizeof(*out));
    int fd = connect_gateway(timeout_sec);
    if (fd < 0) {
        return -1;
    }

    char hdr[1024];
    int hlen = snprintf(hdr, sizeof(hdr),
                        "%s %s HTTP/1.1\r\n"
                        "Host: %s\r\n"
                        "Connection: close\r\n"
                        "Content-Length: %zu\r\n"
                        "\r\n",
                        method, path, gateway_host(), body_len);
    if (hlen <= 0 || (size_t)hlen >= sizeof(hdr)) {
        close(fd);
        return -1;
    }
    if (send_all(fd, hdr, (size_t)hlen) != 0) {
        close(fd);
        return -1;
    }
    if (body != NULL && body_len > 0U) {
        if (send_all(fd, body, body_len) != 0) {
            close(fd);
            return -1;
        }
    }

    size_t cap = 4096U;
    size_t len = 0U;
    char *buf = (char *)malloc(cap);
    if (buf == NULL) {
        close(fd);
        return -1;
    }

    for (;;) {
        if (len + 2048U >= cap) {
            if (cap >= (4U * 1024U * 1024U)) {
                break;
            }
            size_t next_cap = cap * 2U;
            char *grown = (char *)realloc(buf, next_cap);
            if (grown == NULL) {
                free(buf);
                close(fd);
                return -1;
            }
            buf = grown;
            cap = next_cap;
        }
        ssize_t n = recv(fd, buf + len, cap - len - 1U, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (n == 0) {
            break;
        }
        len += (size_t)n;
    }
    close(fd);
    buf[len] = '\0';

    if (len < 12U || strncmp(buf, "HTTP/1.", 7) != 0) {
        free(buf);
        return -1;
    }
    const char *sp = strchr(buf, ' ');
    if (sp == NULL) {
        free(buf);
        return -1;
    }
    out->status_code = atoi(sp + 1);

    const char *sep = strstr(buf, "\r\n\r\n");
    if (sep == NULL) {
        free(buf);
        return -1;
    }
    size_t hdr_bytes = (size_t)(sep - buf);
    const char *seq_hdr = strcasestr(buf, "X-Henge-Seq:");
    if (seq_hdr != NULL && (size_t)(seq_hdr - buf) < hdr_bytes) {
        seq_hdr += strlen("X-Henge-Seq:");
        while (*seq_hdr == ' ' || *seq_hdr == '\t') {
            seq_hdr++;
        }
        out->henge_seq = strtoul(seq_hdr, NULL, 10);
    }

    const char *bstart = sep + 4;
    size_t blen = len - (size_t)(bstart - buf);
    if (blen > 0U) {
        out->body = (char *)malloc(blen + 1U);
        if (out->body != NULL) {
            memcpy(out->body, bstart, blen);
            out->body[blen] = '\0';
            out->body_len = blen;
        }
    }
    free(buf);
    return 0;
}

/* =========================================================================
 * Subcommand 1: dual-console (PL011 <-> /dev/tty1 + OSC 9999 /dev/uinput)
 * ========================================================================= */

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

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    return -1;
}

static void handle_hid_frame(UinputState *u, int master_fd, const char *body, bool on_tty1) {
    if (body[0] == 'T' && body[1] == ' ') {
        if (!on_tty1 || master_fd < 0) {
            return;
        }
        uint8_t decoded[64];
        size_t dlen = 0U;
        const char *p = body + 2;
        while (p[0] != '\0' && p[1] != '\0' && dlen < sizeof(decoded)) {
            int hi = hex_nibble(p[0]);
            int lo = hex_nibble(p[1]);
            if (hi < 0 || lo < 0) {
                break;
            }
            decoded[dlen++] = (uint8_t)((hi << 4) | lo);
            p += 2;
        }
        if (dlen > 0U) {
            write_all(master_fd, decoded, dlen);
        }
        return;
    }
    if (on_tty1) {
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

static void read_pretty_os_name(char *out, size_t cap) {
    snprintf(out, cap, "HengeLinux ARM64");
    FILE *fp = fopen("/etc/os-release", "r");
    if (fp == NULL) {
        return;
    }
    char line[256];
    while (fgets(line, sizeof(line), fp) != NULL) {
        if (strncmp(line, "PRETTY_NAME=", 12) == 0) {
            char *p = line + 12;
            if (*p == '"' || *p == '\'') {
                p++;
            }
            size_t n = strlen(p);
            while (n > 0U && (p[n - 1U] == '\n' || p[n - 1U] == '\r' || p[n - 1U] == '"' || p[n - 1U] == '\'')) {
                p[--n] = '\0';
            }
            if (n > 0U) {
                snprintf(out, cap, "%s", p);
            }
            break;
        }
    }
    fclose(fp);
}

static void exec_root_shell(void) {
    setenv("HOME", "/root", 1);
    setenv("USER", "root", 1);
    setenv("LOGNAME", "root", 1);
    setenv("TERM", "linux", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    if (chdir("/root") != 0 && chdir("/") != 0) {
        /* Continue in inherited working directory if neither exists. */
    }
    char os_name[128];
    read_pretty_os_name(os_name, sizeof(os_name));
    char banner[256];
    int blen = snprintf(banner, sizeof(banner), "\r\n%s (HengeLinux) — root\r\n\r\n", os_name);
    if (blen > 0) {
        write_all(STDOUT_FILENO, banner, (size_t)blen);
    }
    if (access("/bin/bash", X_OK) == 0) {
        setenv("SHELL", "/bin/bash", 1);
        execl("/bin/bash", "-bash", "-i", (char *)NULL);
    }
    setenv("SHELL", "/bin/sh", 1);
    execl("/bin/sh", "-sh", "-i", (char *)NULL);
    _exit(127);
}

static int cmd_dual_console(void) {
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

    static const char kReadyBanner[] = "\x1b]9998;HENGE_HID_READY_V2\x07";
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
            tv.tv_usec = 50000;
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
            uint8_t esc = 0x1BU;
            write_all(master_fd, &esc, 1U);
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
                    } else if (pty_len < sizeof(pty_out)) {
                        pty_out[pty_len++] = b;
                    }
                } else if (st == ST_ESC) {
                    if (b == (uint8_t)']') {
                        st = ST_OSC_PREFIX;
                        prefix_len = 0U;
                    } else if (b == 0x1BU) {
                        if (pty_len < sizeof(pty_out)) {
                            pty_out[pty_len++] = 0x1BU;
                        }
                    } else {
                        if (pty_len + 2U <= sizeof(pty_out)) {
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
                        if (pty_len + 3U + prefix_len <= sizeof(pty_out)) {
                            pty_out[pty_len++] = 0x1BU;
                            pty_out[pty_len++] = (uint8_t)']';
                            for (size_t k = 0U; k < prefix_len; ++k) {
                                pty_out[pty_len++] = (uint8_t)kPrefix[k];
                            }
                            pty_out[pty_len++] = b;
                        }
                        st = ST_NORMAL;
                    }
                } else {
                    if (b == 0x07U) {
                        osc_body[osc_len] = '\0';
                        handle_hid_frame(&uinput, master_fd, osc_body, on_tty1);
                        st = ST_NORMAL;
                    } else if (osc_len + 1U < sizeof(osc_body)) {
                        osc_body[osc_len++] = (char)b;
                    } else {
                        st = ST_NORMAL;
                    }
                }
            }

            if (pty_len > 0U) {
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

/* =========================================================================
 * Subcommand 2: xdg-open (10.0.2.4/.henge/open-url + expose-port)
 * ========================================================================= */

static void auto_expose_loopback_ports(const char *url) {
    static const char *const kKeys[] = {
        "localhost:", "localhost%3A", "localhost%3a",
        "127.0.0.1:", "127.0.0.1%3A", "127.0.0.1%3a",
        "[::1]:", "%5B::1%5D%3A", "%5b::1%5d%3a"
    };
    for (size_t k = 0U; k < sizeof(kKeys) / sizeof(kKeys[0]); ++k) {
        const char *p = url;
        size_t klen = strlen(kKeys[k]);
        while ((p = strcasestr(p, kKeys[k])) != NULL) {
            p += klen;
            int port = atoi(p);
            if (port >= 1024 && port <= 65535) {
                char pstr[16];
                int n = snprintf(pstr, sizeof(pstr), "%d", port);
                if (n > 0) {
                    HttpResponse resp;
                    if (gateway_http("PUT", "/.henge/expose-port", pstr, (size_t)n, 5, &resp) == 0) {
                        free(resp.body);
                    }
                }
            }
        }
    }
}

static int cmd_xdg_open(int argc, char **argv) {
    if (argc < 2 || argv[1][0] == '\0') {
        fprintf(stderr, "usage: henge-xdg-open <url>\n");
        return 2;
    }
    const char *url = argv[1];
    bool is_http = (strncasecmp(url, "http://", 7) == 0 || strncasecmp(url, "https://", 8) == 0);
    if (!is_http) {
        if (getenv("HENGE_XDG_FALLBACK") == NULL && access("/usr/bin/xdg-open", X_OK) == 0) {
            setenv("HENGE_XDG_FALLBACK", "1", 1);
            const char *browser = getenv("BROWSER");
            if (browser != NULL && (strstr(browser, "henge-xdg-open") != NULL || strstr(browser, "henge-guest-agent") != NULL)) {
                unsetenv("BROWSER");
            }
            execl("/usr/bin/xdg-open", "xdg-open", url, (char *)NULL);
        }
        fprintf(stderr, "henge-xdg-open: non-HTTP(S) URI requires /usr/bin/xdg-open: %s\n", url);
        return 1;
    }

    auto_expose_loopback_ports(url);

    HttpResponse resp;
    if (gateway_http("PUT", "/.henge/open-url", url, strlen(url), 5, &resp) != 0) {
        fprintf(stderr, "henge-xdg-open: failed to reach HengeLinux gateway (%s)\n", gateway_host());
        return 1;
    }
    int status = resp.status_code;
    free(resp.body);
    if (status >= 200 && status < 300) {
        return 0;
    }
    fprintf(stderr, "henge-xdg-open: host returned HTTP %d\n", status);
    return 1;
}

/* =========================================================================
 * Subcommand 3: clipboard (get | set [text] | watch)
 * ========================================================================= */

static int read_stdin_all(char **out_buf, size_t *out_len) {
    size_t cap = 4096U;
    size_t len = 0U;
    char *buf = (char *)malloc(cap);
    if (buf == NULL) {
        return -1;
    }
    for (;;) {
        if (len + 2048U >= cap) {
            if (cap >= (2U * 1024U * 1024U)) {
                break;
            }
            size_t next_cap = cap * 2U;
            char *grown = (char *)realloc(buf, next_cap);
            if (grown == NULL) {
                free(buf);
                return -1;
            }
            buf = grown;
            cap = next_cap;
        }
        ssize_t n = read(STDIN_FILENO, buf + len, cap - len - 1U);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            free(buf);
            return -1;
        }
        if (n == 0) {
            break;
        }
        len += (size_t)n;
    }
    buf[len] = '\0';
    *out_buf = buf;
    *out_len = len;
    return 0;
}

static int cmd_clipboard(int argc, char **argv) {
    const char *action = (argc >= 2) ? argv[1] : "get";
    if (strcmp(action, "get") == 0) {
        HttpResponse resp;
        if (gateway_http("GET", "/.henge/clipboard?since=0", NULL, 0U, 5, &resp) != 0) {
            fprintf(stderr, "henge-clipboard: failed to reach gateway (%s)\n", gateway_host());
            return 1;
        }
        if (resp.status_code == 200 && resp.body != NULL && resp.body_len > 0U) {
            write_all(STDOUT_FILENO, resp.body, resp.body_len);
        }
        free(resp.body);
        return (resp.status_code == 200 || resp.status_code == 204) ? 0 : 1;
    }
    if (strcmp(action, "set") == 0) {
        char *buf = NULL;
        size_t len = 0U;
        if (argc >= 3) {
            len = strlen(argv[2]);
            buf = strdup(argv[2]);
        } else if (read_stdin_all(&buf, &len) != 0) {
            return 1;
        }
        if (buf == NULL) {
            return 1;
        }
        HttpResponse resp;
        int rc = gateway_http("PUT", "/.henge/clipboard", buf, len, 5, &resp);
        free(buf);
        if (rc != 0) {
            fprintf(stderr, "henge-clipboard: failed to push clipboard to gateway (%s)\n", gateway_host());
            return 1;
        }
        int status = resp.status_code;
        free(resp.body);
        return (status >= 200 && status < 300) ? 0 : 1;
    }
    if (strcmp(action, "watch") == 0) {
        unsigned long seq = 0UL;
        for (;;) {
            char path[64];
            snprintf(path, sizeof(path), "/.henge/clipboard?since=%lu", seq);
            HttpResponse resp;
            if (gateway_http("GET", path, NULL, 0U, 30, &resp) != 0) {
                sleep(2);
                continue;
            }
            if (resp.henge_seq > seq) {
                seq = resp.henge_seq;
            }
            if (resp.status_code == 200 && resp.body != NULL && resp.body_len > 0U) {
                write_all(STDOUT_FILENO, resp.body, resp.body_len);
                write_all(STDOUT_FILENO, "\n", 1U);
            }
            free(resp.body);
        }
    }
    fprintf(stderr, "usage: henge-clipboard [get | set [text] | watch]\n");
    return 2;
}

static void print_usage(void) {
    printf("henge-guest-agent %s — HengeLinux portable guest additions\n"
           "Usage:\n"
           "  henge-guest-agent dual-console          PL011 <-> tty1 mirror + OSC 9999 uinput HID\n"
           "  henge-guest-agent xdg-open <url>        Open HTTP(S) URL in iOS SafariSheet\n"
           "  henge-guest-agent clipboard <get|set|watch>\n"
           "  henge-guest-agent --version\n",
           HENGE_AGENT_VERSION);
}

int main(int argc, char **argv) {
    char *prog_copy = strdup((argc > 0 && argv[0] != NULL) ? argv[0] : "henge-guest-agent");
    const char *base = (prog_copy != NULL) ? basename(prog_copy) : "henge-guest-agent";

    if (strcmp(base, "henge-dual-console") == 0) {
        free(prog_copy);
        return cmd_dual_console();
    }
    if (strcmp(base, "henge-xdg-open") == 0 || strcmp(base, "xdg-open") == 0) {
        free(prog_copy);
        return cmd_xdg_open(argc, argv);
    }
    if (strcmp(base, "henge-clipboard") == 0) {
        free(prog_copy);
        return cmd_clipboard(argc, argv);
    }
    free(prog_copy);

    if (argc < 2 || strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        print_usage();
        return 0;
    }
    if (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-V") == 0) {
        printf("henge-guest-agent %s\n", HENGE_AGENT_VERSION);
        return 0;
    }
    if (strcmp(argv[1], "dual-console") == 0) {
        return cmd_dual_console();
    }
    if (strcmp(argv[1], "xdg-open") == 0) {
        return cmd_xdg_open(argc - 1, argv + 1);
    }
    if (strcmp(argv[1], "clipboard") == 0) {
        return cmd_clipboard(argc - 1, argv + 1);
    }

    fprintf(stderr, "henge-guest-agent: unknown subcommand '%s'\n", argv[1]);
    print_usage();
    return 2;
}
