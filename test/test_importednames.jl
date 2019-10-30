module TestImportedNames

using AutoImports: importednames
using CSTParser: CSTParser
using Test

inames(code) = importednames(CSTParser.parse(CSTParser.ParseState(code), true)[1].args[1])

@testset begin
    @test inames("using A") == ["A"]
    @test inames("using A: B, C") == ["B", "C"]
    @test inames("using .A: B, C") == ["B", "C"]
    @test inames("using A.B") == ["B"]
    @test inames("using A.B: C") == ["C"]
end

end  # module
