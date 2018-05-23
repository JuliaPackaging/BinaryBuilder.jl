/* Copyright (c) 2017 Julia Computing Inc */
#define _GNU_SOURCE

/*
  sandbox.c - Combination sandbox execution platform and init replacement

This file serves as the entrypoint into our sandboxed/virtualized execution environment for
BinaryBuilder.jl; it has three execution modes:

  1) Unprivileged container mode.
  2) Privileged container mode.
  3) Init mode.

Each mode does similar things, but in a different order and with different privileges. Eventually,
all modes seek the same result; to run a user program with the base root fs and any other shards
requested by the user within the BinaryBuilder.jl execution environment. We will walk through the
three modes here, to explain what each does.

* Unprivileged container mode is the "normal" mode of execution; it attempts to use the native
kernel namespace abilities to setup its environment without ever needing to be `root`. It does this
by creating a user namespace, then using its root privileges within the namespace to mount the
necesary shards, `chroot`, etc... within the right places in the new mount namespace created within
the container.

* Privileged container mode is what happens when `sandbox` is invoked with EUID == 0.  In this
mode, the mounts and chroots and whatnot are performed _before_ creating a new user namespace.
This is used as a workaround for kernels that do not have the capabilities for creating mounts
within user namespaces.  Arch Linux is a great example of this.

Init mode is used when `sandbox` is invoked with PID == 1.  In this mode, some extra work needs to
happen first as this sandbox is the first user program running on a virtualized system, e.g. inside
of QEMU, and it needs to setup the plan 9 filesystem mounts and whatnot.  There is no
containerization or namespaces that happen in this mode.


To test this executable, compile it with:

    gcc -std=c99 -o /tmp/sandbox ./sandbox.c

Then run it, mounting in a rootfs with a workspace and a single map:

    BB=$(echo ~/.julia/v0.6/BinaryBuilder/deps)
    P=/usr/local/bin:/usr/bin:/bin:/opt/x86_64-linux-gnu/bin
    mkdir -p /tmp/workspace
    PATH=$P /tmp/sandbox --verbose --rootfs $BB/root --workspace /tmp/workspace:/workspace --cd /workspace --map $BB/shards/x86_64-linux-gnu:/opt/x86_64-linux-gnu /bin/bash
*/


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

/**** Global Variables ***/

// TODO: NABIL: Explain what these are better
char *sandbox_root = NULL;
char *new_cd = NULL;
unsigned char verbose = 0;

// Linked list of volume mappings
struct map_list {
    char *map_path;
    char *outside_path;
    struct map_list *prev;
};
struct map_list *maps;
struct map_list *workspaces;

// This keeps track of our execution mode
enum {
  UNPRIVILEGED_CONTAINER_MODE,
  PRIVILEGED_CONTAINER_MODE,
  INIT_MODE,
};
static int execution_mode;



/**** General Utilities ***/

/* Like assert, but don't go away with optimizations */
static void _check(int ok, int line) {
  if (!ok) {
    fprintf(stderr, "At line %d, ABORTED (%s)!\n", line, strerror(errno));
    abort();
  }
}
#define check(ok) _check(ok, __LINE__)

/* Opens /proc/%pid/%file */
static int open_proc_file(pid_t pid, const char *file, int mode) {
  char path[PATH_MAX];
  int n = snprintf(path, sizeof(path), "/proc/%d/%s", pid, file);
  check(n >= 0 && n < sizeof(path));
  int fd = open(path, mode);
  check(fd != -1);
  return fd;
}

/* `touch` a file; create it if it doesn't already exist. */
static void touch(const char * path) {
  int fd = open(path, O_RDONLY | O_CREAT, S_IRUSR | S_IRGRP | S_IROTH);
  close(fd);
}

/**** 2: User namespaces
 *
 * For a general overview on user namespaces, see the corresponding manual page
 * user_namespaces(7). In general, user namespaces allow unprivileged users to
 * run privileged executables, by rewriting uids inside the namespaces (and
 * in particular, a user can be root inside the namespace, but not outside),
 * with the kernel still enforcing access protection as if the user was
 * unprivilged (to all files and resources not created exclusively within the
 * namespace). Absent kernel bugs, this provides relatively strong protections
 * against misconfiguration (because no true privilege is ever bestowed upon
 * the sandbox). It should be noted however, that there were such kernel bugs
 * as recently as Feb 2016.  These were sneaky privilege escalation bugs,
 * rather unimportant to the use case of BinaryBuilder, but a recent and fully
 * patched kernel should be considered essential for any security-sensitive
 * work done on top of this infrastructure).
 */
