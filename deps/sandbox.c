/* Copyright (c) 2016 Julia Computing Inc */
#define _GNU_SOURCE

/* Seperate because the headers below don't have all dependencies properly
   declared */
#include <sys/socket.h>

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <linux/socket.h>
#include <linux/if.h>
#include <linux/in.h>
#include <linux/netlink.h>
#include <linux/route.h>
#include <linux/rtnetlink.h>
#include <linux/sockios.h>
#include <linux/veth.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>

/**** General Utilities ***/

/* Like assert, but don't go away with optimizations */
static void _check(int ok, int line) {
  if (!ok) {
    printf("At line %d, ABORTED (%s)!\n", line, strerror(errno));
    abort();
  }
}
#define check(ok) _check(ok, __LINE__)

/* Opens /proc/%pid/%file */
static int open_proc_file(pid_t pid, const char *file, int mode) {
  char path[100];
  int n = snprintf(path, sizeof(path), "/proc/%d/%s", pid, file);
  check(n >= 0 && n < sizeof(path));
  int fd = open(path, mode);
  check(fd != -1);
  return fd;
}

/**** 2: User namespaces
 *
 * For a general overview on user namespaces, see the corresponding manual page,
 * user_namespaces(7). In general, user namespaces allow unprivileged users to
 * run privileged executables, by rewriting uids inside the namespaces (and
 * in particular, a user can be root inside the namespace, but not outside),
 * with the kernel still enforcing, access protection as if the user was
 * unprivilged (to all files and resources not created exclusively within the
 * namespace). Absent kernel bugs, this provides relatively strong protections
 * against misconfiguration (because no true privilege is ever bestowed upon
 * the sandbox). It should be noted however, that there were such kernel bugs
 * as recently as Feb 2016, so it is imperative that this is run on a recent and
 * fully patched kernel.
 */
static void configure_user_namespace(pid_t pid) {
  int nbytes = 0;

  // Setup uid map
  int uidmap_fd = open_proc_file(pid, "uid_map", O_WRONLY);
  check(uidmap_fd != -1);
  char uidmap[100];
  nbytes = snprintf(uidmap, sizeof(uidmap), "0\t%d\t1", getuid());
  check(nbytes > 0 && nbytes <= sizeof(uidmap));
  check(write(uidmap_fd, uidmap, nbytes) == nbytes);
  close(uidmap_fd);

  // Deny setgroups
  int setgroups_fd = open_proc_file(pid, "setgroups", O_WRONLY);
  char deny[] = "deny";
  check(write(setgroups_fd, deny, sizeof(deny)) == sizeof(deny));
  close(setgroups_fd);

  // Setup gid map
  int gidmap_fd = open_proc_file(pid, "gid_map", O_WRONLY);
  check(gidmap_fd != -1);
  char gidmap[100];
  nbytes = snprintf(gidmap, sizeof(gidmap), "0\t%d\t1", getgid());
  check(nbytes > 0 && nbytes <= sizeof(gidmap));
  check(write(gidmap_fd, gidmap, nbytes) == nbytes);
}

char *initial_script =
    // Remount proc file system
    "/bin/busybox mount -t proc proc /proc\n"
    // Mount sandboxed pts devices
    "/bin/busybox mount -t devpts -o newinstance jrunpts /dev/pts\n"
    "/bin/busybox mount -o bind /dev/pts/ptmx /dev/ptmx\n";

// Options (gets filled in by driver code)
char *sandbox_root = NULL;
char *overlay = NULL;
char *overlay_workdir = NULL;
char *workspace = NULL;
char *new_cd = NULL;
unsigned char verbose = 0;

struct map_list {
    char *map_path;
    char *outside_path;
    struct map_list *prev;
};

struct map_list *maps;

/* Mount an overlayfs on "overlayfs_root", anchoring the changes within the
 * temporary folders within /proc/upper and /proc/work created by
 * sandbox_main()
 */
