#import "MapleTagReader.h"
#include <taglib/fileref.h>
#include <taglib/tfile.h>
#include <taglib/tpropertymap.h>
#include <taglib/tvariant.h>
#include <taglib/mpegfile.h>
#include <taglib/mpegproperties.h>
#include <taglib/id3v2tag.h>
#include <taglib/synchronizedlyricsframe.h>

static NSString *text(const TagLib::String &value) {
    const auto utf8 = value.to8Bit(true);
    return [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding] ?: @"";
}

@implementation MapleTagReader
+ (NSDictionary<NSString *, id> *)metadataAtURL:(NSURL *)url {
    @autoreleasepool {
        try {
            TagLib::FileRef ref(url.fileSystemRepresentation, true, TagLib::AudioProperties::Accurate);
            if(ref.isNull() || !ref.file() || !ref.file()->isValid()) return @{};
            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            const auto properties = ref.file()->properties();
            for(auto it = properties.begin(); it != properties.end(); ++it) {
                if(!it->second.isEmpty()) result[text(it->first)] = text(it->second.front());
            }
            // Unified TagLib complex properties cover MP3 APIC, MP4 covr, FLAC pictures,
            // and ID3-tagged AIFF/WAV without inspecting any container bytes ourselves.
            for(const auto &picture : ref.file()->complexProperties("PICTURE")) {
                auto found = picture.find("data");
                if(found == picture.end()) continue;
                const auto bytes = found->second.toByteVector();
                if(!bytes.isEmpty()) {
                    result[@"artwork"] = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                    break;
                }
            }
            // Preserve SYLT as timestamped raw LRC for the player/lyrics layer.
            // Prefer synchronized text when a file includes both USLT and SYLT.
            if(auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(ref.file())) {
                if(auto *tag = mpeg->ID3v2Tag(false)) {
                    for(auto *frame : tag->frameList("SYLT")) {
                        auto *lyrics = dynamic_cast<TagLib::ID3v2::SynchronizedLyricsFrame *>(frame);
                        if(!lyrics) continue;
                        double millisecondsPerUnit = 1;
                        if(lyrics->timestampFormat() == TagLib::ID3v2::SynchronizedLyricsFrame::AbsoluteMpegFrames) {
                            auto *audio = mpeg->audioProperties();
                            if(!audio || audio->sampleRate() <= 0) continue;
                            const int samples = audio->layer() == 1 ? 384 : (audio->layer() == 3 && audio->version() != TagLib::MPEG::Header::Version1 ? 576 : 1152);
                            millisecondsPerUnit = 1000.0 * samples / audio->sampleRate();
                        }
                        NSMutableString *lrc = [NSMutableString string];
                        for(const auto &line : lyrics->synchedText()) {
                            const auto ms = (unsigned long long)(line.time * millisecondsPerUnit);
                            [lrc appendFormat:@"[%02llu:%02llu.%03llu]%@\n", ms / 60000, (ms / 1000) % 60, ms % 1000, text(line.text)];
                        }
                        if(lrc.length) { result[@"LYRICS"] = lrc; break; }
                    }
                }
            }
            return result;
        } catch(...) {
            // A broken tag must not prevent importing otherwise playable audio.
            return @{};
        }
    }
}
@end
