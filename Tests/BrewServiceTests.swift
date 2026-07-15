import Foundation

/// BrewService 文件体积解析测试（parseByteSize 纯函数）
enum BrewServiceTests {
    static func run() {
        print("BrewService parseByteSize:")
        check(parseByteSize("1.5M") == Int64(1.5 * 1024 * 1024), "1.5M")
        check(parseByteSize("100K") == 100 * 1024, "100K")
        check(parseByteSize("2G") == Int64(2) * 1024 * 1024 * 1024, "2G")
        check(parseByteSize("512") == 512, "纯数字按字节")
        check(parseByteSize("nonsense") == 0, "非法输入返回 0")
    }
}