static void configure_user_namespace(uid_t uid, gid_t gid, pid_t pid) {
  int nbytes = 0;

  if (verbose) {
    printf("--> Mapping %d:%d to root:root within container namespace\n", uid, gid);
  }

  // Setup uid map
  int uidmap_fd = open_proc_file(pid, "uid_map", O_WRONLY);
  check(uidmap_fd != -1);
  char uidmap[100];
  nbytes = snprintf(uidmap, sizeof(uidmap), "0\t%d\t1", uid);
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
  nbytes = snprintf(gidmap, sizeof(gidmap), "0\t%d\t1", gid);
  check(nbytes > 0 && nbytes <= sizeof(gidmap));
  check(write(gidmap_fd, gidmap, nbytes) == nbytes);
}


/*
 * Mount an overlayfs from `src` onto `dest`, anchoring the changes made to the overlayfs
 * within the folders `root_dir`/upper and `root_dir`/work.  Note that the common case of
 * `src` == `dest` signifies that we "shadow" the original source location and will simply
 * discard any changes made to it when the overlayfs disappears.  This is how we protect our
 * rootfs and shards when mounting from a local filesystem, as well as how we convert a
 * read-only rootfs and shards to a read-write system when mounting from squashfs images.
 */
static void mount_overlay(const char * src, const char * dest, const char * bname,
                          const char * work_dir, uid_t uid, gid_t gid) {
  char upper[PATH_MAX], work[PATH_MAX], opts[3*PATH_MAX+28];

  // Construct the location of our upper and work directories
  snprintf(upper, sizeof(upper), "%s/upper/%s", work_dir, bname);
  snprintf(work, sizeof(work), "%s/work/%s", work_dir, bname);

  // If `src` is "", we actually want it to be "/", so adapt here because this is the
  // only place in the code base where we actually need the slash at the end of the
  // directory name.
  if (src[0] == '\0') {
    src = "/";
  }

  if (verbose) {
    printf("--> Mounting overlay of %s at %s (modifications in %s)\n", src, dest, upper);
  }

  // Make the upper and work directories
  check(0 == mkdir(upper, 0777));
  check(0 == mkdir(work, 0777));

  // Construct the opts, mount the overlay
  snprintf(opts, sizeof(opts), "lowerdir=%s,upperdir=%s,workdir=%s", src, upper, work);
  check(0 == mount("overlay", dest, "overlay", 0, opts));

  // Chown this directory to the desired UID/GID, so that it doesn't look like it's
  // owned by "nobody" when we're inside the sandbox
  check(0 == chown(dest, uid, gid));
}

static void mount_overlaywork(const char * work_dir) {
  char path[PATH_MAX];

  if (verbose) {
    printf("--> Creating overlay workdir at %s\n", work_dir);
  }
  check(0 == mount("tmpfs", work_dir, "tmpfs", 0, "size=1G"));

  // Create "upper" and "work" directories within this temporary filesystem
  // to hold the modifications and temporary data the overlayfs filesystems
  // will require.  We don't care about these modifications, because these
  // are the modifications that will be created by misbehaving programs that
  // install things into the root directory (or other shards).  The actual
  // workspace overlayfs will have a different upper/work setup.
  snprintf(path, sizeof(path), "%s/upper", work_dir);
  check(0 == mkdir(path, 0777));
  snprintf(path, sizeof(path), "%s/work", work_dir);
  check(0 == mkdir(path, 0777));
}

static void mount_procfs(const char * root_dir) {
  char path[PATH_MAX];

  // Mount procfs at /proc
  snprintf(path, sizeof(path), "%s/proc", root_dir);
  if (verbose) {
    printf("--> Mounting procfs at %s\n", path);
  }
  check(0 == mount("proc", path, "proc", 0, ""));
}

/*
 * We use this method to get /dev in shape.  If we're running as init, we need to
 * mount full-blown devtmpfs at /dev.  If we're just a sandbox, we only bindmount
 * /dev/null into our root_dir.
 */
