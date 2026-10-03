/*
 * A stand-in for the claude binary, for tests/sh/relaunch_sh_test.sh.
 *
 * Built as $FAKE_DIR/bin/claude so its argv[0] basename is `claude`, the way
 * relaunch.sh spots the real one. Two roles, picked by argv[1]:
 *
 *   claude --resume ...   the new session: writes its argv (NUL separated),
 *                         cwd, and whether the old session was still alive
 *                         into $FAKE_DIR, then exits.
 *   claude <flags>        the old session: records its pid, runs the command
 *                         in $FAKE_DIR/relaunch.argv (NUL separated) as its
 *                         child, waits for it, stays up FAKE_LINGER_MS more
 *                         (as the real one does until /exit), then exits.
 *
 * FAKE_DIR comes from the environment, else from -DFAKE_DIR_DEFAULT.
 */

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef FAKE_DIR_DEFAULT
#define FAKE_DIR_DEFAULT "/tmp"
#endif

static char path_buf[4096];

static const char *in_dir(const char *dir, const char *name) {
    snprintf(path_buf, sizeof path_buf, "%s/%s", dir, name);
    return path_buf;
}

static void write_file(const char *dir, const char *name, const char *data, size_t len) {
    char tmp[4096];
    char final_path[4096];
    FILE *f;

    snprintf(final_path, sizeof final_path, "%s/%s", dir, name);
    snprintf(tmp, sizeof tmp, "%s.tmp", final_path);
    f = fopen(tmp, "wb");
    if (!f) {
        perror(tmp);
        exit(70);
    }
    fwrite(data, 1, len, f);
    fclose(f);
    rename(tmp, final_path);
}

static int resumed(const char *dir, int argc, char **argv) {
    char cwd[4096];
    char pid_text[64] = "";
    const char *alive = "unknown";
    FILE *f;
    size_t total = 0;
    char *buf;
    int i;

    if (!getcwd(cwd, sizeof cwd)) {
        strcpy(cwd, "?");
    }

    f = fopen(in_dir(dir, "launcher.pid"), "r");
    if (f) {
        if (fgets(pid_text, sizeof pid_text, f)) {
            pid_t old = (pid_t)atol(pid_text);
            if (old > 0) {
                alive = (kill(old, 0) == 0 || errno == EPERM) ? "alive" : "dead";
            }
        }
        fclose(f);
    }

    for (i = 1; i < argc; i++) {
        total += strlen(argv[i]) + 1;
    }
    buf = malloc(total + 1);
    total = 0;
    for (i = 1; i < argc; i++) {
        size_t n = strlen(argv[i]) + 1;
        memcpy(buf + total, argv[i], n);
        total += n;
    }

    write_file(dir, "resumed.cwd", cwd, strlen(cwd));
    write_file(dir, "resumed.alive", alive, strlen(alive));
    /* Last, so its presence means the other two are in place. */
    write_file(dir, "resumed.argv", buf, total);
    return 0;
}

static int launcher(const char *dir) {
    char pid_text[64];
    char *data = NULL;
    size_t len = 0;
    size_t cap = 0;
    char *child_argv[256];
    int child_argc = 0;
    size_t pos = 0;
    FILE *f;
    pid_t child;
    int status = 0;
    const char *linger = getenv("FAKE_LINGER_MS");

    snprintf(pid_text, sizeof pid_text, "%ld\n", (long)getpid());
    write_file(dir, "launcher.pid", pid_text, strlen(pid_text));

    f = fopen(in_dir(dir, "relaunch.argv"), "rb");
    if (!f) {
        perror("relaunch.argv");
        return 70;
    }
    for (;;) {
        size_t got;
        if (len == cap) {
            cap = cap ? cap * 2 : 4096;
            data = realloc(data, cap + 1);
        }
        got = fread(data + len, 1, cap - len, f);
        if (got == 0) {
            break;
        }
        len += got;
    }
    fclose(f);
    data[len] = '\0';

    while (pos < len && child_argc < 255) {
        child_argv[child_argc++] = data + pos;
        pos += strlen(data + pos) + 1;
    }
    child_argv[child_argc] = NULL;

    if (child_argc == 0) {
        fprintf(stderr, "fake claude: relaunch.argv is empty\n");
        return 70;
    }

    child = fork();
    if (child < 0) {
        perror("fork");
        return 70;
    }
    if (child == 0) {
        execvp(child_argv[0], child_argv);
        perror(child_argv[0]);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
    }

    if (linger && atol(linger) > 0) {
        usleep((useconds_t)(atol(linger) % 1000) * 1000);
        sleep((unsigned)(atol(linger) / 1000));
    }

    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

int main(int argc, char **argv) {
    const char *dir = getenv("FAKE_DIR");

    if (!dir || !*dir) {
        dir = FAKE_DIR_DEFAULT;
    }

    if (argc > 1 && strcmp(argv[1], "--resume") == 0) {
        return resumed(dir, argc, argv);
    }

    return launcher(dir);
}
