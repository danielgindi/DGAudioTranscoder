//
//  DGAudioTranscoder.m
//  DGAudioTranscoder
//
//  Created by Daniel Cohen Gindi on 12/17/14.
//  Copyright (c) 2013 danielgindi@gmail.com. All rights reserved.
//
//  Usage of this library is allowed only when attributed to the author in the licenses section of your application.
//
//  https://github.com/danielgindi/DGAudioTranscoder
//
//  The MIT License (MIT)
//
//  Copyright (c) 2014 Daniel Cohen Gindi (danielgindi@gmail.com)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

#import "DGAudioTranscoder.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CFNetwork/CFNetwork.h>

#define DEFAULT_PACKET_BUFFER_SIZE 2048
#define OS_STATUS_DONE 'done'

@interface DGAudioTranscoder ()
{
    UInt32 _httpStatusCode;
    SInt64 _streamPosition;
    SInt64 _streamLength;
    
    BOOL _isLocalFile;
    
    NSURL *_url, *_transcodeToUrl;
    NSDictionary *_httpHeaders;
    AudioFileTypeID audioFileTypeHint;
    NSDictionary *_requestHeaders;
    
    DGAudioTranscoderStatus _status;
    
    CFReadStreamRef _stream;
    CFStreamError _lastStreamErrorCode;
    NSError *_lastStreamError;
    
    NSRunLoop *_cfEventsRunLoop;
    
    UInt8 *_readBuffer;
    UInt32 _readBufferSize;
    
    AudioFileStreamID _audioFileStream;
    BOOL _parseAudioHeader;
    UInt64 _audioDataOffset;
    UInt64 _audioDataByteCount;
    UInt32 _packetBufferSize;
    
    AudioStreamBasicDescription _sourceAsbd;
    AudioStreamBasicDescription _destinationAsbd;
    AudioStreamBasicDescription _canonicalAsbd;
    
    AudioConverterRef _decodeConverterRef, _encodeConverterRef;
    
    AudioFileID _destinationAudioFileId;
    UInt32 _destinationFilePacketPosition;
    
    UInt32 _decodeBufferSize;
    UInt8 *_decodeBuffer;
    UInt32 _decodePacketsPerBuffer;
    UInt32 _decodePacketSize;
    
    UInt32 _encodeBufferSize;
    UInt8 *_encodeBuffer;
    UInt32 _encodePacketsPerBuffer;
    UInt32 _encodePacketSize;
    
    AudioStreamPacketDescription *_encodePacketDescriptions;
}

@end

@implementation DGAudioTranscoder

static void ReadStreamCallbackProc(CFReadStreamRef _stream, CFStreamEventType eventType, void *inClientInfo)
{
    DGAudioTranscoder *transcoder = (__bridge DGAudioTranscoder *)inClientInfo;
    
    switch (eventType)
    {
        case kCFStreamEventErrorOccurred:
            [transcoder cfErrorOccurred];
            break;
        case kCFStreamEventEndEncountered:
            [transcoder cfEof];
            break;
        case kCFStreamEventHasBytesAvailable:
            [transcoder cfHasBytesAvailable];
            break;
        default:
            break;
    }
}

typedef struct
{
    BOOL done;
    UInt32 numberOfPackets;
    AudioBuffer audioBuffer;
    AudioStreamPacketDescription *packetDescriptions;
}
AudioConvertInfo;

static OSStatus AudioConverterCallback(AudioConverterRef inAudioConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription, void *inUserData)
{
    AudioConvertInfo* convertInfo = (AudioConvertInfo*)inUserData;
    
    if (convertInfo->done)
    {
        ioNumberDataPackets = 0;
        
        return OS_STATUS_DONE;
    }
    
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0] = convertInfo->audioBuffer;
    
    if (outDataPacketDescription)
    {
        *outDataPacketDescription = convertInfo->packetDescriptions;
    }
    
    *ioNumberDataPackets = convertInfo->numberOfPackets;
    convertInfo->done = YES;

    return 0;
}

static void AudioFileStreamPropertyListenerProc(void* clientData, AudioFileStreamID audioFileStream, AudioFileStreamPropertyID	propertyId, UInt32* flags)
{
    DGAudioTranscoder *transcoder = (__bridge DGAudioTranscoder*)clientData;
    
    [transcoder handlePropertyChangeForFileStream:audioFileStream fileStreamPropertyID:propertyId ioFlags:flags];
}