static void create_overlay(const char * overlay_root) {
    char upper_dir[PATH_MAX], work_dir[PATH_MAX], opts[3*PATH_MAX+40];
    const char * bname = basename(overlay_root);

    snprintf(upper_dir, sizeof(upper_dir), "/proc/upper/%s", bname);
    snprintf(work_dir, sizeof(work_dir), "/proc/work/%s", bname);
    snprintf(opts, sizeof(opts), "lowerdir=%s,upperdir=%s,workdir=%s",
             overlay_root, upper_dir, work_dir);

    if (verbose) {
        printf("--> Mounting overlay %s at %s\n", overlay_root, upper_dir);
    }

    check(0 == mkdir(upper_dir, 0777));
    check(0 == mkdir(work_dir, 0777));
    check(0 == mount("overlay", overlay_root, "overlay", 0, opts));
}

/* Sets up the jail, prepares the initial linux environment,
   then execs busybox */
static void sandbox_main(int sandbox_argc, char **sandbox_argv) {
  pid_t pid;
  int status;
  check(sandbox_root != NULL);

  /// Set up a temporary file system to use to hold all the upper dirs for our
  /// overlay.  We re-use /proc outside the chroot for this purpose, because
  /// it's a directory that is required to exist for the sandbox to work and
  /// is not otherwise accessed.
  check(0 == mount("tmpfs", "/proc", "tmpfs", 0, "size=1G"));
  check(0 == mkdir("/proc/upper", 0777));
  check(0 == mkdir("/proc/work", 0777));

  /// Mount the overlay filesystem for the "base" shard
  create_overlay(sandbox_root);
  chdir(sandbox_root);
  
  /// Setup the workspace
  if (workspace) {
    // We don't expect workspace to have any submounts in normal operation.
    // However, for runshell(), workspace could be an arbitrary directory,
    // including one with sub-mounts, so allow that situation.
    check(0 == mount(workspace, "workspace", "", MS_BIND|MS_REC, NULL));
  }

  /// Apply command-line specified mounts
  struct map_list *current_entry = maps;
  while (current_entry != NULL) {
      char *inside = current_entry->map_path;
      // Take the path relative to sandbox root (i.e. cwd)
      if (inside[0] == '/') {
          inside = inside + 1;
      }
      if (verbose) {
          printf("--> Mapping %s to %s\n", inside, current_entry->outside_path);
      }
      check(current_entry->outside_path[0] == '/' && "Outside path must be absolute");

      // Create the inside directory, if we need to
      DIR *d = opendir(inside);
      if (d == NULL) {
          check(0 == mkdir(inside, 0777));
      } else {
          closedir(d);
      }
      check(0 == mount(current_entry->outside_path, inside, "", MS_BIND, NULL));

      // Remount to read-only
      check(0 == mount(current_entry->outside_path, inside, "", MS_BIND|MS_REMOUNT|MS_RDONLY, NULL));

      // Slap an overlay on top to allow future changes
      create_overlay(inside);

      current_entry = current_entry->prev;
  }

  /// Bind host /dev/null in the sandbox
  check(0 == mount("/dev/null", "dev/null", "", MS_BIND, NULL));
  /// Enter chroot
  check(0 == chroot("."));
  if (new_cd) {
    check(0 == chdir(new_cd));
  }


  // Set up the environment
  if ((pid = fork()) == 0) {
    fflush(stdout);
    char *ie_argv[] = {"/bin/busybox", "sh", "-c", initial_script, 0};
    execve("/bin/busybox", ie_argv, environ);
    _exit(0);
  }
  check(pid > 1);
  check(pid == waitpid(pid, &status, 0));
  check(WIFEXITED(status));
  if (sandbox_argc == 0) {
    fflush(stdout);
    char *argv[] = {"/bin/busybox", "sh", 0};
    execve("/bin/busybox", argv, environ);
    fputs("ERROR: Busybox not installed!\n", stderr);
    _exit(1);
  } else {
    if (verbose) {
      printf("About to run `%s` ", sandbox_argv[0]);
      int argc_i;
      for( argc_i=1; argc_i<sandbox_argc; ++argc_i) {
        printf("`%s` ", sandbox_argv[argc_i]);
      }
      printf("\n");
    }
    fflush(stdout);
    execve(sandbox_argv[0], sandbox_argv, environ);
    fprintf(stderr, "ERROR: Failed to run %s!\n", sandbox_argv[0]);
    _exit(1);
  }
}

/******* Driver Code
 * Not much to see here, just putting it all together.
 */
static void sigint_handler() { _exit(0); }

