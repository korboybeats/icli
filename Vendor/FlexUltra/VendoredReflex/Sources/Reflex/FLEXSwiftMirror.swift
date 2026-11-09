//
//  FLEXSwiftMirror.swift
//  Reflex
//
//  Created by Tanner Bennett on 4/12/21.
//  Copyright © 2021 Tanner Bennett. All rights reserved.
//

import Foundation
import FLEX

@objc(FLEXSwiftMirror)
public class SwiftMirror: NSObject, FLEXMirrorProtocol {
    
    /// Never a metaclass
    private let `class`: AnyClass
    private let metadata: ClassMetadata?
    private var flexMirror: FLEXMirror {
        .init(reflecting: self.value)
    }
    
    /// Really it's AnyObject
    public let value: Any
    public let isClass: Bool
    public let className: String

    @objc public var swiftMetadataAvailable: Bool {
        self.metadata != nil
    }

    /// Echo's protocol-conformance decoder predates the Swift runtime shipped
    /// with iOS 26 and can trap while resolving a conformance descriptor's
    /// relative protocol pointer. Keep Swift field inspection available while
    /// conservatively disabling only that unsafe metadata surface.
    @objc public var swiftProtocolsAvailable: Bool {
        guard self.metadata != nil else { return false }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
    }
    
    private(set) public var properties: [FLEXProperty] = []
    @objc public private(set) var classProperties: [FLEXProperty] = []
    private(set) public var ivars: [FLEXIvar] = []
    private(set) public var methods: [FLEXMethod] = []
    @objc public private(set) var classMethods: [FLEXMethod] = []
    private(set) public var protocols: [FLEXProtocol] = []
    
    public var superMirror: FLEXMirrorProtocol? {
        guard let supercls = class_getSuperclass(self.class) else {
            return nil
        }

        // SwiftMirror is only safe for the Swift class it was created for.
        // Feeding Objective-C superclasses back through Echo makes
        // ContextualNominalType.shallowFields interpret Objective-C class
        // metadata as a Swift nominal type and can trap on newer runtimes.
        // Continue the superclass chain with FLEX's Objective-C mirror; the
        // agent guards the terminal superclass before asking FLEX to advance.
        return FLEXMirror(reflecting: supercls)
    }
    
    required public init(reflecting objectOrClass: Any) {
        let cls: AnyClass = object_getClass(objectOrClass)!
        
        self.value = objectOrClass
        self.isClass = class_isMetaClass(cls)
        self.className = NSStringFromClass(cls)
        
        self.class = self.isClass ? objectOrClass as! AnyClass : cls
        self.metadata = reflectClass(self.class)
        
        super.init()
        self.examine()
    }
    
    private func examine() {
        let swiftIvars: [SwiftIvar]
        let swiftProtos: [SwiftProtocol]
        if let metadata = self.metadata {
            swiftIvars = metadata.shallowFields.compactMap {
                .init(field: $0, class: metadata)
            }
            if self.swiftProtocolsAvailable {
                swiftProtos = metadata.conformances
                    .map(\.protocol)
                    .map { .init(protocol: $0) }
            } else {
                swiftProtos = []
            }
        } else {
            swiftIvars = []
            swiftProtos = []
        }
        
        let fm = self.flexMirror
        let ivarNames = Set(swiftIvars.map(\.name))
        self.ivars = swiftIvars + fm.ivars.filter { !ivarNames.contains($0.name) }
        self.protocols = swiftProtos + fm.protocols
        
        self.properties = fm.properties
        self.methods = fm.methods

        // FLEX 4.7 does not expose classProperties/classMethods on FLEXMirror.
        // In that release, reflecting a Class object makes properties/methods
        // represent the class members instead. Newer FLEX exposes both sets at
        // once. Use Objective-C dispatch for the newer selectors so this dylib
        // remains loadable against the 4.7 ABI used by some target devices.
        if fm.responds(to: NSSelectorFromString("classProperties")),
           let properties = fm.value(forKey: "classProperties") as? [FLEXProperty] {
            self.classProperties = properties
        } else {
            self.classProperties = FLEXMirror(reflecting: self.class).properties
        }

        if fm.responds(to: NSSelectorFromString("classMethods")),
           let methods = fm.value(forKey: "classMethods") as? [FLEXMethod] {
            self.classMethods = methods
        } else {
            self.classMethods = FLEXMirror(reflecting: self.class).methods
        }
    }
}