static void AudioFileStreamPacketsProc(void* clientData, UInt32 numberOfBytes, UInt32 numberOfPackets, const void* inputData, AudioStreamPacketDescription* packetDescriptions)
{
    DGAudioTranscoder *transcoder = (__bridge DGAudioTranscoder*)clientData;
    
    [transcoder handleAudioPackets:inputData numberOfBytes:numberOfBytes numberOfPackets:numberOfPackets packetDescriptions:packetDescriptions];
}

#pragma mark - Lifecycle

- (id)initWithURL:(NSURL *)url transcodingToUrl:(NSURL *)transcodeToUrl
{
    return [self initWithURL:url httpRequestHeaders:nil transcodingToUrl:transcodeToUrl];
}

- (id)initWithURL:(NSURL *)url httpRequestHeaders:(NSDictionary *)httpRequestHeaders  transcodingToUrl:(NSURL *)transcodeToUrl
{
    self = [super init];
    if (self)
    {
        _status = DGAudioTranscoderIdle;
        
        _streamPosition = 0;
        _streamLength = -1;
        
        _outputAudioFormat = kAudioFormatMPEG4AAC;
        _outputAudioFormatFlags = kMPEG4Object_AAC_LC;
        _outputAudioFileType = kAudioFileCAFType;
        
        _readBufferSize = 1024 * 64;
        
        _url = url;
        _transcodeToUrl = transcodeToUrl;
        _requestHeaders = httpRequestHeaders;
        
        audioFileTypeHint = [DGAudioTranscoder audioFileTypeHintFromFileExtension:_url.pathExtension];
        
#if __IPHONE_OS_VERSION_MIN_REQUIRED < 80000
        const int bytesPerSample = sizeof(AudioSampleType);
#else
        const int bytesPerSample = sizeof(SInt16);
#endif
        
        _canonicalAsbd = (AudioStreamBasicDescription)
        {
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            .mFramesPerPacket = 1,
            .mChannelsPerFrame = 2,
            .mBytesPerFrame = bytesPerSample * 2 /*channelsPerFrame*/,
            .mBitsPerChannel = 8 * bytesPerSample,
            .mBytesPerPacket = (bytesPerSample * 2)
        };
    }
    return self;
}

- (void)destroyAudioConverters
{
    if (_decodeConverterRef)
    {
        AudioConverterDispose(_decodeConverterRef);
        _decodeConverterRef = nil;
    }
    
    if (_encodeConverterRef)
    {
        AudioConverterDispose(_encodeConverterRef);
        _encodeConverterRef = nil;
    }
}

- (void)closeTranscodeAudioFile
{
    if (_destinationAudioFileId)
    {
        AudioFileClose(_destinationAudioFileId);
        _destinationAudioFileId = NULL;
    }
    
    [self destroyAudioConverters];
    
    if (_decodeBuffer)
    {
        free(_decodeBuffer);
        _decodeBuffer = NULL;
    }
    
    if (_encodeBuffer)
    {
        free(_encodeBuffer);
        _encodeBuffer = NULL;
    }
    
    if (_encodePacketDescriptions)
    {
        free(_encodePacketDescriptions);
        _encodePacketDescriptions = NULL;
    }
    
    _destinationFilePacketPosition = 0;
    
    if (self.isFailed)
    {
        [[NSFileManager defaultManager] removeItemAtURL:_transcodeToUrl error:nil];
    }
}

- (void)dealloc
{
    [self _cancel];
    
    if (_readBuffer)
    {
        free(_readBuffer);
    }
}

- (void)_cancel
{
    [self closeStream];
    [self closeTranscodeAudioFile];
}

- (void)failureOccurred
{
    _status = DGAudioTranscoderFailed;
    
    [self _cancel];
    
    BOOL dispatchMessages = _failedBlock || [self.delegate respondsToSelector:@selector(audioTranscoderFailed:)];
    
    if (dispatchMessages)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if ([self.delegate respondsToSelector:@selector(audioTranscoderFailed:)])
            {
                [self.delegate audioTranscoderFailed:self];
            }
            
            if (_failedBlock)
            {
                _failedBlock(self);
            }
            
        });
    }
}

#pragma mark - Public methods

- (void)start
{
    [self cancel];
    
    _streamPosition = 0LL;
    [self open];
}