static void mount_dev(const char * root_dir) {
  char path[PATH_MAX];

  // Mount devtmps at /dev
  if (execution_mode == INIT_MODE) {
    snprintf(path, sizeof(path), "%s/dev", root_dir);
    if (verbose) {
      printf("--> Mounting /dev at %s\n", path);
    }
    check(0 == mount("devtmpfs", path, "devtmpfs", 0, ""));

    // Create /dev/pts directory
    snprintf(path, sizeof(path), "%s/dev/pts", root_dir);
    check(0 == mkdir(path, 0600));
  } else {
    // Bindmount /dev/null into our root_dir
    snprintf(path, sizeof(path), "%s/dev/null", root_dir);
    if (verbose) {
      printf("--> Mounting /dev/null at %s\n", path);
    }
    touch(path);
    check(0 == mount("/dev/null", path, "", MS_BIND, NULL));

    // If the host has a /dev/urandom, expose that to the sandboxed process as well.
    if (access("/dev/urandom", F_OK) == 0) {
      snprintf(path, sizeof(path), "%s/dev/urandom", root_dir);

      if (verbose) {
        printf("--> Mounting /dev/urandom at %s\n", path);
      }

      // Bind-mount /dev/urandom to internal /dev/urandom (creating it if it doesn't already exist)
      touch(path);
      check(0 == mount("/dev/urandom", path, "", MS_BIND, NULL));
    }
  }
}

static void mount_workspaces(struct map_list * workspaces, const char * dest) {
  char path[PATH_MAX];

  // Apply command-line specified workspace mounts
  struct map_list *current_entry = workspaces;
  while( current_entry != NULL ) {
    char *inside = current_entry->map_path;

    // take the path relative to root_dir
    while (inside[0] == '/') {
      inside = inside + 1;
    }
    snprintf(path, sizeof(path), "%s/%s", dest, inside);

    // map <inside> to the given outside path
    if (verbose) {
      printf("--> workspacing %s to %s\n", current_entry->outside_path, path);
    }

    // create the inside directory, not freaking out if it already exists.
    int result = mkdir(path, 0777);
    check((0 == result) || (errno == EEXIST));

    if (strncmp("9p/", current_entry->outside_path, 3) == 0) {
      // If we're running as init within QEMU, the workspace is a plan 9 mount
      check(0 == mount(current_entry->outside_path+3, path, "9p", 0, "trans=virtio,version=9p2000.L"));
    } else {
      // We don't expect workspace to have any submounts in normal operation.
      // However, for runshell(), workspace could be an arbitrary directory,
      // including one with sub-mounts, so allow that situation.
      check(0 == mount(current_entry->outside_path, path, "", MS_BIND | MS_REC, NULL));
    }

    current_entry = current_entry->prev;
  }
}

/*
 * This will mount the rootfs and shards within the given root directory.
 * `root_dir`  is the path where the rootfs is mounted on the outside.
 * `dest` is the path where the roofs and all should be mounted
 * `shard_maps` is the list of mappings that we've been told to mount.
 */
static void mount_rootfs_and_shards(const char * root_dir, const char * dest,
                                    const char * work_dir, struct map_list * shard_maps,
                                    uid_t uid, gid_t gid) {
  // The first thing we do is create an overlay mounting sandbox_root into our root_dir.
  // The meaning of this is different across our different execution modes:
  //  * Init mode: root_dir is "/", dest is "/tmp" because we need a read-writeable
  //    rootfs, but it's already mounted as our root.
  //  * Privileged mode: root_dir is the path to the already loopback-mounted rootfs
  //    image, we are mounting it as an overlay within `dest`, a new directory that we
  //    will chroot into, then clone ourselves into a userns within.
  //  * Unprivileged mode: root_dir is the path to the already loopback-mounted rootfs
  //    image, we are mounting it as an overlay within `dest`, a new directory that we
  //    have already entered into within a userns.
  mount_overlay(root_dir, dest, "rootfs", work_dir, uid, gid);

  // We're definitely gonna do some path manipulation
  char path[PATH_MAX];

  /// Apply command-line specified mounts
  struct map_list *current_entry = shard_maps;
  while (current_entry != NULL) {
    char *inside = current_entry->map_path;

    // take the path relative to root_dir
    while (inside[0] == '/') {
      inside = inside + 1;
    }
    snprintf(path, sizeof(path), "%s/%s", dest, inside);

    // map <inside> to the given outside path
    if (verbose) {
      printf("--> mapping %s to %s\n", current_entry->outside_path, path);
    }

    // create the inside directory, not freaking out if it already exists.
    int result = mkdir(path, 0777);
    check((0 == result) || (errno == EEXIST));

    if (strncmp(current_entry->outside_path, "/dev", 4) == 0) {
      // if we're running on qemu, we pass mounts in as virtual devices, which we
      // know are always passed-through .squashfs files.
      check(0 == mount(current_entry->outside_path, path, "squashfs", 0, ""));
    } else if (strncmp(current_entry->outside_path, "9p/", 3) == 0) {
      // if we're running on qemu, we pass in mappings as plan 9 shares
      check(0 == mount(current_entry->outside_path+3, path, "9p", MS_RDONLY, "trans=virtio,version=9p2000.L"));
    } else {
      // if it's a normal directory, just bind mount it in
      check(0 == mount(current_entry->outside_path, path, "", MS_BIND, NULL));

      // remount to read-only, nodev, suid.
      // we only really care about read-only, but we need to make sure
      // to be stricter than our parent mount. if the parent mount is
      // noexec, we're out of luck, since we do need to execute these
      // files. however, we don't really have a need for suid (only one
      // uid) or device files (none in the image), so passing those extra
      // flags is harmless. if, we ever cared in the future, the thing
      // to do would be to read /proc/self/fdinfo or the directory, find
      // the mnt_id and extract the correct flags from /proc/self/mountinfo.
      check(0 == mount(current_entry->outside_path, path, "",
                       MS_BIND|MS_REMOUNT|MS_RDONLY|MS_NODEV|MS_NOSUID, NULL));
    }

    // Slap an overlay on top of the inside mapping to allow future changes
    mount_overlay(path, path, basename(path), work_dir, uid, gid);

    current_entry = current_entry->prev;
  }
}

/*
 * Helper function that mounts pretty much everything:
 *   - procfs
 *   - our overlay work directory
 *   - the rootfs,
 *   - the shards
 *   - the workspace (if given by the user)
 *
 *  If we're running in normal mode, `root_dir` and `dest` are both the same,
 *  pointing to the rootfs directory.  If we're running as `init`, they are
 *  "" and "/tmp", respectively.
 */
static void mount_the_world(const char * root_dir, const char * dest,
                            struct map_list * workspaces, struct map_list * shard_maps,
                            uid_t uid, gid_t gid) {
  // Mount the place we'll put all our overlay work directories
  mount_overlaywork("/proc");

  // Next, overlay all the things
  mount_rootfs_and_shards(root_dir, dest, "/proc", shard_maps, uid, gid);

  // Mount /proc within the sandbox
  mount_procfs(dest);

  // Mount /dev stuff
  mount_dev(dest);

  // Mount all our read-write mounts (workspaces)
  mount_workspaces(workspaces, dest);

  // Once we're done with that, put /proc back in its place in the big world.
  mount_procfs("");
}

/*
 * Sets up the chroot jail, then executes the target executable.
 */
static int sandbox_main(const char * root_dir, const char * new_cd, int sandbox_argc, char **sandbox_argv) {
  pid_t pid;
  int status;

  // Enter chroot
  check(0 == chdir(root_dir));
  check(0 == chroot("."));

  // If we've got a directory to change to, do so
  if (new_cd) {
    check(0 == chdir(new_cd));
  }

  // fflush before forking
  fflush(stdout);

  // When the main pid dies, we exit.
  pid_t main_pid;
  if ((main_pid = fork()) == 0) {
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

    // Flush to make sure we've said all we're going to before we _exit()
    fflush(stdout);
    fflush(stderr);
    _exit(1);
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

    pid_t reaped_pid;
    while ((reaped_pid = waitpid(-1, &status, WNOHANG)) != -1) {
      if (reaped_pid == main_pid) {
        // If it was the main pid that exited, return as well.
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
      }
    }
  }
}

