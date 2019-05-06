"""
    QemuRunner

A `QemuRunner` represents an "execution context", an object that bundles all
necessary information to run commands within the container that contains
our crossbuild environment.  Use `run()` to actually run commands within the
`QemuRunner`, and `runshell()` as a quick way to get an interactive shell
within the crossbuild environment.
"""
mutable struct QemuRunner <: Runner
    qemu_cmd::Cmd
    append_line::String
    sandbox_cmd::Cmd
    env::Dict{String, String}
    platform::Platform

    comm_task
    exit_code::Cint
end

qemu_url = "https://github.com/Keno/QemuBuilder/releases/download/v2.12.50-0/Qemu.v2.12.50.x86_64-apple-darwin14.tar.gz"
qemu_hash = "98210f754e39008d982f447cad60043f75ed8831b3ff36d464856ac24d7c603c"
kernel_url = "https://github.com/Keno/LinuxBuilder/releases/download/v4.15-rc2/linux.x86_64-linux-gnu.tar.gz"
kernel_hash = "0d02413529e635d4af6d2122f6aba22d261f43616bb286da3855325988f9ac3b"

qemu_dependencies = [
    "https://github.com/staticfloat/PixmanBuilder/releases/download/v0.34.0-0/Pixman.x86_64-apple-darwin14.tar.gz" =>
        "7d10eba60ac7824093199d557c7fb9ec0750cd2d3f2314d5a2480677fc1f88aa",
    "https://github.com/staticfloat/GlibBuilder/releases/download/v2.54.2-2/Glib.x86_64-apple-darwin14.tar.gz" =>
        "29b52a6a95ef48a0da40e2c3a9385dd2fc93d472a965763f932a15fcd96a100b",
    "https://github.com/staticfloat/PcreBuilder/releases/download/v8.41-0/pcre.x86_64-apple-darwin14.tar.gz" =>
        "e9b99a17525ed9d694e312be7e556e0666f64515c99c7cb87257a411abf8fb9e",
    "https://github.com/staticfloat/GettextBuilder/releases/download/v0.19.8-0/libgettext.x86_64-apple-darwin14.tar.gz" =>
        "b7f64f9c34705c157f6c6a241454a2984cc80cefd11f46c63345341791cc012f",
    "https://github.com/staticfloat/LibffiBuilder/releases/download/v3.2.1-0/libffi.x86_64-apple-darwin14.tar.gz" =>
        "287f289b428cfae58084aa4bab21cb07cc405a7c5535b62a39dc8b68d163d250",
    "https://github.com/staticfloat/ZlibBuilder/releases/download/v1.2.11-3/Zlib.x86_64-apple-darwin14.tar.gz" =>
        "d921114efca229f53b4faaac3d6d153862559aa38bc6df1b702732036394c634",
]

qemu_path() = storage_dir("qemu", "bin", "qemu-system-x86_64")
kernel_path() = storage_dir("qemu", "bzImage")

"""
    update_qemu(;verbose::Bool = false)

Update our QEMU and Linux kernel installations, downloading and installing both
into `<storage_dir>/qemu`.
"""
function update_qemu(;verbose::Bool = false)
	should_delete = false
    for (url, hash) in [qemu_dependencies; qemu_url=>qemu_hash; kernel_url=>kernel_hash]
        should_delete |= !download_verify(
            url,
            hash,
            storage_dir("downloads", basename(url));
            verbose=verbose,
            force=true
        )
    end
    qemu_cache = storage_dir("qemu")
    if should_delete
        rm(qemu_cache; recursive=true, force=true)
    end
    if !isdir(qemu_cache)
        for (url, hash) in [qemu_dependencies; qemu_url=>qemu_hash]
            unpack(storage_dir("downloads", basename(url)), qemu_cache; verbose=verbose)
        end
    end
    if !isfile(kernel_path())
        unpack(storage_dir("downloads", basename(kernel_url)), qemu_cache; verbose=verbose)
    end
end