- (void)cancel
{
    [self _cancel];
    _status = DGAudioTranscoderIdle;
}

#pragma mark - Helpers

+ (AudioFileTypeID)audioFileTypeHintFromFileExtension:(NSString *)fileExtension
{
    static dispatch_once_t onceToken;
    static NSDictionary *fileTypesByFileExtensions = nil;
    
    if (!fileTypesByFileExtensions)
    {
        dispatch_once(&onceToken, ^{
            fileTypesByFileExtensions =
            @{
              @"mp3": @(kAudioFileMP3Type),
              @"wav": @(kAudioFileWAVEType),
              @"aifc": @(kAudioFileAIFCType),
              @"aiff": @(kAudioFileAIFFType),
              @"m4a": @(kAudioFileM4AType),
              @"mp4": @(kAudioFileMPEG4Type),
              @"caf": @(kAudioFileCAFType),
              @"aac": @(kAudioFileAAC_ADTSType),
              @"ac3": @(kAudioFileAC3Type),
              @"3gp": @(kAudioFile3GPType)
              };
        });
    }
    
    NSNumber *number = [fileTypesByFileExtensions objectForKey:fileExtension];
    
    if (!number)
    {
        return 0;
    }
    
    return (AudioFileTypeID)number.intValue;
}

+ (AudioFileTypeID)audioFileTypeHintFromMimeType:(NSString *)mimeType
{
    static dispatch_once_t onceToken;
    static NSDictionary *fileTypesByMimeType = nil;
    
    if (!fileTypesByMimeType)
    {
        dispatch_once(&onceToken, ^{
            fileTypesByMimeType =
            @{
              @"audio/mp3": @(kAudioFileMP3Type),
              @"audio/mpg": @(kAudioFileMP3Type),
              @"audio/mpeg": @(kAudioFileMP3Type),
              @"audio/wav": @(kAudioFileWAVEType),
              @"audio/x-wav": @(kAudioFileWAVEType),
              @"audio/vnd.wav": @(kAudioFileWAVEType),
              @"audio/aifc": @(kAudioFileAIFCType),
              @"audio/aiff": @(kAudioFileAIFFType),
              @"audio/x-m4a": @(kAudioFileM4AType),
              @"audio/x-mp4": @(kAudioFileMPEG4Type),
              @"audio/aacp": @(kAudioFileAAC_ADTSType),
              @"audio/m4a": @(kAudioFileM4AType),
              @"audio/mp4": @(kAudioFileMPEG4Type),
              @"video/mp4": @(kAudioFileMPEG4Type),
              @"audio/caf": @(kAudioFileCAFType),
              @"audio/x-caf": @(kAudioFileCAFType),
              @"audio/aac": @(kAudioFileAAC_ADTSType),
              @"audio/aacp": @(kAudioFileAAC_ADTSType),
              @"audio/ac3": @(kAudioFileAC3Type),
              @"audio/3gp": @(kAudioFile3GPType),
              @"video/3gp": @(kAudioFile3GPType),
              @"audio/3gpp": @(kAudioFile3GPType),
              @"video/3gpp": @(kAudioFile3GPType),
              @"audio/3gp2": @(kAudioFile3GP2Type),
              @"video/3gp2": @(kAudioFile3GP2Type)
              };
        });
    }
    
    NSNumber *number = [fileTypesByMimeType objectForKey:mimeType];
    
    if (!number)
    {
        return 0;
    }
    
    return (AudioFileTypeID)number.intValue;
}

static BOOL GetHardwareCodecClassDesc(UInt32 formatId, AudioClassDescription* classDesc)
{
#if TARGET_OS_IPHONE
    UInt32 size;
    
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, sizeof(formatId), &formatId, &size) != 0)
    {
        return NO;
    }
    
    UInt32 decoderCount = size / sizeof(AudioClassDescription);
    AudioClassDescription encoderDescriptions[decoderCount];
    
    if (AudioFormatGetProperty(kAudioFormatProperty_Decoders, sizeof(formatId), &formatId, &size, encoderDescriptions) != 0)
    {
        return NO;
    }
    
    for (UInt32 i = 0; i < decoderCount; ++i)
    {
        if (encoderDescriptions[i].mManufacturer == kAppleHardwareAudioCodecManufacturer)
        {
            *classDesc = encoderDescriptions[i];
            
            return YES;
        }
    }
#endif
    
    return NO;
}

