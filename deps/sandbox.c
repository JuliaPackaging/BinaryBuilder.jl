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
#include <sys/reboot.h>
#include <linux/reboot.h>
#include <linux/limits.h>
#include <getopt.h>

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
static void create_overlay(const char * overlay_root, const char *mount_point,
                           const char * bname) {
    char upper_dir[PATH_MAX], work_dir[PATH_MAX], opts[3*PATH_MAX+40];
    if (!bname) {
        bname = basename(overlay_root);
    }
    if (!mount_point) {
        mount_point = overlay_root;
    }

    snprintf(upper_dir, sizeof(upper_dir), "/proc/upper/%s", bname);
    snprintf(work_dir, sizeof(work_dir), "/proc/work/%s", bname);
    snprintf(opts, sizeof(opts), "lowerdir=%s,upperdir=%s,workdir=%s",
             overlay_root, upper_dir, work_dir);

    if (verbose) {
        printf("--> Mounting overlay of %s at %s (modifications in %s)\n", overlay_root, mount_point, upper_dir);
    }

    check(0 == mkdir(upper_dir, 0777));
    check(0 == mkdir(work_dir, 0777));
    check(0 == mount("overlay", mount_point, "overlay", 0, opts));
}

/* This is the main pid. We exit the sandbox once this pid dies */
pid_t main_pid;

/*
 * We support running this binary either standalone (which will create a
 * user namespace sandbox) or as init inside a VM.
 */
static int is_init;

static void early_fs_mount() {
  check(0 == mount("proc", "/proc", "proc", 0, ""));
}

static void devtempfs_mount() {
  check(0 == mount("devtmpfs", "dev", "devtmpfs", 0, ""));
  check(0 == mkdir("dev/pts", 0600));
  //int fd = open("dev/ptmx", O_CREAT);
  //check(fd != -1);
  //check(0 == close(fd));
}

static void all_fs_mount() {
  early_fs_mount();
  //check(0 == mount("sandboxpts", "/dev/pts", "devpts", 0, "newinstance"));
  //check(0 == mount("/dev/pts/ptmx", "/dev/ptmx", "", MS_BIND, NULL));
}

/* Sets up the jail, prepares the initial linux environment,
   then execs busybox */
