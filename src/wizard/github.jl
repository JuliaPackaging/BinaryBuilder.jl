# This is a global github authentication token that is set the first time
# we authenticate and then reused
const _github_auth = Ref{GitHub.Authorization}()

function github_auth(;allow_anonymous::Bool=true)
    if !isassigned(_github_auth) || !allow_anonymous && isa(_github_auth[], GitHub.AnonymousAuth)
        # If the user is feeding us a GITHUB_TOKEN token, use it!
        if length(get(ENV, "GITHUB_TOKEN", "")) == 40
            _github_auth[] = GitHub.authenticate(ENV["GITHUB_TOKEN"])
        else
            if allow_anonymous
                _github_auth[] = GitHub.AnonymousAuth()
            else
                # If we're not allowed to return an anonymous authorization,
                # then let's create a token.
                _github_auth[] = GitHub.authenticate(obtain_token())
            end
        end
    end

    # Also shove this into Registrator, so it uses the same token.
    Registrator.CommentBot.CONFIG["github"] = Dict("token" => _github_auth[].token)
    return _github_auth[]
end

function obtain_token(; ins=stdin, outs=stdout, github_api=GitHub.DEFAULT_API)
    println(outs)
    printstyled(outs, "Creating a github access token\n", bold=true)
    println(outs, """
    To continue, we need to create a GitHub access token, so that we can do
    things like fork Yggdrasil and create pull requests against it.  To create
    an access token, you will be asked to enter your GitHub credentials:
    """)

    params = Dict(
        # The only thing we really need to do is write to public repos
        "scopes" => [
            "public_repo",
        ],
        "note" => "BinaryBuilder.jl generated token",
        "note_url" => "https://github.com/JuliaPackaging/BinaryBuilder.jl",
        "fingerpint" => randstring(40)
    )

    while true
        user = nonempty_line_prompt("Username", "GitHub username:", ins=ins, outs=outs)
        password = nonempty_line_prompt("Password", "GitHub password:"; ins=ins, outs=outs, echo=false)

        # Shuffle this junk off to the GH API
        headers = Dict{String, String}("User-Agent"=>"BinaryBuilder-jl")
        auth = GitHub.UsernamePassAuth(user, password)
        resp = GitHub.gh_post(
            github_api,
            "/authorizations";
            headers=headers,
            params=params,
            handle_error=false,
            auth=auth,
        )
        if resp.status == 401 && startswith(strip(HTTP.getkv(resp.headers, "X-GitHub-OTP", "")), "required")
            otp_code = nonempty_line_prompt("Authorization code", "Two-factor authentication in use, enter auth code:")
            resp = GitHub.gh_post(
                github_api,
                "/authorizations";
                headers=merge(headers, Dict("X-GitHub-OTP" => otp_code)),
                params=params,
                handle_error=false,
                auth = auth,
            )
        end
        if resp.status == 401
            printstyled(outs, "Invalid credentials!", color=:red)
            println(outs)
            continue
        end
        if resp.status != 200
            GitHub.handle_response_error(resp)
        end
        token = JSON.parse(HTTP.payload(resp, String))["token"]

        print(outs, strip("""
        Successfully obtained GitHub authorization token!
        This token will be used for the rest of this BB session, however if you
        wish to use this token permanently, you may set it in your environment
        as via the following line in your """))
        printstyled(outs, "~/.julia/config/startup.jl"; bold=true)
        println(outs, "file:")
        println(outs)

        printstyled(outs, "    ENV[\"GITHUB_TOKEN\"] = \"$(token)\""; bold=true)
        println(outs)

        println(outs, "This token is sensitive, so only do this in a computing environment you trust.")
        println(outs)

        return token
    end
end

function create_or_update_pull_request(repo, params; auth=github_auth())
    try
        return create_pull_request(repo; params=params, auth=auth)
    catch ex
        # If it was already created, search for it so we can update it:
        if Registrator.CommentBot.is_pr_exists_exception(ex)
            prs, _ = pull_requests(repo; auth=auth, params=Dict(
                "state" => "open",
                "base" => params["base"],
                "head" => string(split(repo, "/")[1], ":", params["head"]),
            ))
            return update_pull_request(repo, first(prs).number; auth=auth, params=params)
        else
            rethrow(ex)
        end
    end
end
