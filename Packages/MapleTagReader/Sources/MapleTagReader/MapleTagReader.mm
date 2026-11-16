#import "MapleTagReader.h"
#include <taglib/fileref.h>
#include <taglib/tfile.h>
#include <taglib/tpropertymap.h>
#include <taglib/tvariant.h>
#include <taglib/mpegfile.h>
#include <taglib/mpegproperties.h>
#include <taglib/id3v2tag.h>
#include <taglib/synchronizedlyricsframe.h>
#include <cstdio>
#include <set>
#include <string>

// Resource budget. A file in the user's Files folder is untrusted input: these limits keep a
// hostile or merely enormous tag from exhausting memory or storage during import. A file that
// exceeds them is still imported (AVFoundation plays it); its oversized parts are just ignored.
namespace {
constexpr unsigned long kMaxID3TagBytes = 64UL * 1024 * 1024;   // ID3v2 tag at the start of a file
constexpr size_t kMaxPictureBytes = 20UL * 1024 * 1024;          // one embedded picture
constexpr size_t kMaxPictureBytesTotal = 40UL * 1024 * 1024;     // all APIC frames of an MP3
constexpr unsigned kMaxPictures = 16;                            // pictures examined per file
constexpr unsigned kMaxProperties = 2048;                        // property entries examined
constexpr unsigned kMaxFieldCharacters = 4096;                   // title, artist, album, ...
constexpr unsigned kMaxLyricsCharacters = 256 * 1024;            // lyrics, plain or synchronised
constexpr unsigned kMaxSyncedLines = 20000;                      // SYLT lines

NSString *text(const TagLib::String &value, unsigned maximum = kMaxFieldCharacters) {
    const TagLib::String bounded = value.size() > maximum ? value.substr(0, maximum) : value;
    const auto utf8 = bounded.to8Bit(true);
    return [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding] ?: @"";
}

bool isLyricsKey(const std::string &key) {
    return key == "LYRICS" || key == "UNSYNCEDLYRICS" || key == "USLT" || key.rfind("LYRICS:", 0) == 0;
}

// Only the properties the library uses are copied out of TagLib's (unbounded) property map.
bool isWantedKey(const std::string &key) {
    static const std::set<std::string> wanted = {"TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "DATE", "GENRE",
                                                  "TRACKNUMBER", "DISCNUMBER", "COMPILATION"};
    return wanted.count(key) > 0 || isLyricsKey(key);
}

// Size of an ID3v2 tag at the very start of the file (header included), or 0 when there is none.
// Checked before TagLib reads the tag, because TagLib loads the whole tag into memory.
unsigned long leadingID3TagSize(const char *path) {
    FILE *file = fopen(path, "rb");
    if(!file) return 0;
    unsigned char header[10] = {0};
    const size_t count = fread(header, 1, sizeof header, file);
    fclose(file);
    if(count != sizeof header || header[0] != 'I' || header[1] != 'D' || header[2] != '3') return 0;
    return 10UL + ((header[6] & 0x7fUL) << 21 | (header[7] & 0x7fUL) << 14 | (header[8] & 0x7fUL) << 7 | (header[9] & 0x7fUL));
}

// True when the APIC frames of an MP3 are within budget; avoids copying oversized pictures.
bool picturesWithinBudget(TagLib::ID3v2::Tag *tag) {
    size_t total = 0;
    unsigned count = 0;
    for(auto *frame : tag->frameList("APIC")) {
        if(++count > kMaxPictures) return false;
        total += frame->size();
        if(total > kMaxPictureBytesTotal) return false;
    }
    return true;
}
}

@implementation MapleTagReader
+ (NSDictionary<NSString *, id> *)metadataAtURL:(NSURL *)url {
    @autoreleasepool {
        try {
            if(leadingID3TagSize(url.fileSystemRepresentation) > kMaxID3TagBytes) return @{};
            TagLib::FileRef ref(url.fileSystemRepresentation, true, TagLib::AudioProperties::Average);
            if(ref.isNull() || !ref.file() || !ref.file()->isValid()) return @{};
            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(ref.file());
            const auto properties = ref.file()->properties();
            unsigned examined = 0;
            for(auto it = properties.begin(); it != properties.end() && examined < kMaxProperties; ++it, ++examined) {
                if(it->second.isEmpty()) continue;
                const std::string key = it->first.to8Bit(true);
                if(!isWantedKey(key)) continue;
                result[text(it->first, 128)] = text(it->second.front(), isLyricsKey(key) ? kMaxLyricsCharacters : kMaxFieldCharacters);
            }
            // Unified TagLib complex properties cover MP3 APIC, MP4 covr, FLAC pictures,
            // and ID3-tagged AIFF/WAV without inspecting any container bytes ourselves. For MP3 the
            // frame sizes are checked first so oversized pictures are never copied; other formats
            // are bounded after the fact (the parser has already read them).
            bool readPictures = true;
            if(mpeg) if(auto *tag = mpeg->ID3v2Tag(false)) readPictures = picturesWithinBudget(tag);
            if(readPictures) {
                unsigned inspected = 0;
                for(const auto &picture : ref.file()->complexProperties("PICTURE")) {
                    if(++inspected > kMaxPictures) break;
                    auto found = picture.find("data");
                    if(found == picture.end()) continue;
                    const auto bytes = found->second.toByteVector();
                    if(bytes.isEmpty() || bytes.size() > kMaxPictureBytes) continue;
                    result[@"artwork"] = [NSData dataWithBytes:bytes.data() length:bytes.size()];
                    break;
                }
            }
            // Preserve SYLT as timestamped raw LRC for the player/lyrics layer.
            // Prefer synchronized text when a file includes both USLT and SYLT.
            if(mpeg) {
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
                        unsigned lines = 0;
                        for(const auto &line : lyrics->synchedText()) {
                            if(++lines > kMaxSyncedLines || lrc.length > kMaxLyricsCharacters) break;
                            const auto ms = (unsigned long long)(line.time * millisecondsPerUnit);
                            [lrc appendFormat:@"[%02llu:%02llu.%03llu]%@\n", ms / 60000, (ms / 1000) % 60, ms % 1000, text(line.text, kMaxFieldCharacters)];
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
