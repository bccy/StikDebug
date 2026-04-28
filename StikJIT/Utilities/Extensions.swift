//
//  Extensions.swift
//  StikDebug
//
//  Created by s s on 2025/7/9.
//
import Foundation
import UniformTypeIdentifiers
import UIKit

enum PairingFileStore {
    static let fileName = "rp_pairing_file.plist"
    private static let legacyFileName = "pairingFile.plist"
    static let supportedContentTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!,
        .propertyList
    ]

    static var url: URL {
        URL.documentsDirectory.appendingPathComponent(fileName)
    }

    private static var legacyURL: URL {
        URL.documentsDirectory.appendingPathComponent(legacyFileName)
    }

    @discardableResult
    static func prepareURL(fileManager: FileManager = .default) -> URL {
        let destination = url
        guard !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: legacyURL.path) else {
            return destination
        }

        do {
            try fileManager.moveItem(at: legacyURL, to: destination)
        } catch {
            if let data = try? Data(contentsOf: legacyURL) {
                try? data.write(to: destination, options: .atomic)
                try? fileManager.removeItem(at: legacyURL)
            }
        }

        return destination
    }

    static func replace(with sourceURL: URL, fileManager: FileManager = .default) throws {
        let destination = prepareURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.removeItem(at: legacyURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func importFromPicker(_ sourceURL: URL, fileManager: FileManager = .default) throws {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        try replace(with: sourceURL, fileManager: fileManager)
    }

    static func remove(fileManager: FileManager = .default) throws {
        let destination = prepareURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if fileManager.fileExists(atPath: legacyURL.path) {
            try? fileManager.removeItem(at: legacyURL)
        }
    }
}

extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

extension Notification.Name {
    static let pairingFileImported = Notification.Name("PairingFileImported")
}
