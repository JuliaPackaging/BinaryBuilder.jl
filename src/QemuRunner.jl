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
    env::Dict{String, String}
    platform::Platform
end

const qemu_prefix = Prefix(joinpath(@__DIR__,"..","deps","usr"))
const qemu_hash = "92fa439350970f673a7324b61ed5bc4894d6665543175f01135550cb4a458cde"
const kernel_hash = "0d02413529e635d4af6d2122f6aba22d261f43616bb286da3855325988f9ac3b"

function update_qemu()
    install("https://github.com/Keno/QemuBuilder/releases/download/hvf/qemu.x86_64-apple-darwin14.tar.gz",
        qemu_hash; prefix=qemu_prefix, force=true, verbose=true)
    install("https://github.com/Keno/LinuxBuilder/releases/download/v4.15-rc2/linux.x86_64-linux-gnu.tar.gz",
        kernel_hash; prefix=qemu_prefix, force=true, verbose=true, ignore_platform=true)
end

qemu_path() = joinpath(qemu_prefix, "usr/local/bin/qemu-system-x86_64")
kernel_path() = joinpath(qemu_prefix, "bzImage")

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
    global sandbox_path

    # Ensure the rootfs for this platform is downloaded and up to date
    update_rootfs(
        platform != Linux(:x86_64) ?
        [triplet(platform), triplet(Linux(:x86_64))] :
        triplet(platform); verbose=verbose, squashfs=true, mount=false)
    update_qemu()

    qemu_cmd = ```
        $(qemu_path()) -kernel $(kernel_path())
        -M accel=$(platform_accelerator()) -nographic
        -drive if=virtio,file=$(rootfs_path_squashfs()),format=raw
        -nodefaults -rtc base=utc,driftfix=slew
        -device virtio-serial -chardev stdio,id=charconsole0
        -device virtconsole,chardev=charconsole0,id=console0
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

    QemuRunner(qemu_cmd, append_line, sandbox_cmd, merge(target_envs(triplet(platform)), extra_env), platform)
end


function show(io::IO, x::QemuRunner)
    p = x.platform
    # Displays as, e.g., Linux x86_64 (glibc) QemuRunner
    write(io, typeof(p), " ", arch(p), " ",
          Compat.Sys.islinux(p) ? "($(p.libc)) " : "",
          "QemuRunner")
end

function generate_cmd(ur::QemuRunner, cmd)
    cmd = `$(ur.sandbox_cmd) $(cmd)`
    cmd_string = join(map(cmd.exec) do arg
        # Could encode as human readable with shell escaping, but we'd just
        # have to do the decoding on the client side and it's a very, very
        # complicated encoding. Base64 is much simpler.
        base64encode(arg)
    end, ' ')
    env_string = join([base64encode("$k=$v") for (k, v) in ur.env], ' ')
    append_line = string(ur.append_line, " sandboxargs=\"$cmd_string\" sandboxenv=\"$env_string\"")
    bootline = `-append $append_line`
    `$(ur.qemu_cmd) $(bootline)`
end

function Base.run(ur::QemuRunner, cmd, logpath::AbstractString; verbose::Bool = false, tee_stream=STDOUT)
    did_succeed = true
    cd(dirname(sandbox_path)) do
        oc = OutputCollector(generate_cmd(ur, cmd); verbose=verbose, tee_stream=tee_stream)

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
    end

    # Return whether we succeeded or not
    return did_succeed
end

function run_interactive(ur::QemuRunner, cmd::Cmd, stdin = nothing, stdout = nothing, stderr = nothing)
    cd(dirname(sandbox_path)) do
        cmd = generate_cmd(ur, cmd)
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
        # Qemu appears to mess with our terminal
        Base.reseteof(STDIN)
    end
end

function runshell(ur::QemuRunner, args...)
    run_interactive(ur, `/bin/bash`, args...)
end

function runshell(::Type{QemuRunner}, platform::Platform = platform_key())
    ur = QemuRunner(
        pwd();
        cwd="/workspace/",
        platform=platform
    )
    return runshell(ur)
end
