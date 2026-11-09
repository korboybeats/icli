//
//  FLEXSwiftMetadataInspector.swift
//  Reflex
//
//  FlexUltra's crash-averse Swift metadata bridge.
//

import Foundation

/// A deliberately narrow Objective-C bridge for reading stable Swift class
/// metadata without constructing SwiftMirror/FLEXSwiftMirror or reflecting a
/// live object value.
///
/// This surface intentionally does not:
/// - resolve mangled field types,
/// - read or write field values,
/// - enumerate protocol conformances,
/// - construct Mirror/FLEXMirror.
///
/// Those operations have exercised crash-prone Echo/Swift runtime paths on
/// installed devices. Field names and offsets come directly from the class
/// descriptor and initialized metadata field-offset vector.
@objc(FLEXSwiftMetadataInspector)
public final class SwiftMetadataInspector: NSObject {
    @objc(inspectClass:limit:)
    public class func inspectClass(_ cls: AnyClass, limit: Int) -> NSDictionary {
        let className = NSStringFromClass(cls)
        let boundedLimit = max(1, min(limit, 500))

        guard let metadata = reflectClass(cls) else {
            return [
                "class_name": className,
                "is_swift_class": false,
                "metadata_available": false,
                "reflectable": false,
                "fields": [],
                "field_count": 0,
                "truncated": false,
                "mode": "metadata_only",
            ]
        }

        // Echo's ClassMetadata can wrap Objective-C-compatible classes too.
        // Never touch a Swift context descriptor until the metadata itself says
        // this is a Swift class.
        guard metadata.isSwiftClass else {
            return [
                "class_name": className,
                "is_swift_class": false,
                "metadata_available": true,
                "reflectable": false,
                "fields": [],
                "field_count": 0,
                "truncated": false,
                "mode": "metadata_only",
            ]
        }

        guard let descriptor = metadata.descriptor else {
            return [
                "class_name": className,
                "is_swift_class": true,
                "metadata_available": true,
                "reflectable": false,
                "fields": [],
                "field_count": 0,
                "truncated": false,
                "mode": "metadata_only",
            ]
        }

        let reflectable = descriptor.isReflectable
        let records = reflectable ? descriptor.fields.records : []
        let offsets = reflectable ? metadata.fieldOffsets : []
        let count = min(records.count, boundedLimit)
        var fields: [[String: Any]] = []
        fields.reserveCapacity(count)

        for index in 0..<count {
            let record = records[index]
            var field: [String: Any] = [
                "name": record.name,
                "declaring_class": className,
                "has_mangled_type_name": record.hasMangledTypeName,
            ]
            if index < offsets.count {
                field["offset"] = offsets[index]
            }
            fields.append(field)
        }

        return [
            "class_name": className,
            "is_swift_class": true,
            "metadata_available": true,
            "reflectable": reflectable,
            "fields": fields,
            "field_count": records.count,
            "truncated": records.count > count,
            "instance_size": metadata.instanceSize,
            "instance_alignment_mask": metadata.instanceAlignmentMask,
            "uses_swift_ref_counting": metadata.flags.usesSwiftRefCounting,
            "is_actor": metadata.isActor,
            "is_default_actor": metadata.isDefaultActor,
            "mode": "metadata_only",
        ]
    }
}
