# During handling of an execute_request (when execute_msg is !nothing),
# we redirect STDOUT and STDERR into "stream" messages sent to the IPython
# front-end.

# logging in verbose mode goes to original stdio streams.  Use macros
# so that we do not even evaluate the arguments in no-verbose modes
macro vprintln(x...)
    quote
        if verbose::Bool
            println(orig_STDOUT, $(x...))
        end
    end
end
macro verror_show(e, bt)
    quote
        if verbose::Bool
            showerror(orig_STDERR, $e, $bt)
        end
    end
end

function send_stream(rd::IO, name::AbstractString)
    nb = nb_available(rd)
    if nb > 0
        d = readbytes(rd, nb)
        s = try
            bytestring(d)
        catch
            # FIXME: what should we do here?
            string("<ERROR: invalid UTF8 data ", d, ">")
        end
        send_ipython(publish,
                     msg_pub(execute_msg, "stream",
                             @compat Dict("name" => name, "text" => s)))
    end
end

function watch_stream(rd::IO, name::AbstractString)
    try
        while !eof(rd) # blocks until something is available
            send_stream(rd, name)
            sleep(0.1) # a little delay to accumulate output
        end
    catch e
        # the IPython manager may send us a SIGINT if the user
        # chooses to interrupt the kernel; don't crash on this
        if isa(e, InterruptException)
            watch_stream(rd, name)
        else
            rethrow()
        end
    end
end

# this is hacky: we overload some of the I/O functions on pipe endpoints
# in order to fix some interactions with stdio.
if VERSION < v"0.4.0-dev+6987" # JuliaLang/julia#12739
    const StdioPipe = Base.Pipe
else
    const StdioPipe = Base.PipeEndpoint
end

# IJulia issue #42: there doesn't seem to be a good way to make a task
# that blocks until there is a read request from STDIN ... this makes
# it very hard to properly redirect all reads from STDIN to pyin messages.
# In the meantime, however, we can just hack it so that readline works:
import Base.readline
function readline(io::StdioPipe)
    if io == STDIN
        if !execute_msg.content["allow_stdin"]
            error("IJulia: this front-end does not implement stdin")
        end
        send_ipython(raw_input,
                     msg_reply(execute_msg, "input_request",
                               @compat Dict("prompt"=>"STDIN> ", "password"=>false)))
        while true
            msg = recv_ipython(raw_input)
            if msg.header["msg_type"] == "input_reply"
                return msg.content["value"]
            else
                error("IJulia error: unknown stdin reply")
            end
        end
    else
        invoke(readline, (super(StdioPipe),), io)
    end
end

function watch_stdio()
    @async watch_stream(read_stdout, "stdout")
    if capture_stderr
        @async watch_stream(read_stderr, "stderr")
    end
end

import Base.flush
function flush(io::StdioPipe)
    invoke(flush, (super(StdioPipe),), io)
    # send any available bytes to IPython (don't use readavailable,
    # since we don't want to block).
    if io == STDOUT
        send_stream(read_stdout, "stdout")
    elseif io == STDERR
        send_stream(read_stderr, "stderr")
    end
end