#pragma mark - Property accessors

- (NSURL *)url
{
    return _url;
}

- (BOOL)isIdle
{
    return _status == DGAudioTranscoderIdle;
}

- (BOOL)isInProgress
{
    return _status == DGAudioTranscoderInProgress;
}

- (BOOL)isDone
{
    return _status == DGAudioTranscoderDone;
}

- (BOOL)isStreamError
{
    return _status == DGAudioTranscoderStreamError;
}

- (BOOL)isFailed
{
    return _status == DGAudioTranscoderFailed;
}

- (BOOL)hasBytesAvailable
{
    if (!_stream)
    {
        return NO;
    }
    
    return CFReadStreamHasBytesAvailable(_stream);
}

- (UInt32)httpStatusCode
{
    return _httpStatusCode;
}

- (CFStreamStatus)streamStatus
{
    if (_stream)
    {
        return CFReadStreamGetStatus(_stream);
    }
    
    return 0;
}

- (CFStreamError)streamErrorCode
{
    return _lastStreamErrorCode;
}

- (NSError *)streamError
{
    return _lastStreamError;
}

- (SInt64)streamLength
{
    return _streamLength;
}

- (SInt64)streamPosition
{
    return _streamPosition;
}

- (float)progress
{
    return _streamLength < 0 ? 0.f : (_streamPosition / (float)_streamLength);
}

- (DGAudioTranscoderStatus)status
{
    return _status;
}

#pragma mark - CF Stream events

- (void)unregisterForEvents
{
    if (_stream)
    {
        CFReadStreamSetClient(_stream, kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(_stream, [_cfEventsRunLoop getCFRunLoop], kCFRunLoopCommonModes);
    }
}

- (void)registerForEvents:(NSRunLoop *)runLoop
{
    _cfEventsRunLoop = runLoop;
    
    if (!_stream) return;
    
    CFStreamClientContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    
    CFReadStreamSetClient(_stream, kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, ReadStreamCallbackProc, &context);
    
    CFReadStreamScheduleWithRunLoop(_stream, [_cfEventsRunLoop getCFRunLoop], kCFRunLoopCommonModes);
}

- (void)cfErrorOccurred
{
    _lastStreamErrorCode = CFReadStreamGetError(_stream);
    _lastStreamError = CFBridgingRelease(CFReadStreamCopyError(_stream));
    
    [self closeStream];
    
    _status = DGAudioTranscoderStreamError;
    
    BOOL dispatchMessages = _streamErrorBlock || [self.delegate respondsToSelector:@selector(audioTranscoder:streamError:code:)];
    
    if (dispatchMessages)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if ([self.delegate respondsToSelector:@selector(audioTranscoder:streamError:code:)])
            {
                [self.delegate audioTranscoder:self streamError:_lastStreamError code:_lastStreamErrorCode];
            
            }
            
            if (_streamErrorBlock)
            {
                _streamErrorBlock(self, _lastStreamError, _lastStreamErrorCode);
            }
            
        });
    }
}

- (void)cfHasBytesAvailable
{
    if (_stream == NULL) return;
    
    if (!_isLocalFile && _httpStatusCode == 0)
    {
        CFTypeRef response = CFReadStreamCopyProperty(_stream, kCFStreamPropertyHTTPResponseHeader);
        
        if (response)
        {
            _httpHeaders = (__bridge_transfer NSDictionary *)CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef)response);
            
            _httpStatusCode = (UInt32)CFHTTPMessageGetResponseStatusCode((CFHTTPMessageRef)response);
            
            CFRelease(response);
        }
        
        if (_httpStatusCode == 200)
        {
            _streamPosition = 0;
            
            if (_httpHeaders[@"Content-Length"])
            {
                _streamLength = (SInt64)[_httpHeaders[@"Content-Length"] longLongValue];
            }
            else
            {
                _streamLength = -1LL;
            }
            
            NSString *contentType = [_httpHeaders objectForKey:@"Content-Type"];
            AudioFileTypeID typeIdFromMimeType = [DGAudioTranscoder audioFileTypeHintFromMimeType:contentType];
            
            if (typeIdFromMimeType != 0)
            {
                audioFileTypeHint = typeIdFromMimeType;
            }
        }
        else if (_httpStatusCode == 206)
        {
            NSString *contentRange = [_httpHeaders objectForKey:@"Content-Range"];
            NSArray *components = [contentRange componentsSeparatedByString:@"/"];
            
            if (components.count == 2)
            {
                _streamLength = [components[1] integerValue];
            }
        }
        else if (_httpStatusCode == 416)
        {
            if (_streamLength >= 0)
            {
                _streamPosition = _streamLength;
            }
            
            [self cfEof];
            
            return;
        }
        else if (_httpStatusCode >= 300)
        {
            [self cfErrorOccurred];
            
            return;
        }
    }
    
    SInt32 read = [self read:_readBufferSize bytesIntoBuffer:_readBuffer];
    if (read > 0)
    {
        if (!_audioFileStream)
        {
            OSStatus error = AudioFileStreamOpen((__bridge void *)self, AudioFileStreamPropertyListenerProc, AudioFileStreamPacketsProc, audioFileTypeHint, &_audioFileStream);
            
            if (error)
            {
                [self failureOccurred];
                return;
            }
        }
        
        if (_audioFileStream)
        {
            OSStatus error = AudioFileStreamParseBytes(_audioFileStream, read, _readBuffer, 0);
            
            if (error)
            {
                [self failureOccurred];
                return;
            }
        }
    }
}

