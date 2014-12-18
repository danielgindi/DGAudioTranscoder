//
//  DGAudioTranscoder.h
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

#import <AudioToolbox/AudioToolbox.h>

@class DGAudioTranscoder;

typedef void (^ DGAudioTranscoderStreamErrorBlock)(DGAudioTranscoder *transcoder, NSError *error, CFStreamError code);
typedef void (^ DGAudioTranscoderFailedBlock)(DGAudioTranscoder *transcoder);
typedef void (^ DGAudioTranscoderDoneBlock)(DGAudioTranscoder *transcoder);

typedef NS_ENUM(NSInteger, DGAudioTranscoderStatus)
{
    DGAudioTranscoderIdle,
    DGAudioTranscoderInProgress,
    DGAudioTranscoderDone,
    DGAudioTranscoderStreamError,
    DGAudioTranscoderFailed
};

@protocol DGAudioTranscoderDelegate;

@interface DGAudioTranscoder : NSObject

- (id)initWithURL:(NSURL *)url httpRequestHeaders:(NSDictionary *)httpRequestHeaders  transcodingToUrl:(NSURL *)transcodeToUrl;
- (id)initWithURL:(NSURL *)url transcodingToUrl:(NSURL *)transcodeToUrl;

@property (nonatomic, weak) id<DGAudioTranscoderDelegate> delegate;
@property (nonatomic, strong, readonly) NSURL *url;
@property (nonatomic, strong, readonly) NSURL *transcodeToUrl;
@property (nonatomic, assign, readonly) UInt32 httpStatusCode;
@property (nonatomic, assign, readonly) CFStreamStatus streamStatus;
@property (nonatomic, assign, readonly) CFStreamError streamErrorCode;
@property (nonatomic, assign, readonly) NSError *streamError;
@property (nonatomic, assign, readonly) SInt64 streamLength;
@property (nonatomic, assign, readonly) SInt64 streamPosition;
@property (nonatomic, assign, readonly) float progress;
@property (nonatomic, assign, readonly) DGAudioTranscoderStatus status;
@property (nonatomic, assign) UInt32 readBufferSize;

@property (nonatomic, strong) DGAudioTranscoderStreamErrorBlock streamErrorBlock;
@property (nonatomic, strong) DGAudioTranscoderFailedBlock failedBlock;
@property (nonatomic, strong) DGAudioTranscoderDoneBlock doneBlock;

@property (nonatomic, assign, readonly) BOOL isIdle;
@property (nonatomic, assign, readonly) BOOL isInProgress;
@property (nonatomic, assign, readonly) BOOL isDone;
@property (nonatomic, assign, readonly) BOOL isStreamError;
@property (nonatomic, assign, readonly) BOOL isFailed;

/**
 @property outputAudioFileType
 @brief the output file type
 Default value is kAudioFileCAFType
 */
@property (nonatomic, assign) AudioFileTypeID outputAudioFileType;

/**
 @property outputAudioFormat
 @brief the output file format
 Default value is kAudioFormatMPEG4AAC
 */
@property (nonatomic, assign) AudioFormatID outputAudioFormat;

/**
 @property outputAudioFormatFlags
 @brief the output file format flags
 Default value is kMPEG4Object_AAC_LC (lossless AAC codec)
 */
@property (nonatomic, assign) AudioFormatFlags outputAudioFormatFlags;

- (void)start;
- (void)cancel;
- (void)reconnect;

@end

@protocol DGAudioTranscoderDelegate <NSObject>
@optional

/** 
 @function audioTranscoder:streamError:code:
 @brief Indicates a stream failure. If this is over HTTP, you may try to call [reconnect] and continue from where you left off */
- (void)audioTranscoder:(DGAudioTranscoder *)transcoder streamError:(NSError *)error code:(CFStreamError)errorCode;

/**
 @function audioTranscoderFailed:
 @brief Indicates a catastrophic failure, which could be bad data, format not supported etc. You can't recover from this one, and the output file will be deleted */
- (void)audioTranscoderFailed:(DGAudioTranscoder *)DGAudioTranscoder;

/**
 @function audioTranscoderDone:
 @brief Indicates we're done, and the output file is ready */
- (void)audioTranscoderDone:(DGAudioTranscoder *)DGAudioTranscoder;

@end