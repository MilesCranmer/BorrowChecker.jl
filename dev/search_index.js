var documenterSearchIndex = {"docs":
[{"location":"api/#API-Reference","page":"API Reference","title":"API Reference","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"CurrentModule = BorrowChecker","category":"page"},{"location":"api/#Ownership-Macros","page":"API Reference","title":"Ownership Macros","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"@own\n@move\n@clone\n@take\n@take!\n@set","category":"page"},{"location":"api/#BorrowChecker.MacrosModule.@own","page":"API Reference","title":"BorrowChecker.MacrosModule.@own","text":"@own [:mut] x = value\n@own [:mut] x, y, z = (value1, value2, value3)\n@own [:mut] for var in iter\n    # body\nend\n@own [:mut] x  # equivalent to @own [:mut] x = x\n@own [:mut] (x, y)  # equivalent to @own [:mut] (x, y) = (x, y)\n\nCreate a new owned variable. If :mut is specified, the value will be mutable. Otherwise, the value will be immutable.\n\nYou may also use @own in a for loop to create an owned value for each iteration.\n\n\n\n\n\n","category":"macro"},{"location":"api/#BorrowChecker.MacrosModule.@move","page":"API Reference","title":"BorrowChecker.MacrosModule.@move","text":"@move [:mut] new = old\n\nTransfer ownership from one variable to another, invalidating the old variable. If :mut is specified, the destination will be mutable. Otherwise, the destination will be immutable. For isbits types, this will automatically use @clone instead.\n\n\n\n\n\n","category":"macro"},{"location":"api/#BorrowChecker.MacrosModule.@clone","page":"API Reference","title":"BorrowChecker.MacrosModule.@clone","text":"@clone [:mut] new = old\n\nCreate a deep copy of a value, without moving the source. If :mut is specified, the destination will be mutable. Otherwise, the destination will be immutable.\n\n\n\n\n\n","category":"macro"},{"location":"api/#BorrowChecker.MacrosModule.@take","page":"API Reference","title":"BorrowChecker.MacrosModule.@take","text":"@take var\n\nReturns the inner value and does a deepcopy. This does not mark the original as moved.\n\n\n\n\n\n","category":"macro"},{"location":"api/#BorrowChecker.MacrosModule.@take!","page":"API Reference","title":"BorrowChecker.MacrosModule.@take!","text":"@take! var\n\nTake ownership of a value, typically used in function arguments. Returns the inner value and marks the original as moved. For isbits types, this will return a copy and not mark the original as moved.\n\n\n\n\n\n","category":"macro"},{"location":"api/#BorrowChecker.MacrosModule.@set","page":"API Reference","title":"BorrowChecker.MacrosModule.@set","text":"@set x = value\n\nAssign a value to the value of a mutable owned variable itself.\n\n\n\n\n\n","category":"macro"},{"location":"api/#References-and-Lifetimes","page":"API Reference","title":"References and Lifetimes","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"@lifetime\n@ref","category":"page"},{"location":"api/#BorrowChecker.MacrosModule.@lifetime","page":"API Reference","title":"BorrowChecker.MacrosModule.@lifetime","text":"@lifetime a begin\n    @ref ~a rx = x\n    # use refs here\nend\n\nCreate a lifetime scope for references. References created with this lifetime are only valid within the block and are automatically cleaned up when the block exits.\n\n\n\n\n\n","category":"macro"},{"location":"api/#BorrowChecker.MacrosModule.@ref","page":"API Reference","title":"BorrowChecker.MacrosModule.@ref","text":"@ref ~lifetime [:mut] var = value\n@ref ~lifetime [:mut] (var1, var2, ...) = (value1, value2, ...)\n@ref ~lifetime [:mut] for var in iter\n    # body\nend\n\nCreate a reference to an owned value within a lifetime scope. If :mut is specified, creates a mutable reference. Otherwise, creates an immutable reference. Returns a Borrowed{T} or BorrowedMut{T} that forwards access to the underlying value.\n\nwarning: Warning\nThis will not detect aliasing in the iterator.\n\n\n\n\n\n","category":"macro"},{"location":"api/#Types","page":"API Reference","title":"Types","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"BorrowChecker.TypesModule.AbstractOwned\nBorrowChecker.TypesModule.AbstractBorrowed\nOwned\nOwnedMut\nBorrowed\nBorrowedMut\nLazyAccessor\nOrBorrowed\nOrBorrowedMut","category":"page"},{"location":"api/#BorrowChecker.TypesModule.AbstractOwned","page":"API Reference","title":"BorrowChecker.TypesModule.AbstractOwned","text":"AbstractOwned{T}\n\nBase type for all owned value types in the BorrowChecker system.\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.TypesModule.AbstractBorrowed","page":"API Reference","title":"BorrowChecker.TypesModule.AbstractBorrowed","text":"AbstractBorrowed{T}\n\nBase type for all borrowed reference types in the BorrowChecker system.\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.TypesModule.Owned","page":"API Reference","title":"BorrowChecker.TypesModule.Owned","text":"Owned{T}\n\nAn immutable owned value. Common operations:\n\nCreate using @own x = value\nAccess value using @take! (moves) or @take (copies)\nBorrow using @ref\nAccess fields/indices via .field or [indices...] (returns LazyAccessor)\n\nOnce moved, the value cannot be accessed again.\n\nInternal fields (not part of public API):\n\nvalue::T: The contained value\nmoved::Bool: Whether the value has been moved\nimmutable_borrows::Int: Count of active immutable borrows\nsymbol::Symbol: Variable name for error reporting\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.TypesModule.OwnedMut","page":"API Reference","title":"BorrowChecker.TypesModule.OwnedMut","text":"OwnedMut{T}\n\nA mutable owned value. Common operations:\n\nCreate using @own :mut x = value\nAccess value using @take! (moves) or @take (copies)\nModify using @set\nBorrow using @ref or @ref :mut\nAccess fields/indices via .field or [indices...] (returns LazyAccessor)\n\nOnce moved, the value cannot be accessed again.\n\nInternal fields (not part of public API):\n\nvalue::T: The contained value\nmoved::Bool: Whether the value has been moved\nimmutable_borrows::Int: Count of active immutable borrows\nmutable_borrows::Int: Count of active mutable borrows\nsymbol::Symbol: Variable name for error reporting\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.TypesModule.Borrowed","page":"API Reference","title":"BorrowChecker.TypesModule.Borrowed","text":"Borrowed{T,O<:AbstractOwned}\n\nAn immutable reference to an owned value. Common operations:\n\nCreate using @ref lt x = value\nAccess value using @take (copies)\nAccess fields/indices via .field or [indices...] (returns LazyAccessor)\n\nMultiple immutable references can exist simultaneously. The reference is valid only within its lifetime scope.\n\nInternal fields (not part of public API):\n\nvalue::T: The referenced value\nowner::O: The original owned value\nlifetime::Lifetime: The scope in which this reference is valid\nsymbol::Symbol: Variable name for error reporting\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.TypesModule.BorrowedMut","page":"API Reference","title":"BorrowChecker.TypesModule.BorrowedMut","text":"BorrowedMut{T,O<:OwnedMut}\n\nA mutable reference to an owned value. Common operations:\n\nCreate using @ref lt :mut x = value\nAccess value using @take (copies)\nAccess fields/indices via .field or [indices...] (returns LazyAccessor)\n\nOnly one mutable reference can exist at a time, and no immutable references can exist simultaneously.\n\nInternal fields (not part of public API):\n\nvalue::T: The referenced value\nowner::O: The original owned value\nlifetime::Lifetime: The scope in which this reference is valid\nsymbol::Symbol: Variable name for error reporting\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.TypesModule.LazyAccessor","page":"API Reference","title":"BorrowChecker.TypesModule.LazyAccessor","text":"LazyAccessor{T,P,S,O<:Union{AbstractOwned,AbstractBorrowed}}\n\nA lazy accessor for properties or indices of owned or borrowed values. Maintains ownership semantics while allowing property/index access without copying or moving.\n\nCreated automatically when accessing properties or indices of owned/borrowed values:\n\n@own x = (a=1, b=2)\nx.a  # Returns a LazyAccessor\n\nInternal fields (not part of public API):\n\nparent::P: The parent value being accessed\nproperty::S: The property/index being accessed\nproperty_type::Type{T}: Type of the accessed property/index\ntarget::O: The original owned/borrowed value\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.TypesModule.OrBorrowed","page":"API Reference","title":"BorrowChecker.TypesModule.OrBorrowed","text":"OrBorrowed{T}\n\nType alias for accepting either a value of type T or a borrowed reference to it.\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.TypesModule.OrBorrowedMut","page":"API Reference","title":"BorrowChecker.TypesModule.OrBorrowedMut","text":"OrBorrowedMut{T}\n\nType alias for accepting either a value of type T or a mutable borrowed reference to it.\n\n\n\n\n\n","category":"type"},{"location":"api/#Traits","page":"API Reference","title":"Traits","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"is_static","category":"page"},{"location":"api/#BorrowChecker.StaticTraitModule.is_static","page":"API Reference","title":"BorrowChecker.StaticTraitModule.is_static","text":"is_static(x)\n\nThis trait is used to determine if we can safely @take! a value without marking the original as moved.\n\nThis is somewhat analogous to the Copy trait in Rust, although because Julia immutables are truly immutable, we actually do not need to copy on these.\n\nFor the most part, this is equal to isbits, but it also includes things like Symbol and Type{T} (recursively), which are not isbits, but which are immutable.\n\n\n\n\n\n","category":"function"},{"location":"api/#Errors","page":"API Reference","title":"Errors","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"BorrowError\nMovedError\nBorrowRuleError\nSymbolMismatchError\nExpiredError","category":"page"},{"location":"api/#BorrowChecker.ErrorsModule.BorrowError","page":"API Reference","title":"BorrowChecker.ErrorsModule.BorrowError","text":"abstract type BorrowError <: Exception end\n\nBase type for all errors related to borrow checking rules.\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.ErrorsModule.MovedError","page":"API Reference","title":"BorrowChecker.ErrorsModule.MovedError","text":"MovedError <: BorrowError\n\nError thrown when attempting to use a value that has been moved.\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.ErrorsModule.BorrowRuleError","page":"API Reference","title":"BorrowChecker.ErrorsModule.BorrowRuleError","text":"BorrowRuleError <: BorrowError\n\nError thrown when attempting to violate borrow checking rules, such as having multiple mutable references.\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.ErrorsModule.SymbolMismatchError","page":"API Reference","title":"BorrowChecker.ErrorsModule.SymbolMismatchError","text":"SymbolMismatchError <: BorrowError\n\nError thrown when attempting to reassign a variable without using proper ownership transfer mechanisms.\n\n\n\n\n\n","category":"type"},{"location":"api/#BorrowChecker.ErrorsModule.ExpiredError","page":"API Reference","title":"BorrowChecker.ErrorsModule.ExpiredError","text":"ExpiredError <: BorrowError\n\nError thrown when attempting to use a reference whose lifetime has expired.\n\n\n\n\n\n","category":"type"},{"location":"api/#Experimental-Features","page":"API Reference","title":"Experimental Features","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"BorrowChecker.Experimental.@managed","category":"page"},{"location":"api/#BorrowChecker.Experimental.@managed","page":"API Reference","title":"BorrowChecker.Experimental.@managed","text":"@managed f()\n\nRun code with automatic ownership transfer enabled. Any Owned or OwnedMut arguments passed to functions within the block will automatically have their ownership transferred using the equivalent of @take!.\n\nwarning: Warning\nThis is an experimental feature and may change or be removed in future versions.\n\n\n\n\n\n","category":"macro"},{"location":"api/#Internals","page":"API Reference","title":"Internals","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"Normally, you should rely on OrBorrowed and OrBorrowedMut to work with borrowed values, or use @take and @take! to unwrap owned values. However, for convenience, it might be useful to define functions on Owned and OwnedMut types, if you are confident that your operation will not \"move\" the input or return a view of it.","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"Many functions in Base are already overloaded. But if you need to define your own, you can do so by using the request_value function and the AllWrappers type union.","category":"page"},{"location":"api/#Core-Types","page":"API Reference","title":"Core Types","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"AllWrappers{T}: A type union that includes all wrapper types (Owned{T}, OwnedMut{T}, Borrowed{T}, BorrowedMut{T}, and LazyAccessor{T}). This is used to write generic methods that work with any wrapped value.","category":"page"},{"location":"api/#Core-Functions","page":"API Reference","title":"Core Functions","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"request_value(x, Val(:read)): Request read access to a wrapped value\nrequest_value(x, Val(:write)): Request write access to a wrapped value","category":"page"},{"location":"api/#Examples","page":"API Reference","title":"Examples","text":"","category":"section"},{"location":"api/","page":"API Reference","title":"API Reference","text":"Here's how common operations are overloaded:","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"Binary operations (like *) that only need read access:","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"function Base.:(*)(l::AllWrappers{<:Number}, r::AllWrappers{<:Number})\n    return Base.:(*)(request_value(l, Val(:read)), request_value(r, Val(:read)))\nend","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"Mutating operations (like pop!) that need write access:","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"function Base.pop!(r::AllWrappers)\n    return Base.pop!(request_value(r, Val(:write)))\nend","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"The request_value function performs safety checks before allowing access:","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"For read access: Verifies the value hasn't been moved\nFor write access: Verifies the value is mutable and not borrowed","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"Note that for operations that need write access, and return a view of the input, it is wise to modify the standard output to return nothing instead, which is what we do for push!:","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"function Base.push!(r::AllWrappers, items...)\n    Base.push!(request_value(r, Val(:write)), items...)\n    return nothing\nend","category":"page"},{"location":"api/","page":"API Reference","title":"API Reference","text":"While this violates the expected return type, it is a necessary evil for safety. The nothing return will cause loud errors if you have code that relies on this design. This is good! Loud bugs are collaborators; silent bugs are saboteurs.","category":"page"},{"location":"","page":"Home","title":"Home","text":"CurrentModule = BorrowChecker","category":"page"},{"location":"#BorrowChecker.jl","page":"Home","title":"BorrowChecker.jl","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"(Image: Dev) (Image: Build Status) (Image: Coverage)","category":"page"},{"location":"","page":"Home","title":"Home","text":"This package demonstrates Rust-like ownership and borrowing semantics in Julia through a macro-based system that performs runtime checks. This tool is mainly to be used in development and testing to flag memory safety issues, and help you design safer code.","category":"page"},{"location":"","page":"Home","title":"Home","text":"[!WARNING] BorrowChecker.jl does not promise memory safety. This library simulates aspects of Rust's ownership model, but it does not do this at a compiler level, and does not do this with any of the same guarantees. Furthermore, BorrowChecker.jl heavily relies on the user's cooperation, and will not prevent you from misusing it, or from mixing it with regular Julia code.","category":"page"},{"location":"#Usage","page":"Home","title":"Usage","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"In Julia, objects exist independently of the variables that refer to them. When you write x = [1, 2, 3] in Julia, the actual object lives in memory completely independently of the symbol, and you can refer to it from as many variables as you want without issue:","category":"page"},{"location":"","page":"Home","title":"Home","text":"x = [1, 2, 3]\ny = x\nprintln(length(x))\n# 3","category":"page"},{"location":"","page":"Home","title":"Home","text":"Once there are no more references to the object, the \"garbage collector\" will work to free the memory.","category":"page"},{"location":"","page":"Home","title":"Home","text":"Rust is much different. For example, the equivalent code is invalid in Rust","category":"page"},{"location":"","page":"Home","title":"Home","text":"let x = vec![1, 2, 3];\nlet y = x;\nprintln!(\"{}\", x.len());\n// error[E0382]: borrow of moved value: `x`","category":"page"},{"location":"","page":"Home","title":"Home","text":"Rust refuses to compile this code. Why? Because in Rust, objects (vec![1, 2, 3]) are owned by variables. When you write let y = x, the ownership of vec![1, 2, 3] is moved to y. Now x is no longer allowed to access it.","category":"page"},{"location":"","page":"Home","title":"Home","text":"To fix this, we would either write","category":"page"},{"location":"","page":"Home","title":"Home","text":"let y = x.clone();\n// OR\nlet y = &x;","category":"page"},{"location":"","page":"Home","title":"Home","text":"to either create a copy of the vector, or borrow x using the & operator to create a reference. You can create as many references as you want, but there can only be one original object.","category":"page"},{"location":"","page":"Home","title":"Home","text":"The purpose of this \"ownership\" paradigm is to improve safety of code. Especially in complex, multithreaded codebases, it is really easy to shoot yourself in the foot and modify objects which are \"owned\" (editable) by something else. Rust's ownership and lifetime model makes it so that you can prove memory safety of code! Standard thread races are literally impossible. (Assuming you are not using unsafe { ... } to disable safety features, or rust itself has a bug, or a cosmic ray hits your PC!)","category":"page"},{"location":"","page":"Home","title":"Home","text":"In BorrowChecker.jl, we demonstrate a very simple implementation of some of these core ideas. The aim is to build a development layer that, eventually, can help prevent a few classes of memory safety issues, without affecting runtime behavior of code. The above example, with BorrowChecker.jl, would look like this:","category":"page"},{"location":"","page":"Home","title":"Home","text":"using BorrowChecker\n\n@own x = [1, 2, 3]\n@own y = x\nprintln(length(x))\n# ERROR: Cannot use x: value has been moved","category":"page"},{"location":"","page":"Home","title":"Home","text":"You see, the @own operation has bound the variable x with the object [1, 2, 3]. The second operation then moves the object to y, and flips the .moved flag on x so it can no longer be used by regular operations.","category":"page"},{"location":"","page":"Home","title":"Home","text":"The equivalent fixes would respectively be:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@clone y = x\n# OR\n@lifetime a begin\n    @ref ~a y = x\n    #= operations on reference =#\nend","category":"page"},{"location":"","page":"Home","title":"Home","text":"Note that BorrowChecker.jl does not prevent you from cheating the system and using y = x[1]. To use this library, you will need to buy in to the system to get the most out of it. But the good news is that you can introduce it in a library gradually:  add @own, @move, etc., inside a single function, and call @take! when passing objects to external functions. And for convenience, a variety of standard library functions will automatically forward operations on the underlying objects.","category":"page"},{"location":"","page":"Home","title":"Home","text":"[1]: Luckily, the library has a way to try flag such mistakes by recording symbols used in the macro.","category":"page"},{"location":"#API","page":"Home","title":"API","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"[!CAUTION] The API is under active development and may change in future versions.","category":"page"},{"location":"#Basics","page":"Home","title":"Basics","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"@own [:mut] x = value: Create a new owned value (mutable if :mut is specified)\nThese are Owned{T} and OwnedMut{T} objects, respectively.\nYou can use @own [:mut] x as a shorthand for @own [:mut] x = x to create owned values at the start of a function.\n@move [:mut] new = old: Transfer ownership from one variable to another (mutable destination if :mut is specified). Note that this is simply a more explicit version of @own for moving values.\n@clone [:mut] new = old: Create a deep copy of a value without moving the source (mutable destination if :mut is specified).\n@take[!] var: Unwrap an owned value. Using @take! will mark the original as moved, while @takewill perform a copy.","category":"page"},{"location":"#References-and-Lifetimes","page":"Home","title":"References and Lifetimes","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"@lifetime lt begin ... end: Create a scope for references whose lifetimes lt are the duration of the block\n@ref ~lt [:mut] var = value: Create a reference, for the duration of lt, to owned value value and assign it to var (mutable if :mut is specified)\nThese are Borrowed{T} and BorrowedMut{T} objects, respectively. Use these in the signature of any function you wish to make compatible with references. In the signature you can use OrBorrowed{T} and OrBorrowedMut{T} to also allow regular T.","category":"page"},{"location":"#Automatic-Ownership-Transfer","page":"Home","title":"Automatic Ownership Transfer","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"BorrowChecker.Experimental.@managed begin ... end: create a scope where contextual dispatch is performed using Cassette.jl: recursively, all functions (in all dependencies) are automatically modified to apply @take! to any Owned{T} or OwnedMut{T} input arguments.\nNote: this is an experimental feature that may change or be removed in future versions. It relies on compiler internals and seems to break on certain functions (like SIMD operations).","category":"page"},{"location":"#Assignment","page":"Home","title":"Assignment","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"@set x = value: Assign a new value to an existing owned mutable variable","category":"page"},{"location":"#Loops","page":"Home","title":"Loops","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"@own [:mut] for var in iter: Create a loop over an iterable, assigning ownership of each element to var. The original iter is marked as moved.\n@ref ~lt [:mut] for var in iter: Create a loop over an owned iterable, generating references to each element, for the duration of lt.","category":"page"},{"location":"#Disabling-BorrowChecker","page":"Home","title":"Disabling BorrowChecker","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"You can disable BorrowChecker.jl's functionality by setting borrow_checker = false in your LocalPreferences.toml file (using Preferences.jl). When disabled, all macros like @own, @move, etc., will simply pass through their arguments without any ownership or borrowing checks.","category":"page"},{"location":"","page":"Home","title":"Home","text":"You can also set the default behavior from within a module:","category":"page"},{"location":"","page":"Home","title":"Home","text":"module MyModule\n    using BorrowChecker: disable_by_default!\n\n    disable_by_default!(@__MODULE__)\n    #= Other code =#\nend","category":"page"},{"location":"","page":"Home","title":"Home","text":"This can then be overridden by the LocalPreferences.toml file.","category":"page"},{"location":"#Further-Examples","page":"Home","title":"Further Examples","text":"","category":"section"},{"location":"#Basic-Ownership","page":"Home","title":"Basic Ownership","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Let's look at the basic ownership system. When you create an owned value, it's immutable by default:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own x = [1, 2, 3]\npush!(x, 4)  # ERROR: Cannot write to immutable","category":"page"},{"location":"","page":"Home","title":"Home","text":"For mutable values, use the :mut flag:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own :mut data = [1, 2, 3]\npush!(data, 4)  # Works! data is mutable","category":"page"},{"location":"","page":"Home","title":"Home","text":"Note that various functions have been overloaded with the write access settings, such as push!, getindex, etc.","category":"page"},{"location":"","page":"Home","title":"Home","text":"The @own macro creates an Owned{T} or OwnedMut{T} object. Most functions will not be written to accept these, so you can use @take (copying) or @take! (moving) to extract the owned value:","category":"page"},{"location":"","page":"Home","title":"Home","text":"# Functions that expect regular Julia types:\npush_twice!(x::Vector{Int}) = (push!(x, 4); push!(x, 5); x)\n\n@own x = [1, 2, 3]\n@own y = push_twice!(@take!(x))  # Moves ownership of x\n\npush!(x, 4)  # ERROR: Cannot use x: value has been moved","category":"page"},{"location":"","page":"Home","title":"Home","text":"However, for recursively immutable types (like tuples of integers), @take! is smart enough to know that the original can't change, and thus it won't mark a moved:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own point = (1, 2)\nsum1 = write_to_file(@take!(point))  # point is still usable\nsum2 = write_to_file(@take!(point))  # Works again!","category":"page"},{"location":"","page":"Home","title":"Home","text":"This is the same behavior as in Rust (c.f., the Copy trait).","category":"page"},{"location":"","page":"Home","title":"Home","text":"There is also the @take(...) macro which never marks the original as moved, and performs a deepcopy when needed:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own :mut data = [1, 2, 3]\n@own total = sum_vector(@take(data))  # Creates a copy\npush!(data, 4)  # Original still usable","category":"page"},{"location":"","page":"Home","title":"Home","text":"Note also that for improving safety when using BorrowChecker.jl, the macro will actually store the symbol used. This helps catch mistakes like:","category":"page"},{"location":"","page":"Home","title":"Home","text":"julia> @own x = [1, 2, 3];\n\njulia> y = x;  # Unsafe! Should use @clone, @move, or @own\n\njulia> @take(y)\nERROR: Variable `y` holds an object that was reassigned from `x`.","category":"page"},{"location":"","page":"Home","title":"Home","text":"This won't catch all misuses but it can help prevent some.","category":"page"},{"location":"#References-and-Lifetimes-2","page":"Home","title":"References and Lifetimes","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"References let you temporarily borrow values. This is useful for passing values to functions without moving them. These are created within an explicit @lifetime block:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own :mut data = [1, 2, 3]\n\n@lifetime lt begin\n    @ref ~lt r = data\n    @ref ~lt r2 = data  # Can create multiple _immutable_ references!\n    @test r == [1, 2, 3]\n\n    # While ref exists, data can't be modified:\n    data[1] = 4 # ERROR: Cannot write original while immutably borrowed\nend\n\n# After lifetime ends, we can modify again!\ndata[1] = 4","category":"page"},{"location":"","page":"Home","title":"Home","text":"Just like in Rust, while you can create multiple immutable references, you can only have one mutable reference at a time:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own :mut data = [1, 2, 3]\n\n@lifetime lt begin\n    @ref ~lt :mut r = data\n    @ref ~lt :mut r2 = data  # ERROR: Cannot create mutable reference: value is already mutably borrowed\n    @ref ~lt r2 = data  # ERROR: Cannot create immutable reference: value is mutably borrowed\n\n    # Can modify via mutable reference:\n    r[1] = 4\nend","category":"page"},{"location":"","page":"Home","title":"Home","text":"When you need to pass immutable references of a value to a function, you would modify the signature to accept a Borrowed{T} type. This is similar to the &T syntax in Rust. And, similarly, BorrowedMut{T} is similar to &mut T.","category":"page"},{"location":"","page":"Home","title":"Home","text":"Don't worry about references being used after the lifetime ends, because the lt variable will be expired!","category":"page"},{"location":"","page":"Home","title":"Home","text":"julia> @own x = 1\n       @own :mut cheating = []\n       @lifetime lt begin\n           @ref ~lt r = x\n           push!(cheating, r)\n       end\n       \n\njulia> @show cheating[1]\nERROR: Cannot use r: value's lifetime has expired","category":"page"},{"location":"","page":"Home","title":"Home","text":"This makes the use of references inside threads safe, because the threads must finish inside the scope of the lifetime.","category":"page"},{"location":"","page":"Home","title":"Home","text":"Though we can't create multiple mutable references, you are allowed to create multiple mutable references to elements of a collection via the @ref ~lt for syntax:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own :mut data = [[1], [2], [3]]\n\n@lifetime lt begin\n    @ref ~lt :mut for r in data\n        push!(r, 4)\n    end\nend\n\n@show data  # [[1, 4], [2, 4], [3, 4]]","category":"page"},{"location":"#Automatic-Ownership","page":"Home","title":"Automatic Ownership","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"The (experimental) @managed block can be used to perform borrow checking automatically. It basically transforms all functions, everywhere, to perform @take! on function calls that take Owned{T} or OwnedMut{T} arguments:","category":"page"},{"location":"","page":"Home","title":"Home","text":"struct Particle\n    position::Vector{Float64}\n    velocity::Vector{Float64}\nend\n\nfunction update!(p::Particle)\n    p.position .+= p.velocity\n    return p\nend","category":"page"},{"location":"","page":"Home","title":"Home","text":"With @managed, you don't need to manually move ownership:","category":"page"},{"location":"","page":"Home","title":"Home","text":"julia> using BorrowChecker.Experimental: @managed\n\njulia> @own :mut p = Particle([0.0, 0.0], [1.0, 1.0])\n       @managed begin\n           update!(p)\n       end;\n\njulia> p\n[moved]","category":"page"},{"location":"","page":"Home","title":"Home","text":"This works via Cassette.jl overdubbing, which recursively modifies all function calls in the entire call stack - not just the top-level function, but also any functions it calls, and any functions those functions call, and so on. But do note that this is very experimental as it modifies the compilation itself. For more robust usage, just use @take! manually.","category":"page"},{"location":"","page":"Home","title":"Home","text":"This also works with nested field access, just like in Rust:","category":"page"},{"location":"","page":"Home","title":"Home","text":"struct Container\n    x::Vector{Int}\nend\n\nf!(x::Vector{Int}) = push!(x, 3)\n\n@own a = Container([2])\n@managed begin\n    f!(a.x)  # Container ownership handled automatically\nend\n\n@take!(a)  # ERROR: Cannot use a: value has been moved","category":"page"},{"location":"#Mutating-Owned-Values","page":"Home","title":"Mutating Owned Values","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"For mutating an owned value directly, you should use the @set macro, which prevents the creation of a new owned value.","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own :mut local_counter = 0\nfor _ in 1:10\n    @set local_counter = local_counter + 1\nend\n@take! local_counter","category":"page"},{"location":"","page":"Home","title":"Home","text":"But note that if you have a mutable struct, you can just use setproperty! as normal:","category":"page"},{"location":"","page":"Home","title":"Home","text":"mutable struct A\n    x::Int\nend\n\n@own :mut a = A(0)\nfor _ in 1:10\n    a.x += 1\nend\n# Move it to an immutable:\n@own a_imm = a","category":"page"},{"location":"","page":"Home","title":"Home","text":"And, as expected:","category":"page"},{"location":"","page":"Home","title":"Home","text":"julia> a_imm.x += 1\nERROR: Cannot write to immutable\n\njulia> a.x += 1\nERROR: Cannot use a: value has been moved","category":"page"},{"location":"#Cloning-Values","page":"Home","title":"Cloning Values","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Sometimes you want to create a completely independent copy of a value. While you could use @own new = @take(old), the @clone macro provides a clearer way to express this intent:","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own :mut original = [1, 2, 3]\n@clone copy = original  # Creates an immutable deep copy\n@clone :mut mut_copy = original  # Creates a mutable deep copy\n\npush!(mut_copy, 4)  # Can modify the mutable copy\n@test_throws BorrowRuleError push!(copy, 4)  # Can't modify the immutable copy\npush!(original, 5)  # Original still usable\n\n@test original == [1, 2, 3, 5]\n@test copy == [1, 2, 3]\n@test mut_copy == [1, 2, 3, 4]","category":"page"},{"location":"","page":"Home","title":"Home","text":"Another macro is @move, which is a more explicit version of @own new = @take!(old):","category":"page"},{"location":"","page":"Home","title":"Home","text":"@own :mut original = [1, 2, 3]\n@move new = original  # Creates an immutable deep copy\n\n@test_throws MovedError push!(original, 4)","category":"page"},{"location":"","page":"Home","title":"Home","text":"Note that @own new = old will also work as a convenience, but @move is more explicit and also asserts that the new value is owned.","category":"page"},{"location":"#Introducing-BorrowChecker.jl-to-Your-Codebase","page":"Home","title":"Introducing BorrowChecker.jl to Your Codebase","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"When introducing BorrowChecker.jl to your codebase, the first thing is to @own all variables at the top of a particular function. The single-arg version of @own is particularly useful in this case:","category":"page"},{"location":"","page":"Home","title":"Home","text":"function process_data(x, y, z)\n    @own x, y\n    @own :mut z\n\n    #= body =#\nend","category":"page"},{"location":"","page":"Home","title":"Home","text":"This pattern is useful for generic functions because if you pass an owned variable as either x, y, or z, the original function will get marked as moved.","category":"page"},{"location":"","page":"Home","title":"Home","text":"The next pattern that is useful is to use OrBorrowed{T} (basically ==Union{T,Borrowed{<:T}}) and OrBorrowedMut{T} aliases for extending signatures. Let's say you have some function:","category":"page"},{"location":"","page":"Home","title":"Home","text":"struct Bar{T}\n    x::Vector{T}\nend\n\nfunction foo(bar::Bar{T}) where {T}\n    sum(bar.x)\nend","category":"page"},{"location":"","page":"Home","title":"Home","text":"Now, you'd like to modify this so that it can accept references to Bar objects from other functions. Since foo doesn't need to mutate bar, we can modify this as follows:","category":"page"},{"location":"","page":"Home","title":"Home","text":"function foo(bar::OrBorrowed{Bar{T}}) where {T}\n    sum(bar.x)\nend","category":"page"},{"location":"","page":"Home","title":"Home","text":"Thus, the full process_data function might be something like:","category":"page"},{"location":"","page":"Home","title":"Home","text":"function process_data(x, y, z)\n    @own x, y\n    @own :mut z\n\n    @own total = @lifetime lt begin\n        @ref ~lt r1 = z\n        @ref ~lt r2 = z\n\n        @own tasks = [\n            Threads.@spawn(foo(r1))\n            Threads.@spawn(foo(r2))\n        ]\n        sum(map(fetch, @take!(tasks)))\n    end\nend","category":"page"},{"location":"","page":"Home","title":"Home","text":"Because we modified foo to accept OrBorrowed{Bar{T}}, we can safely pass immutable references to z, and it will not be marked as moved in the original context!","category":"page"},{"location":"","page":"Home","title":"Home","text":"Immutable references are safe to pass in a multi-threaded context, so doubles as a good way to prevent unintended thread races.","category":"page"}]
}