- (void)cfEof
{
    [self closeTranscodeAudioFile];
    
    _status = DGAudioTranscoderDone;
    
    BOOL dispatchMessages = _doneBlock || [self.delegate respondsToSelector:@selector(audioTranscoderDone:)];
    
    if (dispatchMessages)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if ([self.delegate respondsToSelector:@selector(audioTranscoderDone:)])
            {
                [self.delegate audioTranscoderDone:self];
            }
            
            if (_doneBlock)
            {
                _doneBlock(self);
            }
            
        });
    }
}

#pragma mark - Manage CF stream

- (void)open
{
    if (!_url) return;
    
    if ([_url.scheme caseInsensitiveCompare:@"file"] == NSOrderedSame)
    {
        _isLocalFile = YES;
        
        _stream = CFReadStreamCreateWithFile(NULL, (__bridge CFURLRef)_url);
        if (!_stream)
        {
            [self cfErrorOccurred];
            return;
        }
        
        NSError *fileError;
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_url.path error:&fileError];
        
        if (fileError)
        {
            CFReadStreamClose(_stream);
            CFRelease(_stream);
            _stream = NULL;
            
            _lastStreamError = fileError;
            
            [self cfErrorOccurred];
            
            return;
        }
        
        NSNumber *fileSize = attributes[NSFileSize];
        if (attributes)
        {
            _streamLength = fileSize.longLongValue;
        }
    }
    else
    {
        _isLocalFile = NO;
        
        CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)@"GET", (__bridge CFURLRef)_url, kCFHTTPVersion1_1);
        
        if (_streamPosition > 0)
        {
            CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Range"), (__bridge CFStringRef)[NSString stringWithFormat:@"bytes=%lld-", _streamPosition]);
        }
        
        for (NSString *key in _requestHeaders)
        {
            CFHTTPMessageSetHeaderFieldValue(message, (__bridge CFStringRef)key, (__bridge CFStringRef)(NSString *)_requestHeaders[key]);
        }
        
        _stream = CFReadStreamCreateForHTTPRequest(NULL, message);
        
        if (!_stream)
        {
            CFRelease(message);
            
            [self cfErrorOccurred];
            
            return;
        }
        
        if (!CFReadStreamSetProperty(_stream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue))
        {
            CFRelease(message);
            
            [self cfErrorOccurred];
            
            return;
        }
        
        // Proxy support
        
        CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
        CFReadStreamSetProperty(_stream, kCFStreamPropertyHTTPProxy, proxySettings);
        CFRelease(proxySettings);
        
        // SSL support
        
        if ([_url.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame)
        {
            NSDictionary *sslSettings = @{
                                          (NSString *)kCFStreamSSLLevel: (NSString *)kCFStreamSocketSecurityLevelNegotiatedSSL,
                                          (NSString *)kCFStreamSSLValidatesCertificateChain: @(NO),
                                          (NSString *)kCFStreamSSLPeerName: NSNull.null
                                          };
            
            CFReadStreamSetProperty(_stream, kCFStreamPropertySSLSettings, (__bridge CFTypeRef)sslSettings);
        }
        
        CFRelease(message);
        
        _httpStatusCode = 0;
    }
    
    if (!_readBuffer)
    {
        if (_readBufferSize <= 1024)
        {
            _readBufferSize = 1024 * 64;
        }
        _readBuffer = malloc(sizeof(UInt8) * _readBufferSize);
    }
    
    _parseAudioHeader = NO;
    
    [self registerForEvents:[NSRunLoop currentRunLoop]];
    
    if (!CFReadStreamOpen(_stream))
    {
        CFRelease(_stream);
        
        _stream = NULL;
        
        [self cfErrorOccurred];
        
        return;
    }
    
    _status = DGAudioTranscoderInProgress;
}

