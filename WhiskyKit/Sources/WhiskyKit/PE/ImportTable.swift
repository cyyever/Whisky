//
//  PortableExecutable+ImportTable.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

extension PEFile {
    /// Size of an `IMAGE_IMPORT_DESCRIPTOR` entry in bytes.
    private static let importDescriptorSize: UInt64 = 20
    /// Defensive cap on the number of import descriptors walked.
    private static let maxImportDescriptors = 4096
    /// Defensive cap on an imported DLL name length in bytes.
    private static let maxDLLNameLength = 256

    /// The DLL names in the image's import directory table, lowercased.
    ///
    /// Walks `DataDirectory[1]` (the regular import table only; delay-load
    /// imports are not considered). Returns `[]` for images without imports or
    /// with a malformed import directory.
    ///
    /// https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#the-idata-section
    public var importedDLLs: [String] {
        var result: [String] = []
        enumerateImportedDLLs { name in
            result.append(name)
            return true
        }
        return result
    }

    /// Whether the image imports the given DLL (case-insensitive). Stops at the
    /// first match rather than materialising the whole import list.
    public func importsDLL(_ name: String) -> Bool {
        let target = name.lowercased()
        var found = false
        enumerateImportedDLLs { dll in
            if dll == target {
                found = true
                return false
            }
            return true
        }
        return found
    }

    /// Call `body` with each imported DLL name (lowercased), stopping early when
    /// `body` returns `false`.
    private func enumerateImportedDLLs(_ body: (String) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer {
            try? handle.close()
        }
        parseImportedDLLs(handle: handle, body)
    }

    private func parseImportedDLLs(handle: FileHandle, _ body: (String) -> Bool) {
        guard let magic = optionalHeader?.magic, magic != .unknown else { return }

        // Re-derive the optional header's file offset (PE offset + signature +
        // COFF header, as in PEFile.init).
        guard let peOffset = handle.extract(UInt32.self, offset: 0x3C) else { return }
        let optionalHeaderOffset = UInt64(peOffset) + 24

        // The data directories follow the fixed optional-header fields, whose
        // size depends on the magic; NumberOfRvaAndSizes is the 4 bytes before.
        let dataDirectoryOffset = optionalHeaderOffset + (magic == .pe32Plus ? 112 : 96)
        guard let directoryCount = handle.extract(UInt32.self, offset: dataDirectoryOffset - 4),
              directoryCount >= 2 else { return }

        // DataDirectory[1] is the import directory table.
        guard let importTableRVA = handle.extract(UInt32.self, offset: dataDirectoryOffset + 8),
              importTableRVA != 0,
              var descriptorOffset = fileOffset(forRVA: importTableRVA) else { return }

        // IMAGE_IMPORT_DESCRIPTORs, terminated by an all-zero entry.
        for _ in 0..<Self.maxImportDescriptors {
            guard let originalFirstThunk = handle.extract(UInt32.self, offset: descriptorOffset),
                  let nameRVA = handle.extract(UInt32.self, offset: descriptorOffset + 12),
                  let firstThunk = handle.extract(UInt32.self, offset: descriptorOffset + 16) else { return }
            if originalFirstThunk == 0 && nameRVA == 0 && firstThunk == 0 { break }

            if nameRVA != 0,
               let nameOffset = fileOffset(forRVA: nameRVA),
               let name = readCString(handle: handle, offset: nameOffset) {
                if !body(name.lowercased()) { return }
            }
            descriptorOffset += Self.importDescriptorSize
        }
    }

    /// Resolve an RVA to a file offset via the section table.
    private func fileOffset(forRVA rva: UInt32) -> UInt64? {
        for section in sections {
            let size = max(section.virtualSize, section.sizeOfRawData)
            if section.virtualAddress <= rva, rva - section.virtualAddress < size {
                return UInt64(section.pointerToRawData) + UInt64(rva - section.virtualAddress)
            }
        }
        return nil
    }

    /// Read a NUL-terminated ASCII string of at most `maxDLLNameLength` bytes.
    private func readCString(handle: FileHandle, offset: UInt64) -> String? {
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: Self.maxDLLNameLength) else { return nil }
            let bytes = data.prefix(while: { $0 != 0 })
            guard !bytes.isEmpty else { return nil }
            return String(bytes: bytes, encoding: .ascii)
        } catch {
            return nil
        }
    }
}