function QemuRunner(workspace_root::String;
                    cwd = nothing,
                    platform::Platform = platform_key_abi(),
                    workspaces::Vector = [],
                    extra_env=Dict{String, String}(),
                    verbose::Bool = false)
    global use_ccache

    # Choose and prepare our shards
    shards = choose_shards(platform)
    prepare_shard.(shards; mount_squashfs = false, verbose=verbose)

    # QEMU can use the .squashfs files directly, so we don't use `mount_path()`.
    qemu_mount_path(cs) = cs.archive_type == :squashfs ? download_path(cs) : mount_path(cs)

    # Download/unpack Qemu (TODO: Make this a Qemu.jll package and just rely on it.)
    update_qemu(;verbose=verbose)

    # Construct environment variables we'll use from here on out
    envs = merge(platform_envs(platform; verbose=verbose), extra_env)

    # Resource limits for QEMU.  For some reason, it seems to crash if we use too many CPUs....
    memory_limit = Int64(div(Sys.total_memory()*3, 4*1024^2))
    core_limit = min(Sys.CPU_THREADS, 3)

    qemu_cmd = ```
        $(qemu_path()) -kernel $(kernel_path())
        -m $(memory_limit)M
        -cpu host
        -smp 2
        -M accel=$(Sys.islinux() ? "kvm" : "hvf")
        -nographic
        -nodefaults
        -rtc base=utc,driftfix=slew
        -device virtio-serial
        -chardev stdio,id=charconsole0
        -device virtconsole,chardev=charconsole0,id=console0
        -device virtserialport,chardev=charcomm0,id=comm0
        -device virtio-net-pci,netdev=networking
        -netdev user,id=networking
    ```
    append_line = "quiet console=hvc0 root=/dev/vda rootflags=ro rootfstype=squashfs noinitrd init=/sandbox"

    # First shard is always the rootfs
    qemu_cmd = `$qemu_cmd -drive if=virtio,file=$(qemu_mount_path(shards[1])),format=raw`

    sandbox_cmd = ``
    if verbose
        # We put --verbose at the beginning here so that we can see argument parsing
        sandbox_cmd = `$sandbox_cmd --verbose`
    end

    if cwd != nothing
        sandbox_cmd = `$sandbox_cmd --cd $cwd`
    end

    # We always include the destdir and  workspace as one of our read-write workspace mountings, and always as the first
    insert!(workspaces, 1, workspace_root => "/workspace")

    # If we're enabling ccache, then mount in a read-writeable volume at /root/.ccache
    if use_ccache
        if !isdir(ccache_dir())
            mkpath(ccache_dir())
        end
        push!(workspaces, ccache_dir() => "/root/.ccache")
    end

    devchr = 'b'
    devnum = 0
    # Mount in read-writable workspaces over plan9
    for (outside, inside) in workspaces
        qemu_cmd = `$qemu_cmd -fsdev local,security_model=none,id=fsdev$(devnum),path=$(outside) -device virtio-9p-pci,id=fs$(devnum),fsdev=fsdev$(devnum),mount_tag=workspace$(devnum)`
        sandbox_cmd = `$sandbox_cmd --workspace 9p/workspace$(devnum):$(inside)`
        devnum += 1
    end

    # Mount in compiler shards (excluding the rootfs shard)
    for shard in shards[2:end]
        # Squashfs files get mounted in directly, actual directories have to be shared over plan9:
        if shard.archive_type == :squashfs
            qemu_cmd = `$qemu_cmd -drive if=virtio,file=$(qemu_mount_path(shard)),format=raw`
            sandbox_cmd = `$sandbox_cmd --map /dev/vd$(devchr):$(map_target(shard))`
            devchr = Char(Int(devchr) + 1)
        else
            qemu_cmd = `$qemu_cmd -fsdev local,security_model=none,id=fsdev$(devnum),path=$(qemu_mount_path(shard)),readonly -device virtio-9p-pci,id=fs$(devnum),fsdev=fsdev$(devnum),mount_tag=mapping$(devnum)`
            sandbox_cmd = `$sandbox_cmd --map 9p/mapping$(devnum):$(map_target(shard))`
            devnum += 1
        end
    end

    return QemuRunner(qemu_cmd, append_line, sandbox_cmd, envs, platform, nothing, 0)