- (void)closeStream
{
    [self unregisterForEvents];
    if (_stream)
    {
        CFReadStreamClose(_stream);
        CFRelease(_stream);
        
        _stream = NULL;
    }
}

- (void)reconnect
{
    [self closeStream];
    
    _stream = 0;
    _streamPosition = 0;
    
    [self open];
}

- (SInt32)read:(UInt32)size bytesIntoBuffer:(UInt8 *)buffer
{
    if (size == 0) return 0;
    
    CFIndex readSize = (CFIndex)size;
    SInt32 read = (SInt32)CFReadStreamRead(_stream, buffer, readSize);
    
    if (read < 0)
    {
        return read;
    }
    
    _streamPosition += read;
    
    return read;
}

#pragma mark - Audio Stream Events

- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID ioFlags:(UInt32*)ioFlags
{
    OSStatus error;
    
    switch (inPropertyID)
    {
        case kAudioFileStreamProperty_DataOffset:
        {
            SInt64 offset;
            UInt32 offsetSize = sizeof(offset);
            
            AudioFileStreamGetProperty(_audioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
            
            _parseAudioHeader = YES;
            _audioDataOffset = offset;
            
            break;
        }
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
            UInt64 audioDataByteCount;
            UInt32 byteCountSize = sizeof(audioDataByteCount);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &audioDataByteCount);
            
            _audioDataByteCount = audioDataByteCount;
            
            break;
        }
        /*case kAudioFileStreamProperty_FileFormat:
        {
            char fileFormat[4];
            UInt32 fileFormatSize = sizeof(fileFormat);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FileFormat, &fileFormatSize, &fileFormat);
            
            break;
        }*/
        case kAudioFileStreamProperty_DataFormat:
        {
            AudioStreamBasicDescription asbd;
            
            if (!_parseAudioHeader)
            {
                UInt32 size = sizeof(asbd);
                
                AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &size, &asbd);
                
                UInt32 packetBufferSize = 0;
                UInt32 sizeOfPacketBufferSize = sizeof(packetBufferSize);
                
                error = AudioFileStreamGetProperty(_audioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfPacketBufferSize, &packetBufferSize);
                
                if (error || packetBufferSize == 0)
                {
                    error = AudioFileStreamGetProperty(_audioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfPacketBufferSize, &packetBufferSize);
                    
                    if (error || packetBufferSize == 0)
                    {
                        packetBufferSize = DEFAULT_PACKET_BUFFER_SIZE;
                    }
                }
                
                _packetBufferSize = packetBufferSize;
                
                [self createAudioConverter:&asbd];
            }
            
            break;
        }
        case kAudioFileStreamProperty_FormatList:
        {
            Boolean outWriteable;
            UInt32 formatListSize;
            OSStatus err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
            
            if (err)
            {
                break;
            }
            
            AudioFormatListItem *formatList = malloc(formatListSize);
            
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
            
            if (err)
            {
                free(formatList);
                break;
            }
            
            for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
            {
                AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                
                if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
                {
                    _sourceAsbd = pasbd;
                    
                    break;
                }
            }
            
            free(formatList);
            
            break;
        }
            
    }
}

