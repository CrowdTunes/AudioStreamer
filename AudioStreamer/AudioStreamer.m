//
//  AudioStreamer.m
//  StreamingAudioPlayer
//
//  Created by Matt Gallagher on 27/09/08.
//  Copyright 2008 Matt Gallagher. All rights reserved.
//
//  This software is provided 'as-is', without any express or implied
//  warranty. In no event will the authors be held liable for any damages
//  arising from the use of this software. Permission is granted to anyone to
//  use this software for any purpose, including commercial applications, and to
//  alter it and redistribute it freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//  3. This notice may not be removed or altered from any source
//     distribution.
//

/* This file has been heavily modified since its original distribution by
   Alex Crichton for the Hermes project */

#import "AudioStreamer.h"

#define BitRateEstimationMinPackets 50

#define PROXY_SYSTEM 0
#define PROXY_SOCKS  1
#define PROXY_HTTP   2

/* Default number and size of audio queue buffers */
#define kDefaultNumAQBufs 256
#define kDefaultAQDefaultBufSize 4096
#define kDefaultNumAQBufsToStart 32

#define CHECK_ERR_NORET(err, code, reasonStr) {                                 \
    if (err) { [self failWithErrorCode:code reason:reasonStr]; return; }        \
}
#define CHECK_ERR_RET(err, code, reasonStr, retVal) {                           \
    if (err) { [self failWithErrorCode:code reason:reasonStr]; return retVal; } \
}
#define CHECK_ERR_X(x, err, code, reasonStr, retVal, FUNC, ...) FUNC
#define CHECK_ERR(...) CHECK_ERR_X(,##__VA_ARGS__, CHECK_ERR_RET(__VA_ARGS__), CHECK_ERR_NORET(__VA_ARGS__))

#if defined(DEBUG) && 0
#define LOG(fmt, args...) NSLog(@"%s " fmt, __PRETTY_FUNCTION__, ##args)
#else
#define LOG(...)
#endif

typedef struct queued_packet {
  AudioStreamPacketDescription desc;
  struct queued_packet *next;
  size_t offset;
  UInt32 byteSize;
  char data[];
} queued_packet_t;

/* Errors, not an 'extern' */
NSString * const ASErrorDomain = @"com.alexcrichton.audiostreamer";

/* Notifcations */
NSString * const ASStatusChangedNotification = @"ASStatusChangedNotification";
NSString * const ASBitrateReadyNotification = @"ASBitrateReadyNotification";

/* Woohoo, actual implementation now! */
@implementation AudioStreamer

/* AudioFileStream callback when properties are available */
static void ASPropertyListenerProc(void *inClientData,
                            AudioFileStreamID inAudioFileStream,
                            AudioFileStreamPropertyID inPropertyID,
                            UInt32 *ioFlags) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inClientData;
  [streamer handlePropertyChangeForFileStream:inAudioFileStream
                         fileStreamPropertyID:inPropertyID
                                      ioFlags:ioFlags];
}

/* AudioFileStream callback when packets are available */
static void ASPacketsProc(void *inClientData, UInt32 inNumberBytes, UInt32
                   inNumberPackets, const void *inInputData,
                   AudioStreamPacketDescription  *inPacketDescriptions) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inClientData;
  [streamer handleAudioPackets:inInputData
                   numberBytes:inNumberBytes
                 numberPackets:inNumberPackets
            packetDescriptions:inPacketDescriptions];
}

/* AudioQueue callback notifying that a buffer is done, invoked on AudioQueue's
 * own personal threads, not the main thread */
static void ASAudioQueueOutputCallback(void *inClientData, AudioQueueRef inAQ,
                                AudioQueueBufferRef inBuffer) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inClientData;
  [streamer handleBufferCompleteForQueue:inAQ buffer:inBuffer];
}

/* AudioQueue callback that a property has changed, invoked on AudioQueue's own
 * personal threads like above */
static void ASAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ,
                                   AudioQueuePropertyID inID) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inUserData;
  [streamer handlePropertyChangeForQueue:inAQ propertyID:inID];
}

/* CFReadStream callback when an event has occurred */
static void ASReadStreamCallBack(CFReadStreamRef aStream, CFStreamEventType eventType,
                          void* inClientInfo) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inClientInfo;
  [streamer handleReadFromStream:aStream eventType:eventType];
}

/* Private method. Developers should call +[AudioStreamer streamWithURL:] */
- (instancetype)initWithURL:(NSURL*)url {
  if ((self = [super init])) {
    _url = url;
    _bufferCount  = kDefaultNumAQBufs;
    _bufferSize = kDefaultAQDefaultBufSize;
    _bufferFillCountToStart = kDefaultNumAQBufsToStart;
    _timeoutInterval = 10;
    _playbackRate = 1.0f;
  }
  return self;
}

+ (instancetype)streamWithURL:(NSURL*)url{
  assert(url != nil);
  return [[self alloc] initWithURL:url];
}

- (void)dealloc {
  [self stop];
  assert(queued_head == NULL);
  assert(queued_tail == NULL);
  assert(timeout == nil);
  assert(buffers == NULL);
  assert(inuse == NULL);
}

- (void)setHTTPProxy:(NSString*)host port:(int)port {
  proxyHost = host;
  proxyPort = port;
  proxyType = PROXY_HTTP;
}

- (void)setSOCKSProxy:(NSString*)host port:(int)port {
  proxyHost = host;
  proxyPort = port;
  proxyType = PROXY_SOCKS;
}

- (BOOL)setVolume:(float)volume {
  if (audioQueue != NULL) {
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, volume);
    return YES;
  }
  return NO;
}

/* Deprecated. */
+ (NSString *)stringForErrorCode:(AudioStreamerErrorCode)anErrorCode {
  return [[self class] descriptionForErrorCode:anErrorCode]; // Internal method.
}

- (BOOL)isPlaying {
  return state_ == AS_PLAYING;
}

- (BOOL)isPaused {
  return state_ == AS_PAUSED;
}

- (BOOL)isWaiting {
  return state_ == AS_WAITING_FOR_DATA ||
         state_ == AS_WAITING_FOR_QUEUE_TO_START;
}

- (BOOL)isDone {
  return state_ == AS_DONE || state_ == AS_STOPPED;
}

- (AudioStreamerDoneReason)doneReason {
  switch (state_) {
    case AS_STOPPED:
      return AS_DONE_STOPPED;
    case AS_DONE:
      if (_error) {
        return AS_DONE_ERROR;
      } else {
        return AS_DONE_EOF;
      }
    default:
      break;
  }
  return AS_NOT_DONE;
}

- (BOOL)start {
  if (stream != NULL) return NO;
  assert(audioQueue == NULL);
  assert(state_ == AS_INITIALIZED);
  [self openReadStream];
  if (![self isDone]) {
    timeout = [NSTimer scheduledTimerWithTimeInterval:_timeoutInterval
                                               target:self
                                             selector:@selector(checkTimeout)
                                             userInfo:nil
                                              repeats:YES];
  }
  return YES;
}

- (BOOL)pause {
  if (state_ != AS_PLAYING) return NO;
  assert(audioQueue != NULL);
  OSStatus osErr = AudioQueuePause(audioQueue);
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_PAUSE_FAILED, @"", NO);
  queuePaused = true;
  [self setState:AS_PAUSED];
  return YES;
}

