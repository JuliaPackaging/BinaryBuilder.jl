"""
    QemuRunner

A `QemuRunner` represents an "execution context", an object that bundles all
necessary information to run commands within the container that contains
our crossbuild environment.  Use `run()` to actually run commands within the
`QemuRunner`, and `runshell()` as a quick way to get an interactive shell
within the crossbuild environment.
"""
type QemuRunner <: Runner
    qemu_cmd::Cmd
    append_line::String
    sandbox_cmd::Cmd
    comm_socket_path::String
    env::Dict{String, String}
    platform::Platform
end

qemu_url = "https://github.com/Keno/QemuBuilder/releases/download/hvf/qemu.x86_64-apple-darwin14.tar.gz"
qemu_hash = "92fa439350970f673a7324b61ed5bc4894d6665543175f01135550cb4a458cde"
kernel_url = "https://github.com/Keno/LinuxBuilder/releases/download/v4.15-rc2/linux.x86_64-linux-gnu.tar.gz"
kernel_hash = "0d02413529e635d4af6d2122f6aba22d261f43616bb286da3855325988f9ac3b"

"""
    update_qemu(;verbose::Bool = false)

Update our QEMU and Linux kernel installations, downloading and installing them
into the `qemu_cache` directory that defaults to `deps/qemu`.
"""
function update_qemu(;verbose::Bool = false)
    download_verify_unpack(
        qemu_url,
        qemu_hash,
        qemu_cache;
        tarball_path=downloads_dir(basename(qemu_url)),
        verbose=verbose,
        force=true
    )
    download_verify_unpack(
        kernel_url,
        kernel_hash,
        qemu_cache;
        tarball_path=downloads_dir(basename(kernel_url)),
        verbose=verbose,
        force=true
    )
end

qemu_path() = joinpath(qemu_cache, "usr/local/bin/qemu-system-x86_64")
kernel_path() = joinpath(qemu_cache, "bzImage")

function platform_def_mounts(platform)
    tp = triplet(platform)
    mapping = Pair{String,String}[
        shard_path_squashfs(tp) => joinpath("/opt", tp)
    ]

    # We might also need the x86_64-linux-gnu platform for bootstrapping,
    # so make sure that's always included
    if platform != Linux(:x86_64)
        ltp = triplet(Linux(:x86_64))
        push!(mapping, shard_path_squashfs(ltp) => joinpath("/opt", ltp))
    end

    # Reverse mapping order, because `sandbox` reads them backwards
    reverse!(mapping)
    return mapping
end

function platform_def_9p_mappings(platform)
    tp = triplet(platform)
    mapping = Pair{String,String}[]

    # If we're trying to run macOS and we have an SDK directory, mount that!
    if platform == MacOS()
        sdk_version = "MacOSX10.10.sdk"
        sdk_shard_path = joinpath(shards_cache, sdk_version)
        push!(mapping, sdk_shard_path => joinpath("/opt", tp, sdk_version))
    end
    
    return mapping
end

platform_accelerator() = Compat.Sys.islinux() ? "kvm" : "hvf"

function QemuRunner(workspace_root::String; cwd = nothing,
                      platform::Platform = platform_key(),
                      extra_env=Dict{String, String}(),
                      verbose::Bool = true,
                      mounts = platform_def_mounts(platform),
                      mappings = platform_def_9p_mappings(platform))
    # Ensure the rootfs for this platform is downloaded and up to date
    update_rootfs(
        platform != Linux(:x86_64) ?
        [triplet(platform), triplet(Linux(:x86_64))] :
        triplet(platform); verbose=verbose, squashfs=true, mount=false)
    update_qemu(;verbose=verbose)

    # Create temporary filename for qemu serial communication
    comm_socket_path = tempname()

    qemu_cmd = ```
        $(qemu_path()) -kernel $(kernel_path())
        -M accel=$(platform_accelerator()) -nographic
        -drive if=virtio,file=$(rootfs_path_squashfs()),format=raw
        -nodefaults -rtc base=utc,driftfix=slew
        -device virtio-serial -chardev stdio,id=charconsole0
        -device virtconsole,chardev=charconsole0,id=console0
        -device virtio-serial -chardev socket,path=$(comm_socket_path),server,nowait,id=charcomm0
        -device virtserialport,chardev=charcomm0,id=comm0
        -fsdev local,security_model=none,id=fsdev0,path=$workspace_root -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=workspace
    ```
    append_line = "quiet console=hvc0 root=/dev/vda rootflags=ro rootfstype=squashfs noinitrd init=/sandbox"

    sandbox_cmd = `--workspace 9p:workspace`
    if cwd != nothing
        sandbox_cmd = `$sandbox_cmd --cd $cwd`
    end

    num = 1
    for (mapping, dir) in mappings
        qemu_cmd = `$qemu_cmd -fsdev local,security_model=none,id=fsdev$num,path=$mapping,readonly -device virtio-9p-pci,id=fs$num,fsdev=fsdev$num,mount_tag=mapping$num`
        sandbox_cmd = `$sandbox_cmd --map 9p/mapping$num:$dir`
    end

    c = 'b'
    for (mount,dir) in mounts
        qemu_cmd = `$qemu_cmd -drive if=virtio,file=$mount,format=raw`
        sandbox_cmd = `$sandbox_cmd --map /dev/vd$c:$dir`
        c = Char(Int(c) + 1)
    end

    if verbose
        # We put --verbose at the beginning here so that we can see argument parsing
        sandbox_cmd = `--verbose $sandbox_cmd`
    end

    QemuRunner(qemu_cmd, append_line, sandbox_cmd, comm_socket_path, merge(target_envs(triplet(platform)), extra_env), platform)