- (void)createAudioConverter:(AudioStreamBasicDescription *)asbd
{
    OSStatus status;
    Boolean writable;
    UInt32 cookieSize;
    
    if (memcmp(asbd, &_sourceAsbd, sizeof(AudioStreamBasicDescription)) == 0)
    {
        AudioConverterReset(_decodeConverterRef);
        
        if (_encodeConverterRef)
        {
            AudioConverterReset(_encodeConverterRef);
        }
        
        return;
    }
    
    [self destroyAudioConverters];
    
    _sourceAsbd = *asbd;
    
    _canonicalAsbd.mSampleRate = _sourceAsbd.mSampleRate;
    _canonicalAsbd.mChannelsPerFrame = _sourceAsbd.mChannelsPerFrame;
    
    _destinationAsbd = (AudioStreamBasicDescription)
    {
        .mFormatID = _outputAudioFormat,
        .mFormatFlags = _outputAudioFormatFlags,
        .mChannelsPerFrame = _canonicalAsbd.mChannelsPerFrame,
        .mSampleRate = _canonicalAsbd.mSampleRate,
    };
    
    UInt32 dataSize = sizeof(_destinationAsbd);
    AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                           0,
                           NULL,
                           &dataSize,
                           &_destinationAsbd);
    
    AudioClassDescription classDesc;
    if (GetHardwareCodecClassDesc(_sourceAsbd.mFormatID, &classDesc))
    {
        AudioConverterNewSpecific(&_sourceAsbd, &_canonicalAsbd, 1, &classDesc, &_decodeConverterRef);
    }
    
    if (!_decodeConverterRef)
    {
        status = AudioConverterNew(&_sourceAsbd, &_canonicalAsbd, &_decodeConverterRef);
        
        if (status)
        {
            [self failureOccurred];
            return;
        }
    }
    
    if (!_encodeConverterRef)
    {
        status = AudioConverterNew(&_canonicalAsbd, &_destinationAsbd, &_encodeConverterRef);
        
        if (status)
        {
            [self failureOccurred];
            return;
        }
    }
    
    status = AudioFileStreamGetPropertyInfo(_audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable);
    
    if (!status)
    {
        void *cookieData = alloca(cookieSize);
        
        status = AudioFileStreamGetProperty(_audioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
        
        if (status)
        {
            return;
        }
        
        status = AudioConverterSetProperty(_decodeConverterRef, kAudioConverterDecompressionMagicCookie, cookieSize, &cookieData);
        
        if (status)
        {
            return;
        }
    }
    
    if (_decodeConverterRef)
    {
        if (_decodeBuffer)
        {
            free(_decodeBuffer);
            _decodeBuffer = NULL;
        }
        
        _decodeBufferSize = 32 * 1024;
        _decodePacketSize = _canonicalAsbd.mBytesPerPacket;
        _decodePacketsPerBuffer = _decodeBufferSize / _decodePacketSize;
        _decodeBuffer = (UInt8 *)malloc(sizeof(UInt8) * _decodeBufferSize);
    }
    
    if (_encodeConverterRef)
    {
        if (_destinationAudioFileId)
        {
            AudioFileClose(_destinationAudioFileId);
            _destinationAudioFileId = NULL;
        }
        
        if (_encodeBuffer)
        {
            free(_encodeBuffer);
            _encodeBuffer = NULL;
        }
        
        if (_encodePacketDescriptions)
        {
            free(_encodePacketDescriptions);
            _encodePacketDescriptions = NULL;
        }
        
        _encodeBufferSize = 32 * 1024;
        _encodePacketSize = _canonicalAsbd.mBytesPerPacket;
        
        if (_encodePacketSize == 0)
        {
            UInt32 size = sizeof(_encodePacketSize);
            if (0 == AudioConverterGetProperty(_encodeConverterRef, kAudioConverterPropertyMaximumOutputPacketSize, &size, &_encodePacketSize))
            {
                if (_encodePacketSize > _encodeBufferSize)
                {
                    _encodeBufferSize = _encodePacketSize;
                }
                
                _encodePacketsPerBuffer = _encodeBufferSize / _encodePacketSize;
            }
            else
            {
                AudioConverterDispose(_encodeConverterRef);
                _encodeConverterRef = NULL;
                
                [self failureOccurred];
                return;
            }
        }
        else
        {
            _encodePacketsPerBuffer = _encodeBufferSize / _encodePacketSize;
        }
        
        UInt32 propertySize = sizeof(UInt32);
        UInt32 externallyFramed = 0;
        OSStatus error = AudioFormatGetProperty(kAudioFormatProperty_FormatIsExternallyFramed, sizeof(_destinationAsbd), &_destinationAsbd, &propertySize, &externallyFramed);
        
        if (externallyFramed)
        {
            _encodePacketDescriptions = (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * _encodePacketsPerBuffer);
        }
        
        _encodeBuffer = (UInt8 *)malloc(sizeof(UInt8) * _encodeBufferSize);
        
        error = AudioFileCreateWithURL(
                                       (__bridge CFURLRef)(_transcodeToUrl),
                                       _outputAudioFileType,
                                       &_destinationAsbd,
                                       kAudioFileFlags_EraseFile,
                                       &_destinationAudioFileId);
        
        _destinationFilePacketPosition = 0;
        
        if (error)
        {
            [self closeTranscodeAudioFile];
        }
    }
}