int main(int sandbox_argc, char **sandbox_argv) {
  int status;
  pid_t pid;

  pid_t pgrp = getpgid(0);

  // Skip the wrapper
  sandbox_argv += 1;
  sandbox_argc -= 1;

  // Probably should replace this by proper argument parsing (or just make this a library)
  if (sandbox_argc >= 2 && strcmp(sandbox_argv[0], "--rootfs") == 0) {
    sandbox_root = strdup(sandbox_argv[1]);
    size_t sandbox_root_len = strlen(sandbox_root);
    if (sandbox_root[sandbox_root_len-1] == '/' ) {
        sandbox_root[sandbox_root_len-1] = '\0';
    }
    sandbox_argv += 2;
    sandbox_argc -= 2;
  }

  if (sandbox_argc >= 2 && strcmp(sandbox_argv[0], "--workspace") == 0) {
    workspace = strdup(sandbox_argv[1]);
    sandbox_argv += 2;
    sandbox_argc -= 2;
  }

  if (sandbox_argc >= 2 && strcmp(sandbox_argv[0], "--cd") == 0) {
    new_cd = strdup(sandbox_argv[1]);
    sandbox_argv += 2;
    sandbox_argc -= 2;
  }

  /* Syntax: --map outside:inside */
  while (sandbox_argc >= 2 && strcmp(sandbox_argv[0], "--map") == 0) {
    char *colon = strchr(sandbox_argv[1], ':');
    check(colon != NULL);
    struct map_list *entry = (struct map_list*)malloc(sizeof(struct map_list));
    entry->map_path = strdup(colon+1);
    entry->outside_path = strndup(sandbox_argv[1], (colon-sandbox_argv[1]));
    entry->prev = maps;
    maps = entry;
    sandbox_argv += 2;
    sandbox_argc -= 2;
  }

  if( sandbox_argc >= 1 && strcmp(sandbox_argv[0], "--verbose") == 0) {
    verbose = 1;
    sandbox_argv += 1;
    sandbox_argc -= 1;
  }

  if (sandbox_argc == 0 || !sandbox_root) {
    fputs("Usage: sandbox --rootfs <dir> [--workspace <dir>] ", stderr);
    fputs("[--cd <dir>] [--map <from>:<to>, ...] [--verbose] <cmd>\n", stderr);
    return 1;
  }

  // Use a pipe for synchronization. The regular SIGSTOP method does not work
  // because container-inits don't receive STOP or KILL signals from within
  // their own pid namespace.
  int child_block[2], parent_block[2];
  pipe(child_block);
  pipe(parent_block);

  if ((pid = syscall(SYS_clone, CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUSER | SIGCHLD,
                     0, 0, 0, 0)) == 0) {
    close(child_block[1]);
    close(parent_block[0]);
    // N.B: Capabilities in the original user namespaces are now dropped
    // The kernel may have decided to reset our dumpability, because of
    // the privilege change. However, the parent needs to access our /proc
    // entries (undumpable processes have /proc/%pid owned by root) in order
    // to configure the sandbox, so reset dumpability.
    prctl(PR_SET_DUMPABLE, 1, 0, 0, 0);

    // Make sure ^C actually kills this process. By default init ignores
    // all signals.
    signal(SIGINT, sigint_handler);

    // Tell the parent we're ready
    close(parent_block[1]);

    // This will block until the parent closes fds[1]
    check(0 == read(child_block[0], NULL, 1));

    sandbox_main(sandbox_argc, sandbox_argv);
    return -1;
  }
  close(child_block[0]);
  close(parent_block[1]);

  // Wait until the child is ready to be configured.
  check(0 == read(parent_block[0], NULL, 1));

  if (verbose) {
    printf("Child Process PID is %d\n", pid);
  }

  configure_user_namespace(pid);

  // Resume the child
  close(child_block[1]);
  // Wait until the child exits.
  check(pid == waitpid(pid, &status, 0));
  check(WIFEXITED(status));

  if (verbose) {
      printf("Child Process exited, exit code %d\n", WEXITSTATUS(status));
  }

  // Delete (empty) work directory
  {
      char work_dir_path[PATH_MAX];
      sprintf(&work_dir_path[0], "%s/work", overlay_workdir);
      rmdir(&work_dir_path[0]);
  }

  // Give back the terminal to the parent
  signal(SIGTTOU, SIG_IGN);
  tcsetpgrp(0, pgrp);

  // Return the error code of the child
  return WEXITSTATUS(status);
}