- (BOOL)play {
  if (state_ != AS_PAUSED) return NO;
  assert(audioQueue != NULL);
  [self startAudioQueue];
  return YES;
}

- (void)stop {
  if (state_ == AS_STOPPED) return; // Already stopped.

  AudioStreamerState prevState = state_;
  if (state_ != AS_DONE) {
    // Delay notification to the end to avoid race conditions
    state_ = AS_STOPPED;
  }

  [timeout invalidate];
  timeout = nil;

  /* Clean up our streams */
  [self closeReadStream];
  if (audioFileStream && !isParsing) {
    [self closeFileStream];
  }
  if (audioQueue) {
    AudioQueueStop(audioQueue, true);
    OSStatus osErr = AudioQueueDispose(audioQueue, true);
    assert(!osErr);
    audioQueue = nil;
  }
  if (buffers != NULL) {
    free(buffers);
    buffers = NULL;
  }
  if (inuse != NULL) {
    free(inuse);
    inuse = NULL;
  }

  _httpHeaders     = nil;
  bytesFilled      = 0;
  packetsFilled    = 0;
  seekByteOffset   = 0;
  packetBufferSize = 0;

  if (prevState != state_) {
    [[NSNotificationCenter defaultCenter]
          postNotificationName:ASStatusChangedNotification
                        object:self];
  }
}

- (BOOL)seekToTime:(double)newSeekTime {
  double bitrate;
  double duration;
  if (![self calculatedBitRate:&bitrate]) return NO;
  if (![self duration:&duration]) return NO;
  if (bitrate == 0.0 || fileLength <= 0) {
    return NO;
  }
  assert(!seeking);
  seeking = true;

  //
  // Calculate the byte offset for seeking
  //
  seekByteOffset = dataOffset +
    (UInt64)(newSeekTime / duration) * (fileLength - dataOffset);

  //
  // Attempt to leave 1 useful packet at the end of the file (although in
  // reality, this may still seek too far if the file has a long trailer).
  //
  if (seekByteOffset > fileLength - 2 * packetBufferSize) {
    seekByteOffset = fileLength - 2 * packetBufferSize;
  }

  //
  // Store the old time from the audio queue and the time that we're seeking
  // to so that we'll know the correct time progress after seeking.
  //
  seekTime = newSeekTime;

  //
  // For later
  //
  OSStatus osErr;

  //
  // Attempt to align the seek with a packet boundary
  //
  double packetDuration = _streamDescription.mFramesPerPacket / _streamDescription.mSampleRate;
  if (packetDuration > 0 && bitrate > 0) {
    UInt32 ioFlags = 0;
    SInt64 packetAlignedByteOffset;
    SInt64 seekPacket = (SInt64)floor(newSeekTime / packetDuration);
    osErr = AudioFileStreamSeek(audioFileStream, seekPacket,
                                &packetAlignedByteOffset, &ioFlags);
    if (!osErr) {
      seekByteOffset = (UInt64)packetAlignedByteOffset + dataOffset;
      seekTime -= ((seekByteOffset - dataOffset) - (UInt64)packetAlignedByteOffset) * 8.0 / bitrate;
    }
  }

  [self closeReadStream];

  /* Stop audio for now */
  osErr = AudioQueueStop(audioQueue, true);
  if (osErr) {
    seeking = false;
    [self failWithErrorCode:AS_AUDIO_QUEUE_STOP_FAILED reason:@""];
    return NO;
  }

  /* Open a new stream with a new offset */
  BOOL ret = [self openReadStream];
  seeking = false;
  return ret;
}

- (BOOL)seekByDelta:(double)seekTimeDelta {
  double p = 0;
  if ([self progress:&p]) {
    return [self seekToTime:p + seekTimeDelta];
  }
  return NO;
}

- (BOOL)progress:(double*)ret {
  double sampleRate = _streamDescription.mSampleRate;
  if (state_ == AS_STOPPED) {
    *ret = lastProgress;
    return YES;
  }
  if (sampleRate <= 0 || (state_ != AS_PLAYING && state_ != AS_PAUSED))
    return NO;

  AudioTimeStamp queueTime;
  Boolean discontinuity;
  OSStatus osErr = AudioQueueGetCurrentTime(audioQueue, NULL, &queueTime, &discontinuity);
  if (osErr) {
    return NO;
  }

  double progress = seekTime + queueTime.mSampleTime / sampleRate;
  if (progress < 0.0) {
    progress = 0.0;
  }

  lastProgress = progress;
  *ret = progress;
  return YES;
}

- (BOOL)calculatedBitRate:(double*)rate {
  if (vbr)
  {
    double sampleRate     = _streamDescription.mSampleRate;
    double packetDuration = _streamDescription.mFramesPerPacket / sampleRate;

    if (packetDuration && processedPacketsCount > BitRateEstimationMinPackets) {
      double averagePacketByteSize = processedPacketsSizeTotal /
                                      processedPacketsCount;
      /* bits/byte x bytes/packet x packets/sec = bits/sec */
      *rate = averagePacketByteSize;
      return YES;
    }
    return NO;
  }
  else
  {
    *rate = 8.0 * _streamDescription.mSampleRate * _streamDescription.mBytesPerPacket * _streamDescription.mFramesPerPacket;
    return YES;
  }
}

- (BOOL)duration:(double*)ret {
  if (fileLength == 0) return NO;

  double packetDuration = _streamDescription.mFramesPerPacket / _streamDescription.mSampleRate;
  if (!packetDuration) return NO;

  // Method one
  UInt64 packetCount;
  UInt32 packetCountSize = sizeof(packetCount);
  OSStatus status = AudioFileStreamGetProperty(audioFileStream,
                                               kAudioFileStreamProperty_AudioDataPacketCount,
                                               &packetCountSize, &packetCount);
  if (status != 0) {
    // Method two
    packetCount = totalAudioPackets;
  }

  if (packetCount == 1000000)
  {
    // Method three
    double calcBitrate;
    if (![self calculatedBitRate:&calcBitrate]) return NO;
    if (calcBitrate == 0) return NO;
    *ret = (fileLength - dataOffset) / (calcBitrate * 0.125);
  }
  else
  {
    *ret = packetCount * _streamDescription.mFramesPerPacket / _streamDescription.mSampleRate;
  }

  return YES;
}

- (BOOL)fadeTo:(float)volume duration:(float)duration {
  if (audioQueue != NULL) {
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_VolumeRampTime, duration);
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, volume);
    return YES;
  }
  return NO;
}

- (void)fadeInDuration:(float)duration {
  //-- set the gain to 0.0, so we can call this method just after creating the streamer
  [self setVolume:0.0];
  [self fadeTo:1.0 duration:duration];
}

- (void)fadeOutDuration:(float)duration {
  [self fadeTo:0.0 duration:duration];
}

#pragma mark - Internal functions

