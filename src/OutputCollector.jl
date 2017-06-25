import Base: wait

immutable LineStream
    pipe::Pipe
    lines::Vector{Tuple{Float64,String}}
    task::Task
end

"""
`LineStream(pipe::Pipe)`

Given a `Pipe` that has been initialized by `spawn()`, create an async Task to
read in lines as they come in and annotate the time the line was captured for
later replay/merging with other simultaneously captured streams.
"""
function LineStream(pipe::Pipe, event::Condition)
    # We always have to close() the input half of the stream before we can
    # read() from it.  I don't know why, and this is honestly kind of annoying
    close(pipe.in)

    lines = Tuple{Float64,String}[]
    task = @async begin
        # Read lines in until we can't anymore
        while !eof(pipe)
            # Push this line onto our lines, then notify() the event
            line = chomp(readline(pipe))
            push!(lines, (time(), line))
            notify(event)
        end
    end

    # Create a second task that runs after the first just to notify()
    # This ensures that anybody that's listening to the event but gated on our
    # being alive (e.g. `tee()`) can die alongside us gracefully as well.
    @async begin
        wait(task)
        notify(event)
    end
    return LineStream(pipe, lines, task)
end

"""
`alive(s::LineStream)`

Returns `true`` if the task owned by this `LineStream` is still processing
output from an underlying `Pipe`.
"""
function alive(s::LineStream)
    return !(s.task.state in [:done, :failed])
end




immutable OutputCollector
    cmd::Base.AbstractCmd
    P::Base.AbstractPipe
    stdout_linestream::LineStream
    stderr_linestream::LineStream
    event::Condition

    extra_tasks::Vector{Task}
end

"""
`OutputCollector(cmd::AbstractCmd; verbose::Bool = false)`

Run `cmd`, and collect the output such that `stdout` and `stderr` are captured
independently, but with the time of each line recorded such that they can be
stored/analyzed independently, but replayed synchronously.
"""
function OutputCollector(cmd::Base.AbstractCmd; verbose::Bool=false)
    # First, launch the command
    out_pipe = Pipe()
    err_pipe = Pipe()
    P = try
        spawn(cmd, (DevNull, out_pipe, err_pipe))
    catch
        warn("Could not spawn $(cmd)")
        rethrow()
    end

    # Next, start siphoning off the first couple lines of output and error
    event = Condition()
    stdout_ls = LineStream(out_pipe, event)
    stderr_ls = LineStream(err_pipe, event)

    # Finally, wrap this up in an object so that we can merge stdout and stderr
    # back together again at the end
    self = OutputCollector(cmd, P, stdout_ls, stderr_ls, event, Task[])

    if verbose
        tee(self)
    end

    return self
end

"""
`wait(collector::OutputCollector)`

Wait for the command and all line streams within an `OutputCollector` to finish
their respective tasks and be ready for full merging.  Return the success of the
underlying process.
"""
function wait(collector::OutputCollector)
    wait(collector.P)
    wait(collector.stdout_linestream.task)
    wait(collector.stderr_linestream.task)

    # Also wait on any extra tasks we've jimmied onto the end of this guy
    for t in collector.extra_tasks
        wait(t)
    end
    return success(collector.P)
end

"""
`merge(collector::OutputCollector; colored::Bool = false)`

Merge the stdout and stderr streams of the `OutputCollector` on a per-line
basis, returning a single string containing all collected lines, interleaved by
capture time.  If `colored` is set to true, embeds terminal color codes to
print `stderr` in red.
"""
function merge(collector::OutputCollector; colored::Bool = false)
    # First, wait for things to be done.  No incomplete mergings here yet.
    wait(collector)

    # We copy here so that you can `merge()` more than once, if you want.
    stdout_lines = copy(collector.stdout_linestream.lines)
    stderr_lines = copy(collector.stderr_linestream.lines)
    output = IOBuffer()

    # Write out an stdout line, optionally with color, and pop off that line
    function write_line(lines, should_color, color)
        if should_color && colored
            print(output, color)
        end
        t, line = shift!(lines)
        println(output, line)
    end

    # These help us keep track of colorizing the output
    out_color = Base.text_colors[:default]
    err_color = Base.text_colors[:red]
    last_line_stderr = false

    # Merge stdout and stderr    
    while !isempty(stdout_lines) && !isempty(stderr_lines)
        # Figure out if stdout's timestamp is earlier than stderr's
        if stdout_lines[1][1] < stderr_lines[1][1]
            write_line(stdout_lines,  last_line_stderr, out_color)
            last_line_stderr = false
        else
            write_line(stderr_lines, !last_line_stderr, err_color)
            last_line_stderr = true
        end
    end

    # Now drain whichever one still has data within it
    while !isempty(stdout_lines)
        write_line(stdout_lines, last_line_stderr, out_color)
        last_line_stderr = false
    end
    while !isempty(stderr_lines)
        write_line(stderr_lines, !last_line_stderr, err_color)
        last_line_stderr = true
    end

    # Clear text colors at the end, if we need to
    if last_line_stderr && colored
        print(output, Base.text_colors[:default])
    end

    # Return our ill-gotten goods
    return String(output)