end


function show(io::IO, x::QemuRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) QemuRunner
    write(io, typeof(p), " ", arch(p), " ",
          Compat.Sys.islinux(p) ? "($(p.libc)) " : "",
          "QemuRunner")
end

function pass_sandbox_args(qr::QemuRunner, cmd::Cmd)
    @async begin
        # This is what we'll send to `sandbox`
        sandbox_args = String.(`$(qr.sandbox_cmd) $(cmd)`.exec)
        sandbox_env = ["$k=$v" for (k, v) in qr.env]

        # Wait until QEMU starts up the communications channel
        while !issocket(qr.comm_socket_path)
            sleep(0.1)
            info("waiting...")
        end

        # Once it has, open it up, 
        commsock = connect(qr.comm_socket_path)

        # We're going to spit out:
        #  [4 bytes] number of sandbox args
        #    for each sandbox arg:
        #      [4 bytes] length of arg
        #      [N bytes] arg literal string
        #  [4 bytes] number of environment mappings
        #    for each environment mapping
        #      [4 bytes] length of mapping
        #      [N bytes] mapping literal string
        write(commsock, UInt32(length(sandbox_args)))
        for idx in 1:length(sandbox_args)
            write(commsock, UInt32(length(sandbox_args[idx])))
            write(commsock, sandbox_args[idx])
        end

        write(commsock, UInt32(length(sandbox_env)))
        for idx in 1:length(sandbox_env)
            write(commsock, UInt32(length(sandbox_env[idx])))
            write(commsock, sandbox_env[idx])
        end

        info("Finished writing to commsock")
        close(commsock)
    end
end

function Base.run(qr::QemuRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=STDOUT)
    # Write out our arguments to `sandbox` to the communication socket:
    pass_sandbox_args(qr, cmd)

    # Launch QEMU
    oc = OutputCollector(`$(qr.qemu_cmd) -append $(qr.append_line)`; verbose=verbose, tee_stream=tee_stream)

    # Always try to remove the comm socket path
    rm(qr.comm_socket_path; force=true)

    did_succeed = wait(oc)
    if !isempty(logpath)
        # Write out the logfile, regardless of whether it was successful
        mkpath(dirname(logpath))
        open(logpath, "w") do f
            # First write out the actual command, then the command output
            println(f, cmd)
            print(f, merge(oc))
        end
    end

    # Return whether we succeeded or not
    return did_succeed
end

function run_interactive(qr::QemuRunner, cmd::Cmd, stdin = nothing, stdout = nothing, stderr = nothing)
    pass_sandbox_args(qr, cmd)
    cmd = `$(qr.qemu_cmd) -append $(qr.append_line)`
    if stdin != nothing
        cmd = pipeline(cmd, stdin=stdin)
    end
    if stdout != nothing
        cmd = pipeline(cmd, stdout=stdout)
    end
    if stderr != nothing
        cmd = pipeline(cmd, stderr=stderr)
    end
    run(cmd)
    
    # Always try to remove the comm socket path
    rm(qr.comm_socket_path; force=true)

    # Qemu appears to mess with our terminal
    Base.reseteof(STDIN)
end

function runshell(qr::QemuRunner, args...)
    run_interactive(qr, `/bin/bash`, args...)
end

function runshell(::Type{QemuRunner}, platform::Platform = platform_key(); verbose::Bool = false)
    qr = QemuRunner(
        pwd();
        cwd="/workspace/",
        platform=platform,
        verbose=verbose
    )
    return runshell(qr)
end