+ (NSString *)descriptionForErrorCode:(AudioStreamerErrorCode)anErrorCode {
  switch (anErrorCode) {
    case 0: /* Deprecated */
      return @"No error";
    case AS_NETWORK_CONNECTION_FAILED:
      return @"Network connection failure";
    case AS_FILE_STREAM_GET_PROPERTY_FAILED:
      return @"File stream get property failed";
    case AS_FILE_STREAM_SET_PROPERTY_FAILED:
      return @"File stream set property failed";
    case 1003: /* AS_FILE_STREAM_SEEK_FAILED - Deprecated */
      return @"File stream seek failed";
    case AS_FILE_STREAM_PARSE_BYTES_FAILED:
      return @"Parse bytes failed";
    case AS_FILE_STREAM_OPEN_FAILED:
      return @"Failed to open file stream";
    case 1006: /* AS_FILE_STREAM_CLOSE_FAILED - Deprecated */
      return @"Failed to close the file stream";
    case AS_AUDIO_DATA_NOT_FOUND:
      return @"No audio data found";
    case AS_AUDIO_QUEUE_CREATION_FAILED:
      return @"Audio queue creation failed";
    case AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED:
      return @"Audio queue buffer allocation failed";
    case AS_AUDIO_QUEUE_ENQUEUE_FAILED:
      return @"Queueing of audio buffer failed";
    case AS_AUDIO_QUEUE_ADD_LISTENER_FAILED:
      return @"Failed to add listener to audio queue";
    case 1012: /* AS_AUDIO_QUEUE_REMOVE_LISTENER_FAILED - Deprecated */
      return @"Failed to remove listener from audio queue";
    case AS_AUDIO_QUEUE_START_FAILED:
      return @"Failed to start the audio queue";
    case AS_AUDIO_QUEUE_PAUSE_FAILED:
      return @"Failed to pause the audio queue";
    case AS_AUDIO_QUEUE_BUFFER_MISMATCH:
      return @"Audio queue buffer mismatch";
    case 1016: /* AS_AUDIO_QUEUE_DISPOSE_FAILED - Deprecated */
      return @"Couldn't dispose of audio queue";
    case AS_AUDIO_QUEUE_STOP_FAILED:
      return @"Audio queue stop failed";
    case AS_AUDIO_QUEUE_FLUSH_FAILED:
      return @"Failed to flush the audio queue";
    case 1019: /* AS_AUDIO_STREAMER_FAILED - Deprecated */
      return @"Audio streamer failed";
    case 1020: /* AS_GET_AUDIO_TIME_FAILED - Deprecated */
      return @"Couldn't get audio time";
    case AS_AUDIO_BUFFER_TOO_SMALL:
      return @"Audio buffer too small";
    case AS_TIMED_OUT:
      return @"Timed out";
    default:
      break;
  }
  return @"Audio streaming failed";
}

//
// failWithErrorCode:reason:
//
// Sets the playback state to failed and logs the error.
//
// Parameters:
//    errorCode - the error condition
//    reason    - the error reason
//
- (void)failWithErrorCode:(AudioStreamerErrorCode)errorCode reason:(NSString*)reason
{
  [self failWithErrorCode:errorCode reason:reason shouldStop:YES];
}

//
// failWithErrorCode:reason:shouldStop:
//
// Sets the playback state to failed and logs the error.
//
// Parameters:
//    errorCode  - the error condition
//    reason     - the error reason
//    shouldStop - whether the stream should stop immediately or not
//
- (void)failWithErrorCode:(AudioStreamerErrorCode)errorCode reason:(NSString*)reason shouldStop:(BOOL)shouldStop {
  // Only set the error once.
  if (_error) {
    return;
  }

  assert(reason != nil);

  /* Attempt to save our last point of progress */
  [self progress:&lastProgress];

  LOG(@"got an error: %@ (%@)", [[self class] descriptionForErrorCode:errorCode], reason);
  _errorCode = errorCode; // Deprecated.

  NSDictionary *userInfo = @{NSLocalizedDescriptionKey:
                               NSLocalizedString([[self class] descriptionForErrorCode:errorCode], nil),
                             NSLocalizedFailureReasonErrorKey:
                               NSLocalizedString(reason, nil)};
  _error = [NSError errorWithDomain:ASErrorDomain code:errorCode userInfo:userInfo];

  if (shouldStop)
  {
    state_ = AS_DONE; // Delay notification to avoid race conditions

    [self stop];

    [[NSNotificationCenter defaultCenter]
          postNotificationName:ASStatusChangedNotification
                        object:self];
  }
}

- (void)setState:(AudioStreamerState)aStatus {
  LOG(@"transitioning to state:%tu", aStatus);

  if (state_ == aStatus) return;
  state_ = aStatus;

  [[NSNotificationCenter defaultCenter]
        postNotificationName:ASStatusChangedNotification
                      object:self];
}

/**
 * @brief Check the stream for a timeout, and trigger one if this is a timeout
 *        situation
 */
- (void)checkTimeout {
  /* Ignore if we're in the paused state */
  if (state_ == AS_PAUSED) return;
  /* If the read stream has been unscheduled and not rescheduled, then this tick
     is irrelevant because we're not trying to read data anyway */
  if (unscheduled && !rescheduled) return;
  /* If the read stream was unscheduled and then rescheduled, then we still
     discard this sample (not enough of it was known to be in the "scheduled
     state"), but we clear flags so we might process the next sample */
  if (rescheduled && unscheduled) {
    unscheduled = false;
    rescheduled = false;
    return;
  }

  /* events happened? no timeout. */
  if (events > 0) {
    events = 0;
    return;
  }

  [self failWithErrorCode:AS_TIMED_OUT
                   reason:[NSString stringWithFormat:@"No data was received in %d seconds while expecting data.", _timeoutInterval]];
}

//
// hintForFileExtension:
//
// Generates a first guess for the file type based on the file's extension
//
// Parameters:
//    fileExtension - the file extension
//
// returns a file type hint that can be passed to the AudioFileStream
//
+ (AudioFileTypeID)hintForFileExtension:(NSString *)fileExtension {
  if ([fileExtension isEqual:@"mp3"]) {
    return kAudioFileMP3Type;
  } else if ([fileExtension isEqual:@"wav"]) {
    return kAudioFileWAVEType;
  } else if ([fileExtension isEqual:@"aifc"]) {
    return kAudioFileAIFCType;
  } else if ([fileExtension isEqual:@"aiff"]) {
    return kAudioFileAIFFType;
  } else if ([fileExtension isEqual:@"m4a"]) {
    return kAudioFileM4AType;
  } else if ([fileExtension isEqual:@"mp4"]) {
    return kAudioFileMPEG4Type;
  } else if ([fileExtension isEqual:@"caf"]) {
    return kAudioFileCAFType;
  } else if ([fileExtension isEqual:@"aac"]) {
    return kAudioFileAAC_ADTSType;
  }
  return 0;
}

/**
 * @brief Guess the file type based on the listed MIME type in the http response
 *
 * Code from:
 * https://github.com/DigitalDJ/AudioStreamer/blob/master/Classes/AudioStreamer.m
 */
+ (AudioFileTypeID)hintForMIMEType:(NSString*)mimeType {
  if ([mimeType isEqual:@"audio/mpeg"]) {
    return kAudioFileMP3Type;
  } else if ([mimeType isEqual:@"audio/x-wav"]) {
    return kAudioFileWAVEType;
  } else if ([mimeType isEqual:@"audio/x-aiff"]) {
    return kAudioFileAIFFType;
  } else if ([mimeType isEqual:@"audio/x-m4a"]) {
    return kAudioFileM4AType;
  } else if ([mimeType isEqual:@"audio/mp4"]) {
    return kAudioFileMPEG4Type;
  } else if ([mimeType isEqual:@"audio/x-caf"]) {
    return kAudioFileCAFType;
  } else if ([mimeType isEqual:@"audio/aac"] ||
             [mimeType isEqual:@"audio/aacp"]) {
    return kAudioFileAAC_ADTSType;
  }
  return 0;
}

