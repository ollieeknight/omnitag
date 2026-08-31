import AVFoundation

let writer = try! AVAssetWriter(url: URL(fileURLWithPath: "/tmp/test.m4a"), fileType: .m4a)
let dummyItem = AVMutableMetadataItem()
dummyItem.identifier = .quickTimeUserDataChapter
dummyItem.dataType = kCMMetadataBaseDataType_UTF8 as String
dummyItem.value = "" as NSString
let dummyGroup = AVTimedMetadataGroup(items: [dummyItem], timeRange: CMTimeRange(start: .zero, end: .invalid))
let chapterInput = AVAssetWriterInput(
    mediaType: .text, 
    outputSettings: nil, 
    sourceFormatHint: dummyGroup.copyFormatDescription()
)
print("text m4a:", writer.canAdd(chapterInput))

let writer2 = try! AVAssetWriter(url: URL(fileURLWithPath: "/tmp/test2.m4a"), fileType: .m4a)
let chapterInput2 = AVAssetWriterInput(
    mediaType: .metadata, 
    outputSettings: nil, 
    sourceFormatHint: dummyGroup.copyFormatDescription()
)
print("metadata m4a:", writer2.canAdd(chapterInput2))

let writer3 = try! AVAssetWriter(url: URL(fileURLWithPath: "/tmp/test3.mp4"), fileType: .mp4)
let chapterInput3 = AVAssetWriterInput(
    mediaType: .metadata, 
    outputSettings: nil, 
    sourceFormatHint: dummyGroup.copyFormatDescription()
)
print("metadata mp4:", writer3.canAdd(chapterInput3))