static void print_help() {
  fputs("Usage: sandbox --rootfs <dir> [--cd <dir>] ", stderr);
  fputs("[--map <from>:<to>, --map <from>:<to>, ...] ", stderr);
  fputs("[--workspace <from>:<to>, --workspace <from>:<to>, ...] ", stderr);
  fputs("[--verbose] [--help] <cmd>\n", stderr);
  fputs("\nExample:\n", stderr);
  fputs("  BB=$(echo ~/.julia/v0.6/BinaryBuilder/deps)\n", stderr);
  fputs("  P=/usr/local/bin:/usr/bin:/bin:/opt/x86_64-linux-gnu/bin\n", stderr);
  fputs("  mkdir -p /tmp/workspace\n", stderr);
  fputs("  PATH=$P /tmp/sandbox --verbose --rootfs $BB/root --workspace /tmp/workspace:/workspace --cd /workspace --map $BB/shards/x86_64-linux-gnu:/opt/x86_64-linux-gnu /bin/bash\n", stderr);
}

// Helper function to read from the serial file descriptor, blocking until we
// can read the requested number of bytes.
void read_blocking(int fd, char * buff, int num_bytes) {
  int bytes_read = 0;

  // Keep reading until we have num_bytes
  while(bytes_read != num_bytes) {
    usleep(1);
    int b = read(fd, buff + bytes_read, num_bytes - bytes_read);
    if( b != -1 ) {
      bytes_read += b;
    }
  }
}

// We have a special way of reading in arguments when running as init,
// where we read from a fake serial device.
static void read_sandbox_args(int fd, int * argc, char *** argv) {
  // First, read the number of sandbox args:
  *argc = 0;
  read_blocking(fd, (char *)argc, sizeof(int));

  // We need to pretend that argv[0] is "sandbox", and we need a NULL ending
  *argc += 1;

  // Allocate and read in those args
  *argv = malloc(sizeof(char *) * (*argc + 1));
  (*argv)[0] = "/sandbox";
  int arg_idx;
  for( arg_idx=1; arg_idx<(*argc); ++arg_idx ) {
    int arg_len = 0;
    read_blocking(fd, (char *)&arg_len, sizeof(int));

    (*argv)[arg_idx] = malloc(arg_len + 1);
    read_blocking(fd, (*argv)[arg_idx], arg_len);
    (*argv)[arg_idx][arg_len] = '\0';
  }
  (*argv)[*argc] = NULL;
}