/**
 * @brief Creates a new stream for reading audio data
 *
 * The stream is currently only compatible with remote HTTP sources. The stream
 * opened could possibly be seeked into the middle of the file, or have other
 * things like proxies attached to it.
 *
 * @return YES if the stream was opened, or NO if it failed to open
 */
- (BOOL)openReadStream {
  NSAssert(stream == NULL, @"Download stream already initialized");

  /* Create our GET request */
  CFHTTPMessageRef message =
      CFHTTPMessageCreateRequest(NULL,
                                 CFSTR("GET"),
                                 (__bridge CFURLRef) _url,
                                 kCFHTTPVersion1_1);

  /* When seeking to a time within the stream, we both already know the file
     length and the seekByteOffset will be set to know what to send to the
     remote server */
  if (fileLength > 0 && seekByteOffset > 0) {
    NSString *str = [NSString stringWithFormat:@"bytes=%lld-%lld",
                                               seekByteOffset, fileLength - 1];
    CFHTTPMessageSetHeaderFieldValue(message,
                                     CFSTR("Range"),
                                     (__bridge CFStringRef) str);
    discontinuous = vbr;
  }

  stream = CFReadStreamCreateForHTTPRequest(NULL, message);
  CFRelease(message);

  /* Follow redirection codes by default */
  CHECK_ERR(!CFReadStreamSetProperty(stream,
                                     kCFStreamPropertyHTTPShouldAutoredirect,
                                     kCFBooleanTrue),
            AS_FILE_STREAM_SET_PROPERTY_FAILED, @"", NO);

  /* Deal with proxies */
  switch (proxyType) {
    case PROXY_HTTP: {
      CFDictionaryRef proxySettings;
      if ([[[_url scheme] lowercaseString] isEqualToString:@"https"]) {
        proxySettings = (__bridge CFDictionaryRef)
          [NSMutableDictionary dictionaryWithObjectsAndKeys:
            proxyHost, kCFStreamPropertyHTTPSProxyHost,
            @(proxyPort), kCFStreamPropertyHTTPSProxyPort,
            nil];
      } else {
        proxySettings = (__bridge CFDictionaryRef)
        [NSMutableDictionary dictionaryWithObjectsAndKeys:
          proxyHost, kCFStreamPropertyHTTPProxyHost,
          @(proxyPort), kCFStreamPropertyHTTPProxyPort,
          nil];
      }
      CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy,
                              proxySettings);
      break;
    }
    case PROXY_SOCKS: {
      CFDictionaryRef proxySettings = (__bridge CFDictionaryRef)
        [NSMutableDictionary dictionaryWithObjectsAndKeys:
          proxyHost, kCFStreamPropertySOCKSProxyHost,
          @(proxyPort), kCFStreamPropertySOCKSProxyPort,
          nil];
      CFReadStreamSetProperty(stream, kCFStreamPropertySOCKSProxy,
                              proxySettings);
      break;
    }
    default:
    case PROXY_SYSTEM: {
      CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
      CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy, proxySettings);
      CFRelease(proxySettings);
      break;
    }
  }

  /* handle SSL connections */
  if ([[[_url scheme] lowercaseString] isEqualToString:@"https"]) {
    NSDictionary *sslSettings = @{
      (id)kCFStreamSSLLevel: (NSString*)kCFStreamSocketSecurityLevelNegotiatedSSL,
      (id)kCFStreamSSLValidatesCertificateChain:  @YES,
      (id)kCFStreamSSLPeerName:                   [NSNull null]
    };

    CFReadStreamSetProperty(stream, kCFStreamPropertySSLSettings,
                            (__bridge CFDictionaryRef) sslSettings);
  }

  [self setState:AS_WAITING_FOR_DATA];

  CHECK_ERR(!CFReadStreamOpen(stream), AS_FILE_STREAM_OPEN_FAILED, @"", NO);

  /* Set the callback to receive a few events, and then we're ready to
     schedule and go */
  CFStreamClientContext context = {0, (__bridge void*) self, NULL, NULL, NULL};
  CFReadStreamSetClient(stream,
                        kCFStreamEventHasBytesAvailable |
                          kCFStreamEventErrorOccurred |
                          kCFStreamEventEndEncountered,
                        ASReadStreamCallBack,
                        &context);
  CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(),
                                  kCFRunLoopCommonModes);

  return YES;
}

