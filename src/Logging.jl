using LoggingExtras, Logging
import Logging: AbstractLogger, handle_message

struct AzureSinkLogger{F} <: Logging.AbstractLogger
    action_chooser::F
    io::IO
end

AzureSinkLogger(f=_->"task.logissue") = AzureSinkLogger(f, stderr)

function Logging.handle_message(logger::AzureSinkLogger, args...; kwargs...)
    #Make it a named tuple for easier working
    log = LoggingExtras.handle_message_args(args...)
    task::String = logger.action_chooser(log)

    properties=String[]
    # AZP calls it `type` not level`, and `warning` not `warn`:
    levelmap = Dict(Logging.Error => "error", Logging.Warn => "warning")
    push!(properties, "type=$(levelmap[log[:level]])")
    for key in (:_module, :group, :id, :file, :line)
        push!(properties, "$key=$(log[key])")
    end
    for key in keys(log.kwargs)
        push!(properties, "$key=$(log.kwargs[key])")
    end
    props=join(properties, ";")
    # format: ##vso[area.action property1=value;property2=value;...]message
    println(logger.io, "##vso[$task $props]$(log.message)")
end
Logging.shouldlog(::AzureSinkLogger, arg...) = true
Logging.min_enabled_level(::AzureSinkLogger) = Logging.Warn
Logging.catch_exceptions(::AzureSinkLogger) = true

function enable_azure_logging()
    # Tee-in AzureSinkLogger so that `@warn` and `@error` are printed out nicely
    global_logger(TeeLogger(
        global_logger(),
        AzureSinkLogger(),
    ))
end

struct BuildkiteLogger <: Logging.AbstractLogger
end

function annotate(annotation; context="default", style="info", append=true)
    @assert style in ("success", "info", "warning", "error")
    append = append ? `--append` : ``
    cmd = `buildkite-agent annotate --style $(style) --context $(context) $(append)`
    open(cmd, stdout, write=true) do io
        write(io, annotation)
    end
end

function Logging.handle_message(logger::BuildkiteLogger, args...; kwargs...)
    #Make it a named tuple for easier working
    log = LoggingExtras.handle_message_args(args...)

    # Buildkite calls it `style` not level`, and `warning` not `warn`:
    log[:level]
    stylemap = Dict(Logging.Error => "error", Logging.Warn => "warning")
    style = stylemap[log[:level]]

    # TODO pretty rendering of properties
    annotate(log.message; context="BinaryBuilder", style)
    return nothing
end
Logging.shouldlog(::BuildkiteLogger, arg...) = true
Logging.min_enabled_level(::BuildkiteLogger) = Logging.Warn
Logging.catch_exceptions(::BuildkiteLogger) = true

function enable_buildkite_logging()
    # Tee-in BuildkiteLogger so that `@warn` and `@error` are printed out nicely
     global_logger(TeeLogger(
        global_logger(),
        BuildkiteLogger(),
    ))
end
