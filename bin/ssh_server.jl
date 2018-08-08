using GitHub
using SSH
using BinaryBuilder
using JSON

eval(Base, :(have_color = true))

port = parse(Int, get(ENV, "BINBUILDER_PORT", "2222"))
sock = listen(port)

pubkey_to_user_map = Dict{Vector{UInt8}, String}()
user_to_pubkey_map = Dict{String, Vector{UInt8}}()

const github_token = strip(String(read(joinpath(dirname(@__FILE__),"..","etc","github_tok"))))
auth = GitHub.authenticate(github_token)

tx = "\033[0m\033[0m" # text
jl = "\033[0m\033[1m" # julia
d1 = "\033[34m" # first dot
d2 = "\033[31m" # second dot
d3 = "\033[32m" # third dot
d4 = "\033[35m" # fourth dot

const banner =
"""

   $(d3)⬤$(tx)     | JuliaLang Binary Builder (JuliaPackaging/BinaryBuilder.jl)
 $(d2)⬤$(tx)   $(d4)⬤$(tx)   | Please file issues for any problems you encounter
   $(d1)⬤$(tx)     | Your call may be monitored for quality assurance.
"""

function enter_main(tty)
    println(tty, banner)
    state = BinaryBuilder.State()
    state.ins = tty
    state.outs = tty
    BinaryBuilder.run_wizard(state)
end


function open_fake_pty()
    O_RDWR = Base.Filesystem.JL_O_RDWR
    O_NOCTTY = Base.Filesystem.JL_O_NOCTTY

    fdm = ccall(:posix_openpt, Cint, (Cint,), O_RDWR|O_NOCTTY)
    fdm == -1 && error("Failed to open PTY master")
    rc = ccall(:grantpt, Cint, (Cint,), fdm)
    rc != 0 && error("grantpt failed")
    rc = ccall(:unlockpt, Cint, (Cint,), fdm)
    rc != 0 && error("unlockpt")

    fds = ccall(:open, Cint, (Ptr{UInt8}, Cint),
        ccall(:ptsname, Ptr{UInt8}, (Cint,), fdm), O_RDWR|O_NOCTTY)

    # slave
    slave   = RawFD(fds)
    master = Base.TTY(RawFD(fdm); readable = true)
    slave, master, RawFD(fdm)
end

while true
    client = accept(sock)
    @async begin
        session = connect(SSH.Session, client; client = false)
        SSH.negotiate_algorithms!(session)
        SSH.server_dh_kex!(session,
            joinpath(dirname(@__FILE__),"..","etc","id_rsa.pub"),
            joinpath(dirname(@__FILE__),"..","etc","id_rsa"))
        pubkey_auth = function(username, algorithm, blob)
            if haskey(pubkey_to_user_map, blob)
                return true
            end
            return false
        end
        SSH.wait_for_userauth(session, publickey = pubkey_auth, keyboard_interactive = function(session, submethods)
            responses = SSH.keyboard_interactive_prompt(session, "New user signup!",
                "Hi there, looks like we don't know who you are.\nTo proceed, please identify yourself.",
                ["GitHub username: "])
            # Check if access is enabled for this user
            github_username = strip(String(responses[1]))
            @show github_username
            if contains(github_username,"/") || contains(github_username,"%") ||
                contains(github_username,"%") || contains(github_username,"@") ||
                contains(github_username,"#")
                SSH.disconnect(session)
                return false
            end
            if !GitHub.check_membership("JuliaComputing", github_username; auth=auth) &&
               !GitHub.check_membership("JuliaLang", github_username; auth=auth)
                SSH.keyboard_interactive_prompt(session, "Access denied",
                """
                    Access is currently restricted to JuliaLang organization members.
                    Please contact keno@juliacomputing.com with any questions.
                """)
                SSH.disconnect(session)
                return false
            end
            pubkeys = values(try
                GitHub.pubkeys(github_username; auth=auth)[1]
            catch
                SSH.keyboard_interactive_prompt(session, "Internal Error",
                """
                    Failed to retrieve your GitHub keys
                """)
                error()
            end)
            for key in pubkeys
                pubkey_to_user_map[base64decode(String(split(key,' ')[2]))] = github_username
            end
            SSH.keyboard_interactive_prompt(session, "Success!",
                """
                    Thank you $(github_username). Login is now enabled using any SSH key you have added to GitHub.
                    Please note that older SSH clients will abort after this message.
                    In that case, please simply reconnect.
                """)
            SSH.userauth_partial_success(session, publickey = pubkey_auth)
        end)
        SSH.perform_ssh_connection(session) do kind, channel
            if kind == "session"
                c = Condition()
                local encoded_termios
                open(channel)
                SSH.on_channel_request(channel) do kind, packet
                    want_reply = read(packet, UInt8) != 0
                    @show kind
                    if kind == "pty-req"
                        TERM_var = SSH.read_string(packet)
                        termwidthchars = bswap(read(packet, UInt32))
                        termheightchars = bswap(read(packet, UInt32))
                        termwidthpixs = bswap(read(packet, UInt32))
                        termheightpixs = bswap(read(packet, UInt32))
                        encoded_modes = SSH.read_string(packet)
                        encoded_termios = IOBuffer(encoded_modes)
                        notify(c)
                    elseif kind == "window-change"

                    elseif kind == "signal"
                        SSH.disconnect(channel.session)
                    end
                    want_reply
                end
                println("Waiting to PTY request")
                @async begin wait(c)
                    asciicast_io = IOBuffer()
                    starttime = now()
                    println(asciicast_io, JSON.json(Dict(
                        "version" => 2,
                        "timestamp" => trunc(Int64,Dates.datetime2unix(starttime)),
                        "title" => "BinaryBuilder.jl session",
                    )))
                    try
                        slave, master, masterfd = open_fake_pty()
                        new_termios = Ref{SSH.termios}()
                        systemerror("tcgetattr",
                            -1 == ccall(:tcgetattr, Cint, (Cint, Ptr{Cvoid}), slave, new_termios))
                        new_termios[] = SSH.decode_modes(encoded_termios, new_termios[])
                        systemerror("tcsetattr",
                            -1 == ccall(:tcsetattr, Cint, (Cint, Cint, Ptr{Cvoid}), slave, 0, new_termios))
                        new_termios = Ref{SSH.termios}()
                        @async while true
                            data = readavailable(master)
                            print(asciicast_io, "[", (now()-starttime).value/1000, ", \"o\", \"")
                            for c in String(data)
                                if c == '\\' || c == '"'
                                    print(asciicast_io, '\\')
                                    print(asciicast_io, c)
                                elseif isprint(c)
                                    print(asciicast_io, c)
                                else
                                    print(asciicast_io, "\\u")
                                    print(asciicast_io, hex(c, 4))
                                end
                            end
                            println(asciicast_io, "\"]")
                            write(channel, data)
                        end
                        @async while true
                            data = readavailable(channel)
                            write(master, data)
                        end
                        tty = Base.TTY(slave, readable = true)
                        println("Entering main loop")
                        enter_main(tty)
                    finally
                        open(joinpath(dirname(@__FILE__),"..","logs",string(randstring(),".cast")), "w") do f
                            write(f, take!(asciicast_io))
                        end
                        try; SSH.disconnect(channel.session); catch; end
                    end
                end
            end
        end
    end
end