//
// handleReadFromStream:eventType:
//
// Reads data from the network file stream into the AudioFileStream
//
// Parameters:
//    aStream - the network file stream
//    eventType - the event which triggered this method
//
- (void)handleReadFromStream:(CFReadStreamRef)aStream
                   eventType:(CFStreamEventType)eventType {
  assert(aStream == stream);
  assert(!waitingOnBuffer || _bufferInfinite);
  events++;

  switch (eventType) {
    case kCFStreamEventErrorOccurred:
      LOG(@"error");
      /* Deprecated. Will eventually be a local variable. */
      _networkError = (__bridge_transfer NSError*) CFReadStreamCopyError(aStream);
      if (!_error) {
        if (buffersUsed != 0) {
          /* shouldStop = NO as we will retry connecting later */
          [self failWithErrorCode:AS_NETWORK_CONNECTION_FAILED reason:[_networkError localizedDescription] shouldStop:NO];
        } else {
          [self failWithErrorCode:AS_NETWORK_CONNECTION_FAILED reason:[_networkError localizedDescription] shouldStop:YES];
        }
      } else {
        /* We tried reconnecting but failed. Time to stop. */
        state_ = AS_DONE; // Delay notification to avoid race conditions
        [self stop];
        [[NSNotificationCenter defaultCenter]
              postNotificationName:ASStatusChangedNotification
                            object:self];
      }
      return;

    case kCFStreamEventEndEncountered:
      LOG(@"end");
      [timeout invalidate];
      timeout = nil;

      /* Flush out extra data if necessary */
      if (bytesFilled) {
        /* Disregard return value because we're at the end of the stream anyway
           so there's no bother in pausing it */
        if ([self enqueueBuffer] < 0) return;
      }

      /* If we never received any packets, then we're done now */
      if (state_ == AS_WAITING_FOR_DATA) {
        if (buffersUsed > 0) {
          /* If we got some data, the stream was either short or interrupted early.
           * We have some data so go ahead and play that. */
          [self startAudioQueue];
        } else if ((seekByteOffset - dataOffset) != 0) {
          /* If a seek was performed, and no data came back, then we probably
             seeked to the end or near the end of the stream */
          [self setState:AS_DONE];
        } else {
          /* In other cases then we just hit an error */
          [self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND reason:@""];
        }
      }
      return;

    default:
      return;

    case kCFStreamEventHasBytesAvailable:
      break;
  }
  LOG(@"data");

  /* Read off the HTTP headers into our own class if we haven't done so */
  if (!_httpHeaders) {
    CFTypeRef message =
        CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
    _httpHeaders = (__bridge_transfer NSDictionary *)
        CFHTTPMessageCopyAllHeaderFields((CFHTTPMessageRef) message);
    CFRelease(message);

    //
    // Only read the content length if we seeked to time zero, otherwise
    // we only have a subset of the total bytes.
    //
    if ((seekByteOffset - dataOffset) == 0) {
      fileLength = (UInt64)[_httpHeaders[@"Content-Length"] longLongValue];
    }
  }

  OSStatus osErr;

  /* If we haven't yet opened up a file stream, then do so now */
  if (!audioFileStream) {
    /* If a file type wasn't specified, we have to guess */
    if (_fileType == 0) {
      _fileType = [[self class] hintForMIMEType: _httpHeaders[@"Content-Type"]];
      if (_fileType == 0) {
        _fileType = [[self class] hintForFileExtension:
                      [[_url path] pathExtension]];
        if (_fileType == 0) {
          _fileType = kAudioFileMP3Type;
          defaultFileTypeUsed = true;
        }
      }
    }

    // create an audio file stream parser
    osErr = AudioFileStreamOpen((__bridge void*) self, ASPropertyListenerProc,
                                         ASPacketsProc, _fileType, &audioFileStream);
    CHECK_ERR(osErr, AS_FILE_STREAM_OPEN_FAILED, @"");
  }

  UInt32 bufferSize = (packetBufferSize > 0) ? packetBufferSize : _bufferSize;
  if (bufferSize <= 0) {
    bufferSize = kDefaultAQDefaultBufSize;
  }

  UInt8 bytes[bufferSize];
  CFIndex length;
  int i;
  for (i = 0;
       i < 3 && ![self isDone] && CFReadStreamHasBytesAvailable(stream);
       i++) {
    length = CFReadStreamRead(stream, bytes, (CFIndex)sizeof(bytes));

    if (length < 0) {
      if (didConnect) {
        didConnect = false;
        // Ignore. A network connection likely happened so we should wait for that to throw.
        // If this happens again, throw a audio data not found error.
        return;
      }
      [self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND reason:@""];
      return;
    } else if (length == 0) {
      return;
    }

    didConnect = true;

    // Shoutcast support.
    if (defaultFileTypeUsed) {
      NSUInteger streamStart = 0;
      NSUInteger lineStart = 0;
      while (YES)
      {
        if (streamStart + 3 > (NSUInteger)length)
        {
          break;
        }

        if (bytes[streamStart] == '\r' && bytes[streamStart+1] == '\n')
        {
          NSString *fullString = [[NSString alloc] initWithBytes:bytes
                                                          length:streamStart
                                                        encoding:NSUTF8StringEncoding];
          if (fullString == nil)
          {
            fullString = [[NSString alloc] initWithBytes:bytes
                                                  length:streamStart
                                                encoding:NSISOLatin1StringEncoding];
          }
          NSArray *lineItems = [[fullString substringWithRange:NSMakeRange(lineStart,
                                                                  streamStart-lineStart)]
                                   componentsSeparatedByString:@":"];

          if ([lineItems count] >= 2)
          {
            if ([lineItems[0] caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
              LOG(@"Shoutcast Stream Content-Type: %@", lineItems[1]);
              AudioFileStreamClose(audioFileStream);
              AudioQueueStop(audioQueue, true);
              AudioQueueReset(audioQueue);
              if (buffers) {
                for (UInt32 j = 0; j < _bufferCount; ++j) {
                  AudioQueueFreeBuffer(audioQueue, buffers[j]);
                }
              }

              _fileType = [[self class] hintForMIMEType:lineItems[1]];
              if (_fileType == 0) {
                // Okay, we can now default to this now.
                _fileType = kAudioFileMP3Type;
              }
              defaultFileTypeUsed = false;

              osErr = AudioFileStreamOpen((__bridge void*) self, ASPropertyListenerProc,
                                            ASPacketsProc, _fileType, &audioFileStream);
              CHECK_ERR(osErr, AS_FILE_STREAM_OPEN_FAILED, @"");

              break; // We're not interested in any other metadata here.
            }
          }

          if (bytes[streamStart+2] == '\r' && bytes[streamStart+3] == '\n')
          {
            break;
          }

          lineStart = streamStart+2;
        }

        streamStart++;
      }
    }

    isParsing = true;
    if (discontinuous) {
      osErr = AudioFileStreamParseBytes(audioFileStream, (UInt32) length, bytes,
                                        kAudioFileStreamParseFlag_Discontinuity);
    } else {
      osErr = AudioFileStreamParseBytes(audioFileStream, (UInt32) length,
                                        bytes, 0);
    }
    isParsing = false;
    if ([self isDone]) [self closeFileStream];
    CHECK_ERR(osErr, AS_FILE_STREAM_PARSE_BYTES_FAILED, @"");
  }
}

//
// enqueueBuffer
//
// Called from ASPacketsProc and connectionDidFinishLoading to pass filled audio
// buffers (filled by ASPacketsProc) to the AudioQueue for playback. This
// function does not return until a buffer is idle for further filling or
// the AudioQueue is stopped.
//
// This function is adapted from Apple's example in AudioFileStreamExample with
// CBR functionality added.
//
- (int)enqueueBuffer {
  assert(stream != NULL);

  assert(!inuse[fillBufferIndex]);
  inuse[fillBufferIndex] = true;    // set in use flag
  buffersUsed++;

  // enqueue buffer
  AudioQueueBufferRef fillBuf = buffers[fillBufferIndex];
  fillBuf->mAudioDataByteSize = bytesFilled;

  OSStatus osErr;
  if (packetsFilled) {
    osErr = AudioQueueEnqueueBuffer(audioQueue, fillBuf, packetsFilled,
                                    packetDescs);
  } else {
    osErr = AudioQueueEnqueueBuffer(audioQueue, fillBuf, 0, NULL);
  }
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"", -1);

  LOG(@"committed buffer %d", fillBufferIndex);

  if (state_ == AS_WAITING_FOR_DATA) {
    /* Once we have a small amount of queued data, then we can go ahead and
     * start the audio queue and the file stream should remain ahead of it */
    if ((_bufferCount < _bufferFillCountToStart && buffersUsed >= _bufferCount) || buffersUsed >= _bufferFillCountToStart) {
      _error = nil; // We have successfully reconnected. Clear the error.
      if (![self startAudioQueue]) return -1;
    }
  }

  /* move on to the next buffer and wait for it to be in use */
  if (++fillBufferIndex >= _bufferCount) fillBufferIndex = 0;
  bytesFilled   = 0;    // reset bytes filled
  packetsFilled = 0;    // reset packets filled

  /* If we have no more queued data, and the stream has reached its end, then
     we're not going to be enqueueing any more buffers to the audio stream. In
     this case flush it out and asynchronously stop it */
  if (queued_head == NULL &&
      CFReadStreamGetStatus(stream) == kCFStreamStatusAtEnd) {
    osErr = AudioQueueFlush(audioQueue);
    CHECK_ERR(osErr, AS_AUDIO_QUEUE_FLUSH_FAILED, @"", -1);
  }

  if (inuse[fillBufferIndex]) {
    LOG(@"waiting for buffer %d", fillBufferIndex);
    if (!_bufferInfinite) {
      CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(),
                                        kCFRunLoopCommonModes);
      /* Make sure we don't have ourselves marked as rescheduled */
      unscheduled = true;
      rescheduled = false;
    }
    waitingOnBuffer = true;
    return 0;
  }
  return 1;
}

