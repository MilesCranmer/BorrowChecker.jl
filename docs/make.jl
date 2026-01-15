using Documenter
using BorrowChecker

DocMeta.setdocmeta!(BorrowChecker, :DocTestSetup, :(using BorrowChecker); recursive=true)

# Read and process README.md
readme = open(dirname(@__FILE__) * "/../README.md") do io
    read(io, String)
end

# Replace HTML image tags with markdown
readme = replace(readme, r"<img src=\"([^\"]+)\"[^>]+>.*" => s"![](\1)")

# Remove div tags
readme = replace(readme, r"<[/]?div.*" => s"")

# Create the index.md
open(dirname(@__FILE__) * "/src/index.md", "w") do io
    # Add meta information
    write(
        io,
        """
```@meta
CurrentModule = BorrowChecker
```

""",
    )
    write(io, readme)
end

makedocs(;
    modules=[BorrowChecker],
    authors="Miles Cranmer <miles.cranmer@gmail.com> and contributors",
    repo="https://github.com/MilesCranmer/BorrowChecker.jl/blob/{commit}{path}#{line}",
    sitename="BorrowChecker.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://ai.damtp.cam.ac.uk/borrowcheckerjl",
        edit_link="main",
        assets=String[],
        repolink="https://github.com/mcranmer/BorrowChecker.jl",
    ),
    pages=["Home" => "index.md", "`@auto`" => "auto.md", "API Reference" => "api.md"],
    warnonly=[:missing_docs],  # Allow missing docstrings
)

deploydocs(; repo="github.com/MilesCranmer/BorrowChecker.jl", devbranch="main")

# Mirror to DAMTP:
if haskey(ENV, "DOCUMENTER_KEY_CAM")
    ENV["DOCUMENTER_KEY"] = ENV["DOCUMENTER_KEY_CAM"]
    ENV["GITHUB_REPOSITORY"] = "ai-damtp-cam-ac-uk/borrowcheckerjl.git"
    deploydocs(; repo="github.com/ai-damtp-cam-ac-uk/borrowcheckerjl.git", devbranch="main")
end
