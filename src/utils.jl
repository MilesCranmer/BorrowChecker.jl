module UtilsModule

using DispatchDoctor: DispatchDoctor

macro _stable(ex)
    return esc(:($(DispatchDoctor).@stable(default_mode = "disable", $ex)))
end

# Analogous to `nothing` but never used to mean something
struct Unused end

# COV_EXCL_START
isunused(::Any) = false
isunused(::Unused) = true
# COV_EXCL_STOP

end