//
// createQueue
//
// Method to create the AudioQueue from the parameters gathered by the
// AudioFileStream.
//
// Creation is deferred to the handling of the first audio packet (although
// it could be handled any time after kAudioFileStreamProperty_ReadyToProducePackets
// is true).
//
- (void)createQueue {
  assert(audioQueue == NULL);

  // create the audio queue
  OSStatus osErr = AudioQueueNewOutput(&_streamDescription, ASAudioQueueOutputCallback,
                                       (__bridge void*) self, CFRunLoopGetMain(), NULL,
                                       0, &audioQueue);
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_CREATION_FAILED, @"");

  // start the queue if it has not been started already
  // listen to the "isRunning" property
  osErr = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning,
                                        ASAudioQueueIsRunningCallback,
                                        (__bridge void*) self);
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_ADD_LISTENER_FAILED, @"");

  if (vbr) {
    /* Try to determine the packet size, eventually falling back to some
       reasonable default of a size */
    UInt32 sizeOfUInt32 = sizeof(UInt32);
    osErr = AudioFileStreamGetProperty(audioFileStream,
                                       kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfUInt32,
                                       &packetBufferSize);

    if (osErr || packetBufferSize == 0) {
      osErr = AudioFileStreamGetProperty(audioFileStream,
                                         kAudioFileStreamProperty_MaximumPacketSize, &sizeOfUInt32,
                                         &packetBufferSize);
      if (osErr || packetBufferSize == 0) {
        // No packet size available, just use the default
        packetBufferSize = _bufferSize;
      }
    }
  } else {
    packetBufferSize = _bufferSize;
  }

  // allocate audio queue buffers
  buffers = malloc(_bufferCount * sizeof(buffers[0]));
  CHECK_ERR(buffers == NULL, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, @"");
  inuse = calloc(_bufferCount, sizeof(inuse[0]));
  CHECK_ERR(inuse == NULL, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, @"");
  for (UInt32 i = 0; i < _bufferCount; ++i) {
    osErr = AudioQueueAllocateBuffer(audioQueue, packetBufferSize,
                                   &buffers[i]);
    CHECK_ERR(osErr, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, @"");
  }

  /* Some audio formats have a "magic cookie" which needs to be transferred from
     the file stream to the audio queue. If any of this fails it's "OK" because
     the stream either doesn't have a magic or error will propagate later */

  // get the cookie size
  UInt32 cookieSize;
  Boolean writable;
  OSStatus ignorableError;
  ignorableError = AudioFileStreamGetPropertyInfo(audioFileStream,
                     kAudioFileStreamProperty_MagicCookieData, &cookieSize,
                     &writable);
  if (ignorableError) {
    return;
  }

  // get the cookie data
  void *cookieData = calloc(1, cookieSize);
  if (cookieData == NULL) return;
  ignorableError = AudioFileStreamGetProperty(audioFileStream,
                     kAudioFileStreamProperty_MagicCookieData, &cookieSize,
                     cookieData);
  if (ignorableError) {
    free(cookieData);
    return;
  }

  // set the cookie on the queue. Don't worry if it fails, all we'd to is return
  // anyway
  AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData,
                        cookieSize);
  free(cookieData);

  /* Playback rate */

  UInt32 propVal = 1;
  AudioQueueSetProperty(audioQueue, kAudioQueueProperty_EnableTimePitch, &propVal, sizeof(propVal));

  propVal = kAudioQueueTimePitchAlgorithm_Spectral;
  AudioQueueSetProperty(audioQueue, kAudioQueueProperty_TimePitchAlgorithm, &propVal, sizeof(propVal));

  propVal = (_playbackRate == 1.0f || fileLength == 0) ? 1 : 0;
  AudioQueueSetProperty(audioQueue, kAudioQueueProperty_TimePitchBypass, &propVal, sizeof(propVal));

  if (_playbackRate != 1.0f && fileLength > 0) {
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_PlayRate, _playbackRate);
  }
}

/**
 * @brief Sets up the audio queue and starts it
 *
 * This will set all the properties before starting the stream.
 *
 * @return YES if the AudioQueue was sucessfully set to start, NO if an error occurred
 */
- (BOOL)startAudioQueue
{
  OSStatus osErr = AudioQueueStart(audioQueue, NULL);
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_START_FAILED, @"", NO);

  if (queuePaused) {
    queuePaused = false;
    [self setState:AS_PLAYING];
  } else {
    [self setState:AS_WAITING_FOR_QUEUE_TO_START];
  }

  return YES;
}

//
// handlePropertyChangeForFileStream:fileStreamPropertyID:ioFlags:
//
// Object method which handles implementation of ASPropertyListenerProc
//
// Parameters:
//    inAudioFileStream - should be the same as self->audioFileStream
//    inPropertyID - the property that changed
//    ioFlags - the ioFlags passed in
//
- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags {
  assert(inAudioFileStream == audioFileStream);

  switch (inPropertyID) {
    case kAudioFileStreamProperty_ReadyToProducePackets:
      LOG(@"ready for packets");
      discontinuous = true;
      break;

    case kAudioFileStreamProperty_DataOffset: {
      SInt64 offset;
      UInt32 offsetSize = sizeof(offset);
      OSStatus osErr = AudioFileStreamGetProperty(inAudioFileStream,
                                                  kAudioFileStreamProperty_DataOffset,
                                                  &offsetSize, &offset);
      CHECK_ERR(osErr, AS_FILE_STREAM_GET_PROPERTY_FAILED, @"");
      dataOffset = (UInt64)offset;

      if (audioDataByteCount) {
        fileLength = dataOffset + audioDataByteCount;
      }
      LOG(@"have data offset: %llx", dataOffset);
      break;
    }

    case kAudioFileStreamProperty_AudioDataByteCount: {
      UInt32 byteCountSize = sizeof(UInt64);
      OSStatus osErr = AudioFileStreamGetProperty(inAudioFileStream,
                                                  kAudioFileStreamProperty_AudioDataByteCount,
                                                  &byteCountSize, &audioDataByteCount);
      CHECK_ERR(osErr, AS_FILE_STREAM_GET_PROPERTY_FAILED, @"");
      fileLength = dataOffset + audioDataByteCount;
      LOG(@"have byte count: %llx", audioDataByteCount);
      break;
    }

    case kAudioFileStreamProperty_DataFormat: {
      /* If we seeked, don't re-read the data */
      if (_streamDescription.mSampleRate == 0) {
        UInt32 descSize = sizeof(_streamDescription);

        OSStatus osErr = AudioFileStreamGetProperty(inAudioFileStream,
                                                    kAudioFileStreamProperty_DataFormat,
                                                    &descSize, &_streamDescription);
        CHECK_ERR(osErr, AS_FILE_STREAM_GET_PROPERTY_FAILED, @"");
      }
      LOG(@"have data format");
      break;
    }

    case kAudioFileStreamProperty_FormatList: {
      Boolean outWriteable;
      UInt32 formatListSize;
      OSStatus osErr = AudioFileStreamGetPropertyInfo(inAudioFileStream,
                                                      kAudioFileStreamProperty_FormatList,
                                                      &formatListSize, &outWriteable);
      CHECK_ERR(osErr, AS_FILE_STREAM_GET_PROPERTY_FAILED, @"");

      AudioFormatListItem *formatList = malloc(formatListSize);
      CHECK_ERR(formatList == NULL, AS_FILE_STREAM_GET_PROPERTY_FAILED, @"");
      osErr = AudioFileStreamGetProperty(inAudioFileStream,
                                         kAudioFileStreamProperty_FormatList,
                                         &formatListSize, formatList);
      if (osErr) {
        free(formatList);
        [self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED reason:@""];
        return;
      }

      for (unsigned long i = 0; i * sizeof(AudioFormatListItem) < formatListSize;
           i += sizeof(AudioFormatListItem)) {
        AudioStreamBasicDescription pasbd = formatList[i].mASBD;

        if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
        {
          _streamDescription = pasbd;
          break;
        }
      }
      free(formatList);
      break;
    }
  }
}

