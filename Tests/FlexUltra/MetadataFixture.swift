import Foundation

/// Loaded only into the disposable acceptance app; never packaged with icli.
@objc(ICLIFlexMetadataFixture)
final class MetadataFixture: NSObject {
    @objc var count: Int = 42
    var title: String = "fixture"
}
