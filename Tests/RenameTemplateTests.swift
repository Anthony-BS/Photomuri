import Foundation

@main
struct RenameTemplateTests {
    static func main() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 10,
                                                              hour: 10, minute: 22, second: 45))!
        func render(_ template: String, _ index: Int = 1, _ stem: String = "DSC_1234",
                    _ ext: String = "JPG") -> String {
            RenameTemplateParser.render(template: template, date: date, originalStem: stem,
                                        sequenceIndex: index, fileExtension: ext)
        }
        assert(render(#"YYMMDD_hhmmss [original]_[s5]_"abc""#) == "260910_102245 DSC_1234_00001_abc.JPG")
        for (index, expected) in [(1, "00001"), (99999, "99999"), (100000, "00001"), (100001, "00002"), (0, "00001")] {
            assert(render("[s5]", index) == expected + ".JPG")
        }
        print("PASS: requested example and s5 rollover")
        for (width, maximum) in [(1, 9), (2, 99), (3, 999), (4, 9999)] {
            assert(render("[s\(width)]", maximum) == String(maximum) + ".JPG")
            assert(render("[s\(width)]", maximum + 1) == String(format: "%0\(width)d.JPG", 1))
        }
        assert(render("YYMMDD_hhmmss [original]") == "260910_102245 DSC_1234.JPG")
        assert(render("YYYYMMDD_hhmmss") == "20260910_102245.JPG")
        print("PASS: existing template and s1-s4 regression")
        assert(render(#""YY_MM [s5] [original]"_[s5]"#) == "YY_MM [s5] [original]_00001.JPG")
        assert(render(#""한글 🎞"_"abc"_YYYY"#) == "한글 🎞_abc_2026.JPG")
        assert(render(#"""[s5]"""#) == "00001.JPG")
        assert(render("[original]_[s5]", 1, "YY_[s5]") == "YY_[s5]_00001.JPG")
        assert(render(#""abc""#, 1, "unused", "") == "abc")
        print("PASS: quoted text, Unicode, empty literals, inserted stem isolation")
        assert(RenameTemplateValidator.validate(#"YYMMDD [s5]_"abc""#).isValid)
        assert(!RenameTemplateValidator.validate(#"YYMMDD_"abc"#).isValid)
        assert(!RenameTemplateValidator.validate("[s6]").isValid)
        assert(RenameTemplateValidator.validate(#""[s6]"_[s5]"#).isValid)
        assert(RenameTemplateValidator.validate(#""[original] [s5]""#).warningMessage != nil)
        assert(RenameTemplateValidator.validate("[s5]").warningMessage == nil)
        assert(!RenameTemplateValidator.validate("").isValid)
        print("PASS: validator shares quote boundaries and rejects missing closing quote")
    }
}