// We have a special way of creating a useful environment when running as init,
// where we read in the environment variables from a fake serial device.
static void read_sandbox_env(int fd) {
  // Clear the current environment.  No inheriting variables from QEMU!
  clearenv();

  int num_env_mappings = 0;
  read_blocking(fd, (char *)&num_env_mappings, sizeof(int));
  if (verbose) {
    printf("Reading %d environment mappings\n", num_env_mappings);
  }

  int env_buff_len = 1024;
  char * env_buff = malloc(env_buff_len + 1);
  int arg_idx;
  for( arg_idx=0; arg_idx<num_env_mappings; ++arg_idx ) {
    int arg_len = 0;
    read_blocking(fd, (char *)&arg_len, sizeof(int));

    // We guess that each environment mapping will be 1K or less,
    // but if we're wrong, bump the buffer size up.
    if( arg_len > env_buff_len) {
      env_buff_len = arg_len;
      env_buff = realloc(env_buff, env_buff_len + 1);
    }

    // Read the environment mapping into env_buff
    read_blocking(fd, env_buff, arg_len);
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

static void sigint_handler() { _exit(0); }

/*
 * Let's get this party started.
 */
int main(int sandbox_argc, char **sandbox_argv) {
  int status;
  pid_t pgrp = getpgid(0);
  int cmdline_fd = -1;

  // First, determine our execution mode based on pid and euid
  if (getpid() == 1) {
    execution_mode = INIT_MODE;
  } else if(geteuid() == 0) {
    execution_mode = PRIVILEGED_CONTAINER_MODE;
  } else {
    execution_mode = UNPRIVILEGED_CONTAINER_MODE;
  }

  uid_t uid = getuid();
  gid_t gid = getgid();

  // If we're running inside of `sudo`, we need to grab the UID/GID of the calling user through
  // environment variables, not using `getuid()` or `getgid()`.  :(
  const char * SUDO_UID = getenv("SUDO_UID");
  if (SUDO_UID != NULL && SUDO_UID[0] != '\0') {
    uid = strtol(SUDO_UID, NULL, 10);
  }
  const char * SUDO_GID = getenv("SUDO_GID");
  if (SUDO_GID != NULL && SUDO_GID[0] != '\0') {
    gid = strtol(SUDO_GID, NULL, 10);
  }

  // If we're running in init mode, we need to do some initial startup; we need to mount /proc,
  // and we need to read in our command line arguments over a virtual serial device, since we
  // have no other way for Julia to speak to us running inside of qemu.
  if (execution_mode == INIT_MODE) {
    // Extract our command line from the second serial device created by BinaryBuilder.jl
    const char * comm_dev = "/dev/vport0p1";
    cmdline_fd = open(comm_dev, O_RDWR);
    if( cmdline_fd == -1 ) {
      // This is a debugging escape hatch for us developers that aren't clever enough and
      // somehow screw up the Julia <---> qemu <---> sandbox communication channel.
      printf("Running as init but couldn't open %s; entering debugging mode!\n", comm_dev);
      sandbox_argc = 5;
      sandbox_argv = malloc(sizeof(char *)*(sandbox_argc + 1));
      sandbox_argv[0] = "/sandbox";
      sandbox_argv[1] = "--verbose";
      sandbox_argv[2] = "--workspace";
      sandbox_argv[3] = "9p/workspace:/workspace";
      sandbox_argv[4] = "/bin/bash";
      sandbox_argv[5] = NULL;
    } else {
      // If we have a communication channel, then let's read in our argc and argv!
      read_sandbox_args(cmdline_fd, &sandbox_argc, &sandbox_argv);
    }
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
      case '?':
      case 'h':
        print_help();
        return 0;
      case 'v':
        verbose = 1;
        printf("verbose sandbox enabled (running in ");
        switch (execution_mode) {
          case INIT_MODE:
            printf("init");
            break;
          case UNPRIVILEGED_CONTAINER_MODE:
            printf("un");
          case PRIVILEGED_CONTAINER_MODE:
            printf("privileged container");
            break;
        }
        printf(" mode)\n");
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
      case 'c':
        new_cd = strdup(optarg);
        if (verbose) {
          printf("Parsed --cd as \"%s\"\n", new_cd);
        }
        break;
      case 'w':
      case 'm': {
        // Find the colon in "from:to"
        char *colon = strchr(optarg, ':');
        check(colon != NULL);

        // Extract "from" and "to"
        char *from =  strndup(optarg, (colon - optarg));
        char *to = strdup(colon + 1);
        if ((from[0] != '/') && (strncmp(from, "9p/", 3) != 0)) {
          printf("ERROR: Outside path \"%s\" must be absolute or 9p!  Ignoring...\n", from);
          break;
        }

        // Construct `map_list` object for this `from:to` pair
        struct map_list *entry = (struct map_list *) malloc(sizeof(struct map_list));
        entry->map_path = to;
        entry->outside_path = from;

        // If this was `--map`, then add it to `maps`, if it was `--workspace` add it to `workspaces`
        if( c == 'm' ) {
          entry->prev = maps;
          maps = entry;
        } else {
          entry->prev = workspaces;
          workspaces = entry;
        }
        if (verbose) {
          printf("Parsed --%s as \"%s\" -> \"%s\"\n", c == 'm' ? "map" : "workspace",
                 entry->outside_path, entry->map_path);
        }
      } break;
      default:
        fputs("getoptlong defaulted?!\n", stderr);
        return 1;
    }
  }

  // Skip past those arguments
  sandbox_argv += optind;
  sandbox_argc -= optind;

  // If we don't have a command, die
  if (sandbox_argc == 0) {
    fputs("No <cmd> given!\n", stderr);
    print_help();
    return 1;
  }

  // If we're not init but we haven't been given a sandbox root, die
  if (!(execution_mode == INIT_MODE) && !sandbox_root) {
    fputs("--rootfs is required, unless running as init!\n", stderr);
    print_help();
    return 1;
  }

  // If we are running as init, read in our mandated environment variables,
  // then sub off to sandbox_main and finally reboot
  if (execution_mode == INIT_MODE) {
    read_sandbox_env(cmdline_fd);

    // We've received all of our configuration data.
    // Acknowledge receipt and close the file descriptor.
    uint8_t ok = 0;
    check(1 == write(cmdline_fd, &ok, sizeof(uint8_t)));
    close(cmdline_fd);

    // Take over the terminal
    setsid();
    ioctl(0, TIOCSCTTY, 1);

    // Let's mount our world.  Since we're running as init, the rootfs is already mounted
    // at "/", but it's read-only, so we use overlayfs to mount it on "/tmp".  We then
    // continue to mount our shards within "/tmp".
    mount_the_world("", "/tmp", workspaces, maps, 0, 0);

    // Run sandbox_main to Enter The Sandbox (TM)
    sandbox_main("/tmp", new_cd, sandbox_argc, sandbox_argv);

    // Don't forget to `sync()` so that we don't lose any pending writes to the filesystem!
    sync();

    // Goodnight, my sweet prince
    check(0 == reboot(RB_POWER_OFF));

    // This is never reached, but it's nice for completionism
    return 0;
  }

  // If we're running in one of the container modes, we're going to syscall() ourselves a
  // new, cloned process that is in a container process. We will use a pipe for synchronization.
  // The regular SIGSTOP method does not work because container-inits don't receive STOP or KILL
  // signals from within their own pid namespace.
  int child_block[2], parent_block[2];
  pipe(child_block);
  pipe(parent_block);
  pid_t pid;

  // If we are running as a privileged container, we need to build our mount mappings now.
  if (execution_mode == PRIVILEGED_CONTAINER_MODE) {
    // We dissociate ourselves from the typical mount namespace.  This gives us the freedom
    // to start mounting things willy-nilly without mucking up the user's computer.
    check(0 == unshare(CLONE_NEWNS));

    // Even if we unshare, we might need to mark `/` as private, as systemd often subverts
    // the kernel's default value of `MS_PRIVATE` on the root mount.  This doesn't affect
    // the main root mount, because we have unshared, but this prevents our changes to
    // any subtrees of `/` (e.g. everything) from propagating back to the outside `/`.
    check(0 == mount(NULL, "/", NULL, MS_PRIVATE|MS_REC, NULL));

    // Mount the rootfs, shards, and workspace.
    mount_the_world(sandbox_root, sandbox_root, workspaces, maps, uid, gid);
  }

  // We want to request a new PID space, a new mount space, and a new user space
  int clone_flags = CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUSER | SIGCHLD;
  if ((pid = syscall(SYS_clone, clone_flags, 0, 0, 0, 0)) == 0) {
    // If we're in here, we have become the "child" process, within the container.

    // Get rid of the ends of the synchronization pipe that I'm not going to use
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

    // Tell the parent we're ready, and wait until it signals that it's done
    // setting up our PID/GID mapping in configure_user_namespace()
    close(parent_block[1]);
    check(0 == read(child_block[0], NULL, 1));

    if (execution_mode == PRIVILEGED_CONTAINER_MODE) {
      // If we are in privileged container mode, let's go ahead and drop back
      // to the original calling user's UID and GID, which has been mapped to
      // zero within this container.

      check(0 == setuid(0));
      check(0 == setgid(0));
    }

    if (execution_mode == UNPRIVILEGED_CONTAINER_MODE) {
      // If we're unprivileged, we now take advantage of our new root status
      // to mount the world.
      mount_the_world(sandbox_root, sandbox_root, workspaces, maps, 0, 0);
    }

    // Finally, we begin invocation of the target program
    return sandbox_main(sandbox_root, new_cd, sandbox_argc, sandbox_argv);
  }

  // If we're out here, we are still the "parent" process.  The Prestige lives on.

  // Check to make sure that the clone actually worked
  check(pid != -1);

  // Get rid of the ends of the synchronization pipe that I'm not going to use.
  close(child_block[0]);
  close(parent_block[1]);

  // Wait until the child is ready to be configured.
  check(0 == read(parent_block[0], NULL, 1));
  if (verbose) {
    printf("Child Process PID is %d\n", pid);
  }

  // Configure user namespace for the child PID.
  configure_user_namespace(uid, gid, pid);

  // Signal to the child that it can now continue running.
  close(child_block[1]);

  // Wait until the child exits.
  check(pid == waitpid(pid, &status, 0));
  check(WIFEXITED(status));
  if (verbose) {
    printf("Child Process exited, exit code %d\n", WEXITSTATUS(status));
  }

  // Give back the terminal to the parent
  signal(SIGTTOU, SIG_IGN);
  tcsetpgrp(0, pgrp);

  // Return the error code of the child
  return WEXITSTATUS(status);
}