static int sandbox_main(int sandbox_argc, char **sandbox_argv) {
  pid_t pid;
  int status;
  check(is_init || sandbox_root != NULL);

  /// Set up a temporary file system to use to hold all the upper dirs for our
  /// overlay.  We re-use /proc outside the chroot for this purpose, because
  /// it's a directory that is required to exist for the sandbox to work and
  /// is not otherwise accessed.
  check(0 == mount("tmpfs", "/proc", "tmpfs", 0, "size=1G"));
  check(0 == mkdir("/proc/upper", 0777));
  check(0 == mkdir("/proc/work", 0777));

  char *rootfs_mount_point = sandbox_root;
  if (is_init) {
    sandbox_root = "/";
    rootfs_mount_point = "/proc";
    create_overlay("/", "/tmp", "root");
    chdir("/tmp");
  } else {
    create_overlay(sandbox_root, NULL, NULL);
    chdir(sandbox_root);
  }

  /// Setup the workspace
  if (workspace) {
    // If the workspace is specified as 9p:, try to mount it as a 9p share
    if (strncmp("9p:", workspace, 3) == 0) {
      check(0 == mount(workspace+3, "workspace", "9p", 0, "trans=virtio,version=9p2000.L"));
    } else {
      // We don't expect workspace to have any submounts in normal operation.
      // However, for runshell(), workspace could be an arbitrary directory,
      // including one with sub-mounts, so allow that situation.
      check(0 == mount(workspace, "workspace", "", MS_BIND|MS_REC, NULL));
    }
  }

  // In a VM, we may have to mount devices
  if (is_init) {
     devtempfs_mount();
  } else {
     /// Bind host /dev/null in the sandbox
     check(0 == mount("/dev/null", "dev/null", "", MS_BIND, NULL));
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
      check((current_entry->outside_path[0] == '/' ||
            strncmp(current_entry->outside_path, "9p/", 3) == 0) && "Outside path must be absolute or 9p");

      // Create the inside directory, if we need to
      DIR *d = opendir(inside);
      if (d == NULL) {
          check(0 == mkdir(inside, 0777));
      } else {
          closedir(d);
      }

      // If specified as a device, mount as squashfs
      if (strncmp(current_entry->outside_path, "/dev", 4) == 0) {
          check(0 == mount(current_entry->outside_path, inside, "squashfs", 0, ""));
      } else if (strncmp(current_entry->outside_path, "9p/", 3) == 0) {
          check(0 == mount(current_entry->outside_path+3, inside, "9p", MS_RDONLY, "trans=virtio,version=9p2000.L"));
      } else {
          check(0 == mount(current_entry->outside_path, inside, "", MS_BIND, NULL));
          // Remount to read-only
          check(0 == mount(current_entry->outside_path, inside, "", MS_BIND|MS_REMOUNT|MS_RDONLY, NULL));
      }

      // Slap an overlay on top to allow future changes
      create_overlay(inside, NULL, NULL);

      current_entry = current_entry->prev;
  }

  /// Enter chroot
  check(0 == chroot("."));

  if (new_cd) {
    check(0 == chdir(new_cd));
  }

  // Set up the environment
  all_fs_mount();
  fflush(stdout);

  if ((main_pid = fork()) == 0) {
    if (sandbox_argc == 0) {
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

  // Let's perform normal init functions, handling signals from orphaned
  // children, etc
  sigset_t waitset;
  sigemptyset(&waitset);
  sigaddset(&waitset, SIGCHLD);
  sigprocmask(SIG_BLOCK, &waitset, NULL);
  for (;;) {
    int sig;
    sigwait(&waitset, &sig);
    size_t reaped_pid;
    while ((reaped_pid = waitpid(-1, &status, WNOHANG)) != -1) {
      if (reaped_pid == main_pid) {
        // If it was the main pid that exited, return as well.
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
      }
    }
  }
}

static void print_help() {
  fputs("Usage: sandbox --rootfs <dir> [--workspace <dir>] ", stderr);
  fputs("[--cd <dir>] [--map <from>:<to>, --map <from>:<to>, ...] ", stderr);
  fputs("[--verbose] [--help] <cmd>\n", stderr);
}

static void read_sandbox_args(int fd, int * argc, char *** argv) {
  // First, read the number of sandbox args:
  *argc = 0;
  check(4 == read(fd, argc, sizeof(int)));
  check(*argc > 0);

  // We need to pretend that argv[0] is "sandbox"
  *argc += 1;

  // Allocate and read in those args
  *argv = malloc(sizeof(char *) * (*argc));
  (*argv)[0] = "/sandbox";
  int arg_idx;
  for( arg_idx=1; arg_idx<(*argc); ++arg_idx ) {
    int arg_len = 0;
    check(4 == read(fd, &arg_len, sizeof(int)));

    (*argv)[arg_idx] = malloc(arg_len + 1);
    check(arg_len == read(fd, (*argv)[arg_idx], arg_len));
    (*argv)[arg_idx][arg_len] = '\0';
  }
}

static void read_sandbox_env(int fd) {
  clearenv();
  int num_env_mappings = 0;
  check(4 == read(fd, &num_env_mappings, sizeof(int)));

  if (verbose) {
    printf("Reading %d environment mappings\n", num_env_mappings);
  }

  int env_buff_len = 1024;
  char * env_buff = malloc(env_buff_len + 1);
  int arg_idx;
  for( arg_idx=0; arg_idx<num_env_mappings; ++arg_idx ) {
    int arg_len = 0;
    check(4 == read(fd, &arg_len, sizeof(int)));

    // We guess that each environment mapping will be 1K or less,
    // but if we're wrong, bump the buffer size up.
    if( arg_len > env_buff_len) {
      env_buff_len = arg_len;
      env_buff = realloc(env_buff, env_buff_len + 1);
    }

    // Read the environment mapping into env_buff
    check(arg_len == read(fd, env_buff, arg_len));
    env_buff[arg_len] = '\0';

    // Find `=`, use it to chop env_buff in half,
    char * equals = strchr(env_buff, '=');
    check(equals != NULL);
    equals[0] = '\0';

    // Grab our name and value, feed that into setenv():
    setenv(env_buff, equals + 1, 1);
  }
  free(env_buff);
}

/******* Driver Code
 * Not much to see here, just putting it all together.
 */
static void sigint_handler() { _exit(0); }

int main(int sandbox_argc, char **sandbox_argv) {
  int status;
  pid_t mypid = getpid();
  pid_t pgrp = getpgid(0);
  is_init = mypid == 1;
  int cmdline_fd = -1;

  if (is_init) {
    // Mount our file systems right away so we can start using them
    early_fs_mount();

    // Extract our command line from the second serial device created by BinaryBuilder.jl
    cmdline_fd = open("/dev/vport1p1", O_RDONLY);
    check(cmdline_fd != -1);
    read_sandbox_args(cmdline_fd, &sandbox_argc, &sandbox_argv);
  } else {
    // Skip the wrapper
    sandbox_argv += 1;
    sandbox_argc -= 1;
  }

  // Parse out options
  while(1) {
    static struct option long_options[] = {
      {"help",      no_argument,       NULL, 'h'},
      {"verbose",   no_argument,       NULL, 'v'},
      {"rootfs",    required_argument, NULL, 'r'},
      {"workspace", required_argument, NULL, 'w'},
      {"cd",        required_argument, NULL, 'c'},
      {"map",       required_argument, NULL, 'm'},
      {0, 0, 0, 0}
    };

    int opt_idx;
    int c = getopt_long(sandbox_argc, sandbox_argv, "", long_options, &opt_idx);

    // End of options
    if( c == -1 )
      break;

    switch( c ) {
      case 'h':
        print_help();
        return 0;
      case 'v':
        verbose = 1;
        printf("verbose sandbox enabled\n");
        break;
      case 'r': {
        sandbox_root = strdup(optarg);
        size_t sandbox_root_len = strlen(sandbox_root);
        if (sandbox_root[sandbox_root_len-1] == '/' ) {
            sandbox_root[sandbox_root_len-1] = '\0';
        }
        if (verbose) {
          printf("Parsed --rootfs as \"%s\"\n", sandbox_root);
        }
      } break;
      case 'w':
        workspace = strdup(optarg);
        if (verbose) {
          printf("Parsed --workspace as \"%s\"\n", workspace);
        }
        break;
      case 'c':
        new_cd = strdup(optarg);
        if (verbose) {
          printf("Parsed --cd as \"%s\"\n", new_cd);
        }
        break;
      case 'm': {
        // Find the colon in "from:to"
        char *colon = strchr(optarg, ':');
        check(colon != NULL);
        struct map_list *entry = (struct map_list *) malloc(sizeof(struct map_list));

        // Extract "from" and "to"
        entry->map_path = strdup(colon + 1);
        entry->outside_path = strndup(optarg, (colon - optarg));
        entry->prev = maps;
        maps = entry;
        if (verbose) {
          printf("Parsed --map as \"%s\" -> \"%s\"\n", entry->outside_path, entry->map_path);
        }
      } break;
      case '?':
        print_help();
        return 1;
      default:
        fputs("getoptlong defaulted?!\n", stderr);
        return 1;
    }
  }

  // Skip past those arguments
  sandbox_argv += optind;
  sandbox_argc -= optind;

  // If we don't have a command, die
  if (sandbox_argc == 0 ) {
    fputs("No <cmd> given!\n", stderr);
    print_help();
    return 1;
  }

  // If we're not init but we haven't been given a sandbox root, die
  if (!is_init && !sandbox_root) {
    fputs("--rootfs is required, unless running as init!\n", stderr);
    print_help();
    return 1;
  }

  // If we have a cmdline_fd, then pull out the environment from it now
  if( cmdline_fd != -1 ) {
    read_sandbox_env(cmdline_fd);
  }

  // If we are running as init, run sandbox_main then reboot
  if (is_init) {
    setsid();
    ioctl(0, TIOCSCTTY, 1);
    sandbox_main(sandbox_argc, sandbox_argv);
	  sync();

    // Goodnight, my sweet prince
    check(0 == reboot(RB_POWER_OFF));

    // This is never reached, but it's nice for completionism
    return 0;
  }


  // Use a pipe for synchronization. The regular SIGSTOP method does not work
  // because container-inits don't receive STOP or KILL signals from within
  // their own pid namespace.
  int child_block[2], parent_block[2];
  pipe(child_block);
  pipe(parent_block);

  pid_t pid;
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

    return sandbox_main(sandbox_argc, sandbox_argv);
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