end

"""
`stdout(collector::OutputCollector)`

Returns all stdout lines collected by this collector so far.
"""
function stdout(collector::OutputCollector)
    return join([l[2] * "\n" for l in collector.stdout_linestream.lines], "")
end

"""
`stderr(collector::OutputCollector)`

Returns all stderr lines collected by this collector so far.
"""
function stderr(collector::OutputCollector)
    return join([l[2] * "\n" for l in collector.stderr_linestream.lines], "")
end

"""
`tail(collector::OutputCollector; len::Int = 10, colored::Bool = false)`

Write out the last `len` lines, optionally writing colored lines.
"""
function tail(collector::OutputCollector; len::Int = 10, colored::Bool = false)
    out = merge(collector; colored=colored)

    idx = length(out)
    for line_idx in 1:len
        idx = findprev(out, '\n', idx-1)
        if idx <= 0
            break
        end
    end

    return out[idx+1:end]
end

"""
`tee(c::OutputCollector; colored::Bool = false)`

Spawn a background task to incrementally output lines from `collector` to the
standard output, optionally colored.
"""
function tee(c::OutputCollector; colored::Bool = Base.have_color)
    tee_task = @async begin
        out_idx = 1
        err_idx = 1
        out_lines = c.stdout_linestream.lines
        err_lines = c.stderr_linestream.lines

        # Helper function to print out the next line of stdout/stderr
        function print_next_line()
            timestr = Libc.strftime("[%T] ", time())
            # We know we have data, so figure out if it's for stdout or stderr
            if length(out_lines) >= out_idx
                print_color(:default, timestr; bold=true)
                if length(err_lines) >= err_idx
                    # If we've got input waiting from both lines, then output
                    # the one with the lowest capture time
                    if out_lines[out_idx][1] < err_lines[err_idx][1]
                        # Print the out line as it's older
                        println(out_lines[out_idx][2])
                        out_idx += 1
                    else
                        # Print the err line as it's older
                        print_color(:red, err_lines[err_idx][2])
                        println()
                        err_idx += 1
                    end
                else
                    # Pring the out line that is the only one waiting
                    println(out_lines[out_idx][2])
                    out_idx += 1
                end
            else length(err_lines) > err_idx
                # Print the err line that is the only one waiting
                print_color(:default, timestr; bold=true)
                print_color(:red, err_lines[err_idx][2])
                println()
                err_idx += 1
            end
        end

        # First thing, wait for some input.  This avoids us trying to inspect
        # the liveliness of the linestreams before they've even started.
        wait(c.event)

        while alive(c.stdout_linestream) || alive(c.stderr_linestream)
            if length(out_lines) >= out_idx || length(err_lines) >= err_idx
                # If we have data to output, then do so
                print_next_line()
            else
                # Otherwise, wait for more input
                wait(c.event)
            end
        end

        # Drain the rest of stdout and stderr
        while length(out_lines) >= out_idx || length(err_lines) >= err_idx
            print_next_line()
        end
    end

    # Let the collector know that he might have to wait on this `tee()` to
    # finish its business as well.
    push!(c.extra_tasks, tee_task)

    return tee_task
end

"""
`print_color(color::Symbol, msg::AbstractString; bold::Bool = false)`

Functionally identical to `Base.print_with_color` except that this works
identically across Julia 0.5 and 0.6.
"""
function print_color(color::Symbol, msg::AbstractString; bold::Bool=false)
    buf = IOBuffer()

    # Engage the color, and optionally the boldness
    print(buf, Base.text_colors[color])
    if bold
        print(buf, "\e[1m")
    end

    # Print the message
    print(buf, msg)

    # Disengage the color, and optionally the boldness
    if bold
        print(buf, "\e[22m")
    end
    print(buf, Base.text_colors[:normal])
    
    # Finally, print this out to stdout
    print(buf)
end