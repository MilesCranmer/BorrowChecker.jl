module UtilsModule

# Analogous to `nothing` but never used to mean something
struct Unused end

isunused(::Any) = false
isunused(::Unused) = true

end