//
// handleAudioPackets:numberBytes:numberPackets:packetDescriptions:
//
// Object method which handles the implementation of ASPacketsProc
//
// Parameters:
//    inInputData - the packet data
//    inNumberBytes - byte size of the data
//    inNumberPackets - number of packets in the data
//    inPacketDescriptions - packet descriptions
//
- (void)handleAudioPackets:(const void*)inInputData
               numberBytes:(UInt32)inNumberBytes
             numberPackets:(UInt32)inNumberPackets
        packetDescriptions:(AudioStreamPacketDescription*)inPacketDescriptions {
  if ([self isDone]) return;
  // we have successfully read the first packets from the audio stream, so
  // clear the "discontinuous" flag
  if (discontinuous) {
    discontinuous = false;
  }

  if (!audioQueue) {
    vbr = (inPacketDescriptions != NULL);

    OSStatus status = 0;
    UInt32 ioFlags = 0;
    long long byteOffset;
    SInt64 lower = 0;
    SInt64 upper = 1000000;
    SInt64 current;
    while (upper - lower > 1 || status != 0)
    {
      current = (upper + lower) / 2;
      status = AudioFileStreamSeek(audioFileStream, current, &byteOffset, &ioFlags);
      if (status == 0)
      {
        lower = current;
      }
      else
      {
        upper = current;
      }
    }
    AudioFileStreamSeek(audioFileStream, 0, &byteOffset, &ioFlags);
    totalAudioPackets = (UInt64)current + 1;
    seekByteOffset = (UInt64)byteOffset + dataOffset;
    [self closeReadStream];
    [self openReadStream];

    assert(!waitingOnBuffer);
    [self createQueue];
    if ([self isDone]) return; // Queue creation failed. Abort.
  }

  if (inPacketDescriptions) {
    /* Place each packet into a buffer and then send each buffer into the audio
       queue */
    UInt32 i;
    for (i = 0; i < inNumberPackets && !waitingOnBuffer && queued_head == NULL; i++) {
      AudioStreamPacketDescription *desc = &inPacketDescriptions[i];
      int ret = [self handleVBRPacket:(inInputData + desc->mStartOffset)
                              desc:desc];
      CHECK_ERR(ret < 0, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");
      if (!ret) break;
    }
    if (i == inNumberPackets) return;

    for (; i < inNumberPackets; i++) {
      /* Allocate the packet */
      UInt32 size = inPacketDescriptions[i].mDataByteSize;
      queued_packet_t *packet = malloc(sizeof(queued_packet_t) + size);
      CHECK_ERR(packet == NULL, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");

      /* Prepare the packet */
      packet->next = NULL;
      packet->desc = inPacketDescriptions[i];
      packet->desc.mStartOffset = 0;
      packet->byteSize = 0; // Not used when we have a desc.
      memcpy(packet->data, inInputData + inPacketDescriptions[i].mStartOffset,
             size);

      if (queued_head == NULL) {
        queued_head = queued_tail = packet;
      } else {
        queued_tail->next = packet;
        queued_tail = packet;
      }
    }
  } else {
    size_t offset = 0;
    while (inNumberBytes && !waitingOnBuffer && queued_head == NULL) {
      size_t copySize;
      int ret = [self handleCBRPacket:(inInputData + offset)
                             byteSize:inNumberBytes
                             copySize:&copySize];
      CHECK_ERR(ret < 0, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");
      if (!ret) break;
      inNumberBytes -= copySize;
      offset += copySize;
    }
    while (inNumberBytes) {
      /* Allocate the packet */
      size_t size = MIN(packetBufferSize - bytesFilled, inNumberBytes);
      queued_packet_t *packet = malloc(sizeof(queued_packet_t) + size);
      CHECK_ERR(packet == NULL, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");

      /* Prepare the packet */
      packet->next = NULL;
      packet->byteSize = inNumberBytes;
      packet->offset = offset;
      memcpy(packet->data, inInputData + offset, size);

      if (queued_head == NULL) {
        queued_head = queued_tail = packet;
      } else {
        queued_tail->next = packet;
        queued_tail = packet;
      }

      inNumberBytes -= size;
      offset += size;
    }
  }
}

- (int)handleVBRPacket:(const void*)data
                desc:(AudioStreamPacketDescription*)desc{
  assert(audioQueue != NULL);
  UInt32 packetSize = desc->mDataByteSize;

  /* This shouldn't happen because most of the time we read the packet buffer
     size from the file stream, but if we restored to guessing it we could
     come up too small here. Developers may have to set the bufferCount property. */
  CHECK_ERR(packetSize > packetBufferSize, AS_AUDIO_BUFFER_TOO_SMALL,
            @"The audio buffer was too small to handle the audio packets.", -1);

  // if the space remaining in the buffer is not enough for this packet, then
  // enqueue the buffer and wait for another to become available.
  if (packetBufferSize - bytesFilled < packetSize) {
    int hasFreeBuffer = [self enqueueBuffer];
    if (hasFreeBuffer <= 0) {
      return hasFreeBuffer;
    }
    assert(bytesFilled == 0);
  }

  /* global statistics */
  processedPacketsSizeTotal += 8.0 * packetSize / (_streamDescription.mFramesPerPacket / _streamDescription.mSampleRate);
  processedPacketsCount++;
  if (processedPacketsCount > BitRateEstimationMinPackets &&
      !bitrateNotification) {
    bitrateNotification = true;
    [[NSNotificationCenter defaultCenter]
          postNotificationName:ASBitrateReadyNotification
                        object:self];
  }

  // copy data to the audio queue buffer
  AudioQueueBufferRef buf = buffers[fillBufferIndex];
  memcpy(buf->mAudioData + bytesFilled, data, (unsigned long)packetSize);

  // fill out packet description to pass to enqueue() later on
  packetDescs[packetsFilled] = *desc;
  // Make sure the offset is relative to the start of the audio buffer
  packetDescs[packetsFilled].mStartOffset = bytesFilled;
  // keep track of bytes filled and packets filled
  bytesFilled += packetSize;
  packetsFilled++;

  /* If filled our buffer with packets, then commit it to the system */
  if (packetsFilled >= kAQMaxPacketDescs) return [self enqueueBuffer];
  return 1;
}

- (int)handleCBRPacket:(const void*)data
              byteSize:(UInt32)byteSize
              copySize:(size_t*)copySize{
  assert(audioQueue != NULL);

  size_t bufSpaceRemaining = packetBufferSize - bytesFilled;
  if (bufSpaceRemaining < byteSize) {
    int hasFreeBuffer = [self enqueueBuffer];
    if (hasFreeBuffer <= 0) {
      return hasFreeBuffer;
    }
    assert(bytesFilled == 0);
  }

  if ([self isDone]) return 0;

  bufSpaceRemaining = packetBufferSize - bytesFilled;
  *copySize = MIN(bufSpaceRemaining, byteSize);

  AudioQueueBufferRef buf = buffers[fillBufferIndex];
  memcpy(buf->mAudioData + bytesFilled, data, *copySize);

  bytesFilled += *copySize;

  // Bitrate isn't estimated with these packets.
  // It's safe to calculate the bitrate as soon as we start getting audio.
  if (!bitrateNotification) {
    bitrateNotification = true;
    [[NSNotificationCenter defaultCenter]
          postNotificationName:ASBitrateReadyNotification
                        object:self];
  }

  return 1;
}

/**
 * @brief Internal helper for sending cached packets to the audio queue
 *
 * This method is enqueued for delivery when an audio buffer is freed
 */
- (void)enqueueCachedData {
  if ([self isDone]) return;
  assert(!waitingOnBuffer);
  assert(!inuse[fillBufferIndex]);
  assert(stream != NULL);
  LOG(@"processing some cached data");

  /* Queue up as many packets as possible into the buffers */
  queued_packet_t *cur = queued_head;
  while (cur != NULL) {
    if (cur->byteSize) {
      size_t copySize;
      int ret = [self handleCBRPacket:cur->data
                             byteSize:cur->byteSize
                             copySize:&copySize];
      CHECK_ERR(ret < 0, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");
      if (ret == 0) break;
    } else {
      int ret = [self handleVBRPacket:cur->data desc:&cur->desc];
      CHECK_ERR(ret < 0, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");
      if (ret == 0) break;
    }
    queued_packet_t *next = cur->next;
    free(cur);
    cur = next;
  }
  queued_head = cur;

  /* If we finished queueing all our saved packets, we can re-schedule the
   * stream to run */
  if (cur == NULL) {
    queued_tail = NULL;
    rescheduled = true;
    if (!_bufferInfinite) {
      CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(),
                                      kCFRunLoopCommonModes);
    }
  }
}

//
// handleBufferCompleteForQueue:buffer:
//
// Handles the buffer completion notification from the audio queue
//
// Parameters:
//    inAQ - the queue
//    inBuffer - the buffer
//
- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
                              buffer:(AudioQueueBufferRef)inBuffer {
  /* we're only registered for one audio queue... */
  assert(inAQ == audioQueue);
  /* Sanity check to make sure we're on the right thread */
  assert([NSThread currentThread] == [NSThread mainThread]);

  /* Figure out which buffer just became free, and it had better damn well be
     one of our own buffers */
  UInt32 idx;
  for (idx = 0; idx < _bufferCount; idx++) {
    if (buffers[idx] == inBuffer) break;
  }
  CHECK_ERR(idx >= _bufferCount, AS_AUDIO_QUEUE_BUFFER_MISMATCH, @"");
  assert(inuse[idx]);

  LOG(@"buffer %u finished", (unsigned int)idx);

  /* Signal the buffer is no longer in use */
  inuse[idx] = false;
  buffersUsed--;

  /* If we're done with the buffers because the stream is dying, then there's no
   * need to call more methods on it */
  if (state_ == AS_STOPPED) {
    return;

  /* If there is absolutely no more data which will ever come into the stream,
   * then we're done with the audio */
  } else if (buffersUsed == 0 && queued_head == NULL && stream != nil &&
      CFReadStreamGetStatus(stream) == kCFStreamStatusAtEnd) {
    assert(!waitingOnBuffer);
    AudioQueueStop(audioQueue, false);

  /* If we are out of buffers then we need to reconnect or wait */
  } else if (buffersUsed == 0 && ![self isDone] && ![self isWaiting]) {
    if (_error)
    {
      /* A previous error occurred without the need to halt,
       * so we can try reconnecting */
      if (fileLength != 0)
      {
        /* Livestream - don't bother reconnecting */
        state_ = AS_DONE; // Delay notification to avoid race conditions
        [self stop];
        [[NSNotificationCenter defaultCenter]
         postNotificationName:ASStatusChangedNotification
         object:self];
      }
      /* Try to reconnect */
      double progress;
      [self progress:&progress];
      [self seekToTime:progress];
    }
    else
    {
      /* No previous error occurred so we simply aren't buffering fasting enough */
      OSStatus osErr = AudioQueuePause(audioQueue);
      CHECK_ERR(osErr, AS_AUDIO_QUEUE_PAUSE_FAILED, @"");
      queuePaused = true;

      /* This can either fix or delay the problem
       * If it cannot fix it, the network is simply too slow */
      if (packetBufferSize < 65536) packetBufferSize = packetBufferSize * 2;
      for (UInt32 j = 0; j < _bufferCount; ++j) {
        AudioQueueFreeBuffer(audioQueue, buffers[j]);
      }
      for (UInt32 i = 0; i < _bufferCount; ++i) {
        osErr = AudioQueueAllocateBuffer(audioQueue, packetBufferSize,
                                         &buffers[i]);
        CHECK_ERR(osErr, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, @"");
      }

      [self setState:AS_WAITING_FOR_DATA];
    }

  /* If we just opened up a buffer so try to fill it with some cached
   * data if there is any available */
  } else if (waitingOnBuffer) {
    waitingOnBuffer = false;
    [self enqueueCachedData];
  }
}

//
// handlePropertyChangeForQueue:propertyID:
//
// Implementation for ASAudioQueueIsRunningCallback
//
// Parameters:
//    inAQ - the audio queue
//    inID - the property ID
//
- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
                          propertyID:(AudioQueuePropertyID)inID {
  /* Sanity check to make sure we're on the expected thread */
  assert([NSThread currentThread] == [NSThread mainThread]);
  /* We only asked for one property, so the audio queue had better damn well
     only tell us about this property */
  assert(inID == kAudioQueueProperty_IsRunning);

  if (state_ == AS_WAITING_FOR_QUEUE_TO_START) {
    [self setState:AS_PLAYING];
  } else if (state_ != AS_STOPPED && !seeking && !_error) {
    UInt32 running;
    UInt32 output = sizeof(running);
    OSStatus osErr = AudioQueueGetProperty(audioQueue, kAudioQueueProperty_IsRunning,
                                           &running, &output);
    if (!osErr && !running) {
      [self setState:AS_DONE];
    }
  }
}

/**
 * @brief Closes the read stream and frees all queued data
 */
- (void)closeReadStream {
  if (waitingOnBuffer) waitingOnBuffer = false;
  queued_packet_t *cur = queued_head;
  while (cur != NULL) {
    queued_packet_t *tmp = cur->next;
    free(cur);
    cur = tmp;
  }
  queued_head = queued_tail = NULL;

  if (stream) {
    CFReadStreamClose(stream);
    CFRelease(stream);
    stream = nil;
  }
}

/**
 * @brief Closes the file stream
 */
- (void)closeFileStream {
  OSStatus osErr = AudioFileStreamClose(audioFileStream);
  assert(!osErr);
  audioFileStream = nil;
}

@end
