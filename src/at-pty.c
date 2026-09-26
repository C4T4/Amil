/* Tiny PTY holder. Survives ATerminal crashing: we keep the master fd
   open and hand a duplicate to the UI over a unix socket (SCM_RIGHTS). */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static int send_fd(int sock, int fd) {
    char dummy = 0;
    struct iovec iov = { .iov_base = &dummy, .iov_len = 1 };
    char buf[CMSG_SPACE(sizeof(int))];
    memset(buf, 0, sizeof(buf));
    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = buf;
    msg.msg_controllen = sizeof(buf);
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof(int));
    return sendmsg(sock, &msg, 0) < 0 ? -1 : 0;
}

static int listen_unix(const char *path) {
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int clo = fcntl(fd, F_GETFD, 0);
    if (clo >= 0) fcntl(fd, F_SETFD, clo | FD_CLOEXEC);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    size_t n = strlen(path);
    if (n >= sizeof(addr.sun_path)) {
        close(fd);
        return -1;
    }
    memcpy(addr.sun_path, path, n + 1);
    addr.sun_len = (unsigned char)(2 + n + 1);
    if (bind(fd, (struct sockaddr *)&addr, addr.sun_len) != 0) {
        close(fd);
        return -1;
    }
    chmod(path, 0600);
    if (listen(fd, 4) != 0) {
        close(fd);
        unlink(path);
        return -1;
    }
    return fd;
}

static void write_pid(const char *sock, pid_t pid) {
    char path[512];
    snprintf(path, sizeof(path), "%s.pid", sock);
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%d\n", (int)pid);
    fclose(f);
    chmod(path, 0600);
}

int at_pty_main(int argc, char **argv) {
    const char *cwd = NULL;
    const char *sock = NULL;
    int cols = 80, rows = 24;
    int dash = -1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) {
            dash = i;
            break;
        }
        if (strcmp(argv[i], "--cwd") == 0 && i + 1 < argc) cwd = argv[++i];
        else if (strcmp(argv[i], "--sock") == 0 && i + 1 < argc) sock = argv[++i];
        else if (strcmp(argv[i], "--cols") == 0 && i + 1 < argc) cols = atoi(argv[++i]);
        else if (strcmp(argv[i], "--rows") == 0 && i + 1 < argc) rows = atoi(argv[++i]);
    }
    if (!sock || dash < 0 || dash + 1 >= argc) {
        fprintf(stderr, "at-pty --cwd DIR --sock PATH --cols N --rows N -- cmd args\n");
        return 2;
    }
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    setsid();

    struct winsize ws = { .ws_col = (unsigned short)cols, .ws_row = (unsigned short)rows };
    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, &ws);
    if (child < 0) return 1;
    if (child == 0) {
        if (cwd && cwd[0]) chdir(cwd);
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("LANG", "en_US.UTF-8", 1);
        execvp(argv[dash + 1], argv + dash + 1);
        dprintf(STDERR_FILENO, "at-pty: %s: %s\n", argv[dash + 1], strerror(errno));
        _exit(127);
    }
    int lfd = listen_unix(sock);
    if (lfd < 0) {
        kill(child, SIGTERM);
        return 1;
    }
    write_pid(sock, getpid());
    for (;;) {
        int st = 0;
        pid_t w = waitpid(child, &st, WNOHANG);
        if (w == child) break;
        struct pollfd p = { .fd = lfd, .events = POLLIN };
        int n = poll(&p, 1, 250);
        if (n > 0 && (p.revents & POLLIN)) {
            int cfd = accept(lfd, NULL, NULL);
            if (cfd >= 0) {
                send_fd(cfd, master);
                close(cfd);
            }
        }
    }
    close(master);
    close(lfd);
    unlink(sock);
    char pidpath[512];
    snprintf(pidpath, sizeof(pidpath), "%s.pid", sock);
    unlink(pidpath);
    return 0;
}
