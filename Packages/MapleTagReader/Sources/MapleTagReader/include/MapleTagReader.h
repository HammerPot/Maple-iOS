#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Read-only, source-built TagLib boundary. No C++ types cross into Swift.
@interface MapleTagReader : NSObject
+ (NSDictionary<NSString *, id> *)metadataAtURL:(NSURL *)url;
@end
NS_ASSUME_NONNULL_END
