# MapleTagReader

Read-only Objective-C++ bridge for [sbooth/CXXTagLib 2.3.2](https://github.com/sbooth/CXXTagLib/tree/2.3.2), built from source by SwiftPM. The dependency uses the Mozilla Public License 1.1; its notice is bundled as `Maple/Resources/TagLib-License.txt`. Original TagLib source remains available at the pinned revision in `Package.resolved`.

Swift receives only a Foundation dictionary. Standard properties and embedded pictures use TagLib's unified property APIs. ID3 SYLT uses TagLib's parsed frame API and is rendered as raw LRC; MPEG-frame timestamps are converted using the decoded MPEG properties. No media or tags are changed. C++ exceptions return an empty result so native AVFoundation metadata remains available for playable formats TagLib does not support.