- (void)handleAudioPackets:(const void *)inputData
             numberOfBytes:(UInt32)numberOfBytes
           numberOfPackets:(UInt32)numberOfPackets
        packetDescriptions:(AudioStreamPacketDescription *)packetDescriptions
{
    if (!_audioFileStream || !_parseAudioHeader || !_decodeConverterRef) return;
    
    AudioConvertInfo convertInfo = (AudioConvertInfo){
        .done = NO,
        .numberOfPackets = numberOfPackets,
        .packetDescriptions = packetDescriptions,
        .audioBuffer = (AudioBuffer){
            .mData = (void *)inputData,
            .mDataByteSize = numberOfBytes,
            .mNumberChannels = _sourceAsbd.mChannelsPerFrame
        }
    };
    
    AudioBufferList decodedData;
    decodedData.mNumberBuffers = 1;
    decodedData.mBuffers[0].mNumberChannels = _canonicalAsbd.mChannelsPerFrame;
    decodedData.mBuffers[0].mDataByteSize = _decodeBufferSize;
    decodedData.mBuffers[0].mData = _decodeBuffer;
    
    UInt32 ioOutputDataPackets1, ioOutputDataPackets2;
    OSStatus decodingStatus, encodingStatus;
    
    while (1)
    {
        ioOutputDataPackets1 = numberOfPackets;
        
        decodingStatus = AudioConverterFillComplexBuffer(_decodeConverterRef, AudioConverterCallback, (void*)&convertInfo, &ioOutputDataPackets1, &decodedData, NULL);
        
        if (decodingStatus == OS_STATUS_DONE || decodingStatus == 0)
        {
            if (ioOutputDataPackets1 > 0)
            {
                // Start encoding
                
                AudioConvertInfo encodeConvertInfo = (AudioConvertInfo){
                    .done = NO,
                    .numberOfPackets = ioOutputDataPackets1,
                    .packetDescriptions = NULL,
                    .audioBuffer = (AudioBuffer){
                        .mData = decodedData.mBuffers[0].mData,
                        .mDataByteSize = decodedData.mBuffers[0].mDataByteSize,
                        .mNumberChannels = _canonicalAsbd.mChannelsPerFrame
                    }
                };
                
                AudioBufferList encodedData;
                encodedData.mNumberBuffers = 1;
                encodedData.mBuffers[0].mNumberChannels = _destinationAsbd.mChannelsPerFrame;
                encodedData.mBuffers[0].mDataByteSize = _encodeBufferSize;
                encodedData.mBuffers[0].mData = _encodeBuffer;
                
                while (1)
                {
                    ioOutputDataPackets2 = _encodePacketsPerBuffer;
                    
                    encodingStatus = AudioConverterFillComplexBuffer(_encodeConverterRef, AudioConverterCallback, (void*)&encodeConvertInfo, &ioOutputDataPackets2, &encodedData, _encodePacketDescriptions);
                    
                    if (encodingStatus == OS_STATUS_DONE || encodingStatus == 0)
                    {
                        if (ioOutputDataPackets2 > 0)
                        {
                            OSStatus writeError = AudioFileWritePackets(_destinationAudioFileId, NO, encodedData.mBuffers[0].mDataByteSize, _encodePacketDescriptions, _destinationFilePacketPosition, &ioOutputDataPackets2, encodedData.mBuffers[0].mData);
                            
                            if (writeError)
                            {
                                [self failureOccurred];
                                return;
                            }
                            else
                            {
                                _destinationFilePacketPosition += ioOutputDataPackets2;
                            }
                        }
                    }
                    else
                    {
                        [self failureOccurred];
                        return;
                    }
                    
                    if (encodingStatus == OS_STATUS_DONE)
                    {
                        break;
                    }
                }
                
                // End encoding
            }
        }
        else
        {
            [self failureOccurred];
            return;
        }
        
        if (decodingStatus == OS_STATUS_DONE)
        {
            break;
        }
    }
}

@end
