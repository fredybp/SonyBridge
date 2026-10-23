//
//  XM5Fixtures.swift
//  Real replies from a WH-1000XM5 (firmware 2.5.1), copied from SonyBridge's "Copy diagnostics".
//

func hex(_ string: String) -> [UInt8] {
    string.split(separator: " ").map { UInt8($0, radix: 16)! }
}

enum XM5 {
    static let initReply = hex("01 00 03 00 20 16 00 00")
    static let supportFunctions = hex("07 00 06 41 25 50 ff f2 ff 32 03 31 ff f8 1e")
    static let generalSettingD1 = hex("d1 d1 00 01 13 54 4f 55 43 48 5f 50 41 4e 45 4c 5f 53 45 54 54 49 4e 47 00")
    static let generalSettingD2 = hex("""
        d1 d2 00 01 12 4d 55 4c 54 49 50 4f 49 4e 54 5f 53 45 54 54 49 4e 47 29 4d 55 4c 54 49 50 4f 49 4e 54 5f 53 45 \
        54 54 49 4e 47 5f 53 55 4d 4d 41 52 59 5f 4c 44 41 43 5f 41 56 41 49 4c 41 42 4c 45
        """)
    static let multipointOn = hex("d7 d2 00 00")
    static let playbackFixed = hex("37 01 00")
    static let deviceList = hex("""
        37 02 05 41 43 3a 30 37 3a 37 35 3a 32 32 3a 44 34 3a 36 37 02 38 01 0c 17 46 72 65 64 27 73 20 57 6f 72 6b 20 \
        4d 61 63 42 6f 6f 6b 20 50 72 6f 39 43 3a 44 41 3a 41 38 3a 35 36 3a 30 31 3a 33 45 01 7a 02 0c 12 46 72 65 64 \
        65 72 69 63 6f 27 73 20 69 50 68 6f 6e 65 33 43 3a 41 39 3a 41 42 3a 32 45 3a 39 32 3a 36 41 00 ff ff ff 11 4e \
        69 6e 74 65 6e 64 6f 20 53 77 69 74 63 68 20 32 34 34 3a 31 42 3a 38 38 3a 34 42 3a 35 42 3a 37 32 00 ff ff ff \
        0b 46 72 65 64 64 79 20 69 50 61 64 38 34 3a 32 46 3a 35 37 3a 33 31 3a 35 36 3a 32 43 00 ff ff ff 12 46 72 65 \
        64 27 73 20 4d 61 63 42 6f 6f 6b 20 50 72 6f 02
        """)

    static let workMac = "AC:07:75:22:D4:67"
    static let iPhone = "9C:DA:A8:56:01:3E"
    static let nintendoSwitch = "3C:A9:AB:2E:92:6A"
}