end


function show(io::IO, x::QemuRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) QemuRunner
    write(io, "$(typeof(p).name.name)", " ", arch(p), " ",
          Sys.islinux(p) ? "($(p.libc)) " : "",
          "QemuRunner")
end

function qemu_gen_cmd(qr::QemuRunner, cmd::Cmd, comm_socket_path::String)
    qr.comm_task = @async begin
        # This is what we'll send to `sandbox`
        sandbox_args = String.(`$(qr.sandbox_cmd) -- $(cmd)`.exec)
        sandbox_env = ["$k=$v" for (k, v) in qr.env]

        # Wait until QEMU starts up the communications channel
        start_time = time()
        while !issocket(comm_socket_path)
            sleep(0.01)
            if time() - start_time > 2
                start_time = time()
                @warn("Unable to establish communication with QEMU on $(comm_socket_path); quitting QEMU comms task")
                qr.exit_code = -5040
                return
            end
        end

        # Once it has, open it up,
        commsock = connect(comm_socket_path)

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

        # Wait for acknowledgement
        ack = read(commsock, UInt8)
        if ack != 0
            @warn("Acknowledgement from sandbox nonzero! $(ack)")
        end

        # Read exit status
        qr.exit_code = read(commsock, Cint)

        # Close communications socket
        close(commsock)
    end

    long_cmd = ```
        $(qr.qemu_cmd)
        -device virtio-serial -chardev socket,path=$(comm_socket_path),server,nowait,id=charcomm0
        -append $(qr.append_line)
    ```

    return `$long_cmd`
end

function qemu_wait(qr, oc)
    # Wait for QEMU to finish running
    did_succeed = wait(oc)

    if !did_succeed
        @warn("QEMU failed to run")
        return false
    end

    # Wait for our communications task to finish
    wait(qr.comm_task)

    # Check return code
    return qr.exit_code == 0
end

function Base.run(qr::QemuRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=stdout)
    return temp_prefix() do prefix
        comm_socket_path = joinpath(prefix.path, "qemu_comm.socket")
        # Launch QEMU
        cmd = qemu_gen_cmd(qr, cmd, comm_socket_path)

        oc = OutputCollector(cmd; verbose=verbose, tee_stream=tee_stream)
        did_succeed = qemu_wait(qr, oc)

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
end

function run_interactive(qr::QemuRunner, cmd::Cmd; stdin = nothing, stdout = nothing, stderr = nothing)
    temp_prefix() do prefix
        comm_socket_path = joinpath(prefix.path, "qemu_comm.socket")
        cmd = qemu_gen_cmd(qr, cmd, comm_socket_path)
        if stdin isa Base.AbstractCmd || stdin isa Base.TTY
            cmd = pipeline(cmd, stdin=stdin)
        end
        if stdout isa Base.AbstractCmd || stdout isa Base.TTY
            cmd = pipeline(cmd, stdout=stdout)
        end
        if stderr isa Base.AbstractCmd || stderr isa Base.TTY
            cmd = pipeline(cmd, stderr=stderr)
        end

        if stdout isa IOBuffer
            if !(stdin isa IOBuffer)
                stdin = devnull
            end

            process = open(cmd, "r", stdin)
            @async begin
                while !eof(process)
                    write(stdout, read(process))
                end
            end
            wait(process)
        else
            @static if Sys.isapple()
                println("Setting parent shell interrupt to ^] (use ^C as usual, ^] to interrupt Julia)")
                run(`stty intr ^\]`)
            end
            run(cmd)
            @static if Sys.isapple()
                run(`stty intr ^\C`)
            end
        end
    end

    # Qemu appears to mess with our terminal
    if stdin !== nothing
        Base.reseteof(stdin)
    end
end

function runshell(qr::QemuRunner, args...; kwargs...)
    run_interactive(qr, `/bin/bash`, args...; kwargs...)
end
