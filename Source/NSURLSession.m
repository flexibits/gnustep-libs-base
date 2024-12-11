/**
 * NSURLSession.m
 *
 * Copyright (C) 2017-2024 Free Software Foundation, Inc.
 *
 * Written by: Hugo Melder <hugo@algoriddim.com>
 * Date: May 2024
 * Author: Hugo Melder <hugo@algoriddim.com>
 *
 * This file is part of GNUStep-base
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * If you are interested in a warranty or support for this source code,
 * contact Scott Christley <scottc@net-community.com> for more information.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free
 * Software Foundation, Inc., 31 Milk Street #960789 Boston, MA 02196 USA.
 */

#import "NSURLSessionPrivate.h"
#import "NSURLSessionTaskPrivate.h"
#import "Foundation/NSString.h"
#import "Foundation/NSArray.h"
#import "Foundation/NSException.h"
#import "Foundation/NSStream.h"
#import "Foundation/NSUserDefaults.h"
#import "Foundation/NSValue.h"
#import "Foundation/NSBundle.h"
#import "Foundation/NSData.h"

#import "GNUstepBase/NSDebug+GNUstepBase.h"  /* For NSDebugMLLog */
#import "GNUstepBase/NSObject+GNUstepBase.h" /* For -notImplemented */
#import "GSPThread.h"                        /* For nextSessionIdentifier() */
#import "GSDispatch.h"                       /* For dispatch compatibility */

NSString * GS_NSURLSESSION_DEBUG_KEY = @"NSURLSession";

/*
 * Read and write libdispatch sources for a specific socket.
 *
 * A simple helper that combines two sources -- both being optional.
 *
 * This info is stored into the socket using `curl_multi_assign()`.
 *
 */

@interface _SocketSources : NSObject

- (instancetype) initWithSocket: (curl_socket_t) socket
                 readReadyBlock: (dispatch_block_t) readReadyBlock
                writeReadyBlock: (dispatch_block_t) writeReadyBlock
                          queue: (dispatch_queue_t) queue;

- (void) setReadable: (BOOL)readable
         andWritable: (BOOL)writable;

@end

/* We need a globably unique label for the NSURLSession workQueues.
 */
static NSUInteger nextSessionIdentifier()
{
  static gs_mutex_t lock = GS_MUTEX_INIT_STATIC;
  static NSUInteger sessionCounter = 0;

  GS_MUTEX_LOCK(lock);
  sessionCounter += 1;
  GS_MUTEX_UNLOCK(lock);

  return sessionCounter;
}

#pragma mark - libcurl callbacks

/* CURLMOPT_SOCKETFUNCTION: Callback to receive socket monitoring requests */
static int curl_socket_function(CURL *easy, curl_socket_t socket, int what, void *clientp, void *socketp) 
{
  NSURLSession *session = (NSURLSession *)clientp;

    NSDebugLLog(
      GS_NSURLSESSION_DEBUG_KEY,
      @"Socket Callback for Session %@: easy=%p socket=%llu what=%d socketp=%p",
      session,
      easy,
      socket,
      what,
      socketp);

  return [session _socketCallback: easy
                           socket: socket
                             what: what
                          socketp: socketp];
}

/* CURLMOPT_TIMERFUNCTION: Callback to receive timer requests */
static int curl_timer_function(CURLM *multi, long timeout_ms, void *clientp)
{
    NSURLSession *session = (NSURLSession *)clientp;

    NSDebugLLog(
      GS_NSURLSESSION_DEBUG_KEY,
      @"Timer Callback for Session %@: multi=%p timeout_ms=%ld",
      session,
      multi,
      timeout_ms);

    return [session _timerCallback:multi
                        timeout_ms:timeout_ms];
}


#pragma mark - NSURLSession Implementation

@implementation NSURLSession
{
  /* The libcurl multi handle associated with this session.
   * We use the curl_multi_socket_action API as we utilise our
   * own event-handling system based on libdispatch.
   *
   * Event creation and deletion is driven by the various callbacks
   * registered during initialisation of the multi handle.
   */
  CURLM * _multiHandle;
  /* A serial work queue for timer and socket sources
   * created on libcurl's behalf.
   */
  dispatch_queue_t _workQueue;

  /* A queue specifically to process socket sources
   * See further discussion in https://github.com/swiftlang/swift-corelibs-libdispatch/issues/609
   */
  dispatch_queue_t _sourcesQueue;

  /* This timer is driven by libcurl and used by
   * libcurl's multi API.
   *
   * The handler notifies libcurl using curl_multi_socket_action
   * and checks for completed requests by calling
   * _checkForCompletion.
   *
   * See https://curl.se/libcurl/c/CURLMOPT_TIMERFUNCTION.html
   * and https://curl.se/libcurl/c/curl_multi_socket_action.html
   * respectively.
   */
  dispatch_source_t _timer;

  /* The timer may be suspended upon request by libcurl.
   */
  BOOL _isTimerSuspended;

  /* Only set when session originates from +[NSURLSession sharedSession] */
  BOOL _isSharedSession;
  BOOL _invalidated;

  /*
   * Number of currently running handles.
   * This number is updated by curl_multi_socket_action
   * in the socket source handlers.
   */
  int _stillRunning;

  /* List of active tasks. Access is synchronised via the _workQueue.
   */
  NSMutableArray<NSURLSessionTask *> * _tasks;

  /* PEM encoded blob of one or more certificates.
   *
   * See GSCACertificateFilePath in NSUserDefaults.h
   */
  NSData * _certificateBlob;
  /* Path to PEM encoded CA certificate file. */
  NSString * _certificatePath;

  /* The task identifier for the next task
   */
  _Atomic(NSInteger) _taskIdentifier;
  /* Lock for _taskIdentifier and _tasks
   */
  gs_mutex_t _taskLock;
}

+ (NSURLSession *) sharedSession
{
  static NSURLSession * session = nil;
  static dispatch_once_t predicate;

  dispatch_once(
    &predicate,
    ^{
      NSURLSessionConfiguration * configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
      session = [[NSURLSession alloc] initWithConfiguration: configuration
                                                   delegate: nil
                                              delegateQueue: nil];
      [session _setSharedSession: YES];
    });

  return session;
}

+ (NSURLSession *) sessionWithConfiguration: (NSURLSessionConfiguration *)configuration
{
  NSURLSession * session;

  session = [[NSURLSession alloc] initWithConfiguration: configuration
                                               delegate: nil
                                          delegateQueue: nil];

  return AUTORELEASE(session);
}

+ (NSURLSession *) sessionWithConfiguration: (NSURLSessionConfiguration *)configuration
                                   delegate: (id<NSURLSessionDelegate>)delegate
                              delegateQueue: (NSOperationQueue *)queue
{
  NSURLSession * session;

  session = [[NSURLSession alloc] initWithConfiguration: configuration
                                               delegate: delegate
                                          delegateQueue: queue];

  return AUTORELEASE(session);
}

- (instancetype) initWithConfiguration: (NSURLSessionConfiguration *)configuration
                              delegate: (id<NSURLSessionDelegate>)delegate
                         delegateQueue: (NSOperationQueue *)queue
{
  self = [super init];

  if (self)
    {
      NSString * queueLabel;
      NSString * caPath;
      NSUInteger sessionIdentifier;

      sessionIdentifier = nextSessionIdentifier();
      ASSIGN(_delegate, delegate);
      ASSIGNCOPY(_configuration, configuration);

      _tasks = [[NSMutableArray alloc] init];
      GS_MUTEX_INIT(_taskLock);

      /* label is strdup'ed by libdispatch */
      queueLabel = [[NSString alloc] initWithFormat: @"org.gnustep.NSURLSession.WorkQueue%lld", sessionIdentifier];
      _workQueue = dispatch_queue_create([queueLabel UTF8String], DISPATCH_QUEUE_SERIAL);
      DESTROY(queueLabel);

      if (!_workQueue)
        {
          return nil;
        }

      queueLabel = [[NSString alloc] initWithFormat: @"org.gnustep.NSURLSession.SourcesQueue%lld", sessionIdentifier];
      _sourcesQueue = dispatch_queue_create([queueLabel UTF8String], DISPATCH_QUEUE_SERIAL);
      DESTROY(queueLabel);

      if (!_sourcesQueue)
        {
          return nil;
        }

      _isTimerSuspended = YES;
      _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _workQueue);

      if (!_timer)
        {
          return nil;
        }

      dispatch_source_set_cancel_handler(
        _timer,
        ^{
            dispatch_release(_timer);
        });

      // Called after timeout set by libcurl is reached
      dispatch_source_set_event_handler(
        _timer,
        ^{
          // TODO: Check for return values
          curl_multi_socket_action(_multiHandle, CURL_SOCKET_TIMEOUT, 0, &_stillRunning);

          [self _checkForCompletion];
        });

      /* Use the provided delegateQueue if available */
      if (queue)
        {
          ASSIGN(_delegateQueue, queue);
        }
      else
        {
          /* This (serial) NSOperationQueue is only used for dispatching
           * delegate callbacks and is orthogonal to the workQueue.
           */
          _delegateQueue = [[NSOperationQueue alloc] init];
          [_delegateQueue setMaxConcurrentOperationCount: 1];
        }

      /* libcurl Configuration */
      curl_global_init(CURL_GLOBAL_SSL);

      _multiHandle = curl_multi_init();

      // Set up CURL multi callbacks
      curl_multi_setopt(_multiHandle, CURLMOPT_SOCKETFUNCTION, curl_socket_function);
      curl_multi_setopt(_multiHandle, CURLMOPT_SOCKETDATA, self);
      curl_multi_setopt(_multiHandle, CURLMOPT_TIMERFUNCTION, curl_timer_function);
      curl_multi_setopt(_multiHandle, CURLMOPT_TIMERDATA, self);

      // Configure Multi Handle
      curl_multi_setopt(
        _multiHandle,
        CURLMOPT_MAX_HOST_CONNECTIONS,
        [_configuration HTTPMaximumConnectionsPerHost]);

      /* Check if GSCACertificateFilePath is set */
      caPath = [[NSUserDefaults standardUserDefaults] objectForKey: GSCACertificateFilePath];

      if (caPath)
        {
          NSDebugMLLog(
            GS_NSURLSESSION_DEBUG_KEY,
            @"Found a GSCACertificateFilePath entry in UserDefaults");

          _certificateBlob = [[NSData alloc] initWithContentsOfFile: caPath];

          if (!_certificateBlob)
            {
              NSDebugMLLog(
                GS_NSURLSESSION_DEBUG_KEY,
                @"Could not open file at GSCACertificateFilePath=%@",
                caPath);
            }
          else
            {
              ASSIGN(_certificatePath, caPath);
            }
        }
    }

  return self;
} /* initWithConfiguration */

#pragma mark - Private Methods

- (NSData *) _certificateBlob
{
  return _certificateBlob;
}

- (NSString *) _certificatePath
{
  return _certificatePath;
}

- (void) _setSharedSession: (BOOL)flag
{
  _isSharedSession = flag;
}

- (NSInteger) _nextTaskIdentifier
{
  NSInteger identifier;

  GS_MUTEX_LOCK(_taskLock);
  identifier = _taskIdentifier;
  _taskIdentifier += 1;
  GS_MUTEX_UNLOCK(_taskLock);

  return identifier;
}

- (void) _resumeTask: (NSURLSessionTask *)task
{
  dispatch_async(
    _workQueue,
    ^{
      CURLMcode code;
      CURLM * multiHandle = _multiHandle;

      code = curl_multi_add_handle(multiHandle, [task _easyHandle]);

      NSDebugMLLog(
        GS_NSURLSESSION_DEBUG_KEY,
        @"Added task=%@ easy=%p to multi=%p with return value %d",
        task,
        [task _easyHandle],
        multiHandle,
        code);
    });
}

- (void) _addHandle: (CURL *)easy
{
  curl_multi_add_handle(_multiHandle, easy);
}
- (void) _removeHandle: (CURL *)easy
{
  curl_multi_remove_handle(_multiHandle, easy);
}

- (int) _timerCallback: (CURLM *)multi
            timeout_ms: (long)timeout_ms
{
  /* if timeout_ms is -1, just delete the timer
   *
   * For all other values of timeout_ms, set or *update* the timer
   */
  if (timeout_ms == -1)
    {
      if (!_isTimerSuspended)
        {
          _isTimerSuspended = YES;
          dispatch_suspend(_timer);
        }
    }
  else
    {
        dispatch_source_set_timer(
          _timer,
          dispatch_time(
            DISPATCH_TIME_NOW,
            timeout_ms * NSEC_PER_MSEC),
          DISPATCH_TIME_FOREVER,              // don't repeat
          timeout_ms * 0.05 * NSEC_PER_MSEC); // 5% leeway

        if (_isTimerSuspended)
          {
            _isTimerSuspended = NO;
            dispatch_resume(_timer);
          }
    }

  return 0;
}

- (int) _socketCallback: (CURL *)easy
                 socket: (curl_socket_t)socket
                   what: (int)what
                socketp: (void *)socketp
{
  _SocketSources *socketSources = (_SocketSources *)socketp;

  switch (what)
    {
      case CURL_POLL_IN:
      case CURL_POLL_OUT:
      case CURL_POLL_INOUT:
        if (!socketSources)
          {
            NSDebugMLLog(GS_NSURLSESSION_DEBUG_KEY, @"Add Socket: %llu easy: %p what: %d", socket, easy, what);

            socketSources = [[_SocketSources alloc] initWithSocket: socket
                                                    readReadyBlock: ^{
                                                        [self _performAction: CURL_CSELECT_IN forSocket: socket];
                                                    }
                                                    writeReadyBlock: ^{
                                                        [self _performAction: CURL_CSELECT_OUT forSocket: socket];
                                                    }
                                                              queue: _sourcesQueue];
            if (!socketSources)
              {
                NSDebugMLLog(GS_NSURLSESSION_DEBUG_KEY, @"Failed to initialize SocketSources!");

                return -1;
              }

            curl_multi_assign(_multiHandle, socket, (void *)socketSources);
          }

        [socketSources setReadable: (what != CURL_POLL_OUT)
                       andWritable: (what != CURL_POLL_IN)];

        break;
      case CURL_POLL_REMOVE:
        curl_multi_assign(_multiHandle, socket, NULL);
        DESTROY(socketSources);
        break;
      default:
        {
          NSDictionary *userInfo = @{ @"NSURLSession.CURL_POLL": @(what) };
          NSException *exception = [NSException exceptionWithName: @"NSURLSession.libcurl"
                                                           reason: @"Invalid CURL_POLL value"
                                                         userInfo: userInfo];

          [exception raise];

          return -1;
        }
    }

  return 0;
}

- (dispatch_queue_t) _workQueue
{
  return _workQueue;
}

- (void) _performAction: (int)action
              forSocket: (curl_socket_t)sockfd
{
  dispatch_async(
    _workQueue,
    ^{
      curl_multi_socket_action(_multiHandle, sockfd, action, &_stillRunning);

      [self _checkForCompletion];
    });
}

- (void) _checkForCompletion
{
  CURLMsg * msg;
  int msgs_left;
  CURL * easyHandle;
  CURLcode res;
  char * eff_url = NULL;
  NSURLSessionTask * task = nil;

  /* Ask the multi handle if there are any messages from the individual
   * transfers.
   *
   * Remove the associated easy handle and release the task if the transfer is
   * done. This completes the life-cycle of a task added to NSURLSession.
   */
  while ((msg = curl_multi_info_read(_multiHandle, &msgs_left)))
    {
      if (msg->msg == CURLMSG_DONE)
        {
          CURLcode rc;
          easyHandle = msg->easy_handle;
          res = msg->data.result;

          /* Get the NSURLSessionTask instance */
          rc = curl_easy_getinfo(easyHandle, CURLINFO_PRIVATE, &task);

          if (CURLE_OK != rc)
            {
              NSDebugMLLog(
                GS_NSURLSESSION_DEBUG_KEY,
                @"Failed to retrieve task from easy handle %p using "
                @"CURLINFO_PRIVATE",
                easyHandle);
            }

          rc = curl_easy_getinfo(easyHandle, CURLINFO_EFFECTIVE_URL, &eff_url);

          if (CURLE_OK != rc)
            {
              NSDebugMLLog(
                GS_NSURLSESSION_DEBUG_KEY,
                @"Failed to retrieve effective URL from easy handle %p using "
                @"CURLINFO_PRIVATE",
                easyHandle);
            }

          NSDebugMLLog(
            GS_NSURLSESSION_DEBUG_KEY,
            @"Transfer finished for Task %@ with effective url %s "
            @"and CURLcode: %s",
            task,
            eff_url,
            curl_easy_strerror(res));

          curl_multi_remove_handle(_multiHandle, easyHandle);

          /* This session might be released in _transferFinishedWithCode. Better
           * retain it first. */
          RETAIN(self);

          RETAIN(task);
          [_tasks removeObject: task];
          [task _transferFinishedWithCode: res];
          RELEASE(task);

          /* Send URLSession: didBecomeInvalidWithError: to delegate if this
           * session was invalidated */
          if (_invalidated && [_tasks count] == 0 && [_delegate respondsToSelector: @selector(URLSession:didBecomeInvalidWithError:)])
            {
              [_delegateQueue addOperationWithBlock:^{
                 /* We only support explicit Invalidation for now. Error is set
                  * to nil in this case. */
                 [_delegate URLSession: self didBecomeInvalidWithError: nil];
              }];
            }

          RELEASE(self);
        }
    }
} /* _checkForCompletion */

/* Adds task to _tasks and updates the delegate */
- (void) _didCreateTask: (NSURLSessionTask *)task
{
  dispatch_async(
    _workQueue,
    ^{
      [_tasks addObject: task];
    });

  if ([_delegate respondsToSelector: @selector(URLSession:didCreateTask:)])
    {
      [_delegateQueue addOperationWithBlock:^{
         [(id<NSURLSessionTaskDelegate>) _delegate URLSession: self
                                                didCreateTask: task];
      }];
    }
}

#pragma mark - Public API

- (void) finishTasksAndInvalidate
{
  if (_isSharedSession)
    {
      return;
    }

  dispatch_async(
    _workQueue,
    ^{
      _invalidated = YES;
    });
}

- (void) invalidateAndCancel
{
  if (_isSharedSession)
    {
      return;
    }

  dispatch_async(
    _workQueue,
    ^{
      _invalidated = YES;

      /* Cancel all tasks */
      for (NSURLSessionTask * task in _tasks)
        {
          [task cancel];
        }
    });
}

- (NSURLSessionDataTask *) dataTaskWithRequest: (NSURLRequest *)request
{
  NSURLSessionDataTask * task;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  task = [[NSURLSessionDataTask alloc] initWithSession: self
                                               request: request
                                        taskIdentifier: identifier];

  /* We use the session delegate by default. NSURLSessionTaskDelegate
   * is a purely optional protocol.
   */
  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];

  [task _setProperties: GSURLSessionUpdatesDelegate];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
}

- (NSURLSessionDataTask *) dataTaskWithURL: (NSURL *)url
{
  NSURLRequest * request;

  request = [NSURLRequest requestWithURL: url];
  return [self dataTaskWithRequest: request];
}

- (NSURLSessionUploadTask *) uploadTaskWithRequest: (NSURLRequest *)request
                                          fromFile: (NSURL *)fileURL
{
  NSURLSessionUploadTask * task;
  NSInputStream * stream;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  stream = [NSInputStream inputStreamWithURL: fileURL];
  task = [[NSURLSessionUploadTask alloc] initWithSession: self
                                                 request: request
                                          taskIdentifier: identifier];

  /* We use the session delegate by default. NSURLSessionTaskDelegate
   * is a purely optional protocol.
   */
  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];
  [task _setProperties: GSURLSessionUpdatesDelegate | GSURLSessionHasInputStream];
  [task _setBodyStream: stream];
  [task _enableUploadWithSize: 0];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
} /* uploadTaskWithRequest */

- (NSURLSessionUploadTask *) uploadTaskWithRequest: (NSURLRequest *)request
                                          fromData: (NSData *)bodyData
{
  NSURLSessionUploadTask * task;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  task = [[NSURLSessionUploadTask alloc] initWithSession: self
                                                 request: request
                                          taskIdentifier: identifier];

  /* We use the session delegate by default. NSURLSessionTaskDelegate
   * is a purely optional protocol.
   */
  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];
  [task _setProperties: GSURLSessionUpdatesDelegate];
  [task _enableUploadWithData: bodyData];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
}

- (NSURLSessionUploadTask *) uploadTaskWithStreamedRequest:
  (NSURLRequest *)request
{
  NSURLSessionUploadTask * task;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  task = [[NSURLSessionUploadTask alloc] initWithSession: self
                                                 request: request
                                          taskIdentifier: identifier];

  /* We use the session delegate by default. NSURLSessionTaskDelegate
   * is a purely optional protocol.
   */
  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];
  [task _setProperties: GSURLSessionUpdatesDelegate | GSURLSessionHasInputStream];
  [task _enableUploadWithSize: 0];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
}

- (NSURLSessionDownloadTask *) downloadTaskWithRequest: (NSURLRequest *)request
{
  NSURLSessionDownloadTask * task;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  task = [[NSURLSessionDownloadTask alloc] initWithSession: self
                                                   request: request
                                            taskIdentifier: identifier];

  /* We use the session delegate by default. NSURLSessionTaskDelegate
   * is a purely optional protocol.
   */
  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];
  [task _setProperties: GSURLSessionWritesDataToFile | GSURLSessionUpdatesDelegate];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
}

- (NSURLSessionDownloadTask *) downloadTaskWithURL: (NSURL *)url
{
  NSURLRequest * request;

  request = [NSURLRequest requestWithURL: url];
  return [self downloadTaskWithRequest: request];
}

- (NSURLSessionDownloadTask *) downloadTaskWithResumeData: (NSData *)resumeData
{
  return [self notImplemented: _cmd];
}

- (void) getTasksWithCompletionHandler: (void (^)(NSArray<NSURLSessionDataTask *> * dataTasks, NSArray<NSURLSessionUploadTask *> * uploadTasks, NSArray<NSURLSessionDownloadTask *> * downloadTasks)) completionHandler
{
  dispatch_async(
    _workQueue,
    ^{
      NSMutableArray<NSURLSessionDataTask *> * dataTasks;
      NSMutableArray<NSURLSessionUploadTask *> * uploadTasks;
      NSMutableArray<NSURLSessionDownloadTask *> * downloadTasks;
      NSInteger numberOfTasks;

      Class dataTaskClass;
      Class uploadTaskClass;
      Class downloadTaskClass;

      numberOfTasks = [_tasks count];
      dataTasks = [NSMutableArray arrayWithCapacity: numberOfTasks / 2];
      uploadTasks = [NSMutableArray arrayWithCapacity: numberOfTasks / 2];
      downloadTasks = [NSMutableArray arrayWithCapacity: numberOfTasks / 2];

      dataTaskClass = [NSURLSessionDataTask class];
      uploadTaskClass = [NSURLSessionUploadTask class];
      downloadTaskClass = [NSURLSessionDownloadTask class];

      for (NSURLSessionTask * task in _tasks)
        {
          if ([task isKindOfClass: dataTaskClass])
            {
              [dataTasks addObject: (NSURLSessionDataTask *)task];
            }
          else if ([task isKindOfClass: uploadTaskClass])
            {
              [uploadTasks addObject: (NSURLSessionUploadTask *)task];
            }
          else if ([task isKindOfClass: downloadTaskClass])
            {
              [downloadTasks addObject: (NSURLSessionDownloadTask *)task];
            }
        }

      completionHandler(dataTasks, uploadTasks, downloadTasks);
    });
} /* getTasksWithCompletionHandler */

- (void) getAllTasksWithCompletionHandler:(void (^)(NSArray<__kindof NSURLSessionTask *> * tasks))completionHandler
{
  dispatch_async(
    _workQueue,
    ^{
      completionHandler(_tasks);
    });
}

#pragma mark - Getter and Setter

- (NSOperationQueue *) delegateQueue
{
  return _delegateQueue;
}

- (id<NSURLSessionDelegate>) delegate
{
  return _delegate;
}

- (NSURLSessionConfiguration *) configuration
{
  return AUTORELEASE([_configuration copy]);
}

- (NSString *) sessionDescription
{
  return _sessionDescription;
}

- (void) setSessionDescription: (NSString *)sessionDescription
{
  ASSIGNCOPY(_sessionDescription, sessionDescription);
}

- (void) dealloc
{
  RELEASE(_delegateQueue);
  RELEASE(_delegate);
  RELEASE(_configuration);
  RELEASE(_tasks);
  RELEASE(_certificateBlob);
  RELEASE(_certificatePath);

  curl_multi_cleanup(_multiHandle);

#if defined(HAVE_DISPATCH_CANCEL)
  dispatch_cancel(_timer);
#else
  dispatch_source_cancel(_timer);
#endif
  dispatch_release(_workQueue);
  dispatch_release(_sourcesQueue);

  [super dealloc];
}

@end

@implementation
NSURLSession (NSURLSessionAsynchronousConvenience)

- (NSURLSessionDataTask *) dataTaskWithRequest: (NSURLRequest *)request
                             completionHandler: (GSNSURLSessionDataCompletionHandler)completionHandler
{
  NSURLSessionDataTask * task;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  task = [[NSURLSessionDataTask alloc] initWithSession: self
                                               request: request
                                        taskIdentifier: identifier];
  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];
  [task _setCompletionHandler: completionHandler];
  [task _enableAutomaticRedirects: YES];
  [task _setProperties: GSURLSessionStoresDataInMemory | GSURLSessionHasCompletionHandler];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
}

- (NSURLSessionDataTask *) dataTaskWithURL: (NSURL *)url
                         completionHandler: (GSNSURLSessionDataCompletionHandler)completionHandler
{
  NSURLRequest * request = [NSURLRequest requestWithURL: url];

  return [self dataTaskWithRequest: request completionHandler: completionHandler];
}

- (NSURLSessionUploadTask *) uploadTaskWithRequest: (NSURLRequest *)request
                                          fromFile: (NSURL *)fileURL
                                 completionHandler: (GSNSURLSessionDataCompletionHandler)completionHandler
{
  NSURLSessionUploadTask * task;
  NSInputStream * stream;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  stream = [NSInputStream inputStreamWithURL: fileURL];
  task = [[NSURLSessionUploadTask alloc] initWithSession: self
                                                 request: request
                                          taskIdentifier: identifier];
  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];

  [task _setProperties: GSURLSessionStoresDataInMemory | GSURLSessionHasInputStream |
   GSURLSessionHasCompletionHandler];
  [task _setCompletionHandler: completionHandler];
  [task _enableAutomaticRedirects: YES];
  [task _setBodyStream: stream];
  [task _enableUploadWithSize: 0];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
} /* uploadTaskWithRequest */

- (NSURLSessionUploadTask *) uploadTaskWithRequest: (NSURLRequest *)request
                                          fromData: (NSData *)bodyData
                                 completionHandler: (GSNSURLSessionDataCompletionHandler)completionHandler
{
  NSURLSessionUploadTask * task;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  task = [[NSURLSessionUploadTask alloc] initWithSession: self
                                                 request: request
                                          taskIdentifier: identifier];
  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];

  [task _setProperties: GSURLSessionStoresDataInMemory | GSURLSessionHasCompletionHandler];
  [task _setCompletionHandler: completionHandler];
  [task _enableAutomaticRedirects: YES];
  [task _enableUploadWithData: bodyData];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
}

- (NSURLSessionDownloadTask *) downloadTaskWithRequest: (NSURLRequest *)request
                                     completionHandler: (GSNSURLSessionDownloadCompletionHandler) completionHandler
{
  NSURLSessionDownloadTask * task;
  NSInteger identifier;

  identifier = [self _nextTaskIdentifier];
  task = [[NSURLSessionDownloadTask alloc] initWithSession: self
                                                   request: request
                                            taskIdentifier: identifier];

  [task setDelegate: (id<NSURLSessionTaskDelegate>)_delegate];

  [task _setProperties: GSURLSessionWritesDataToFile | GSURLSessionHasCompletionHandler];
  [task _enableAutomaticRedirects: YES];
  [task _setCompletionHandler: completionHandler];

  [self _didCreateTask: task];

  return AUTORELEASE(task);
}

- (NSURLSessionDownloadTask *) downloadTaskWithURL: (NSURL *)url
                                 completionHandler: (GSNSURLSessionDownloadCompletionHandler)completionHandler
{
  NSURLRequest * request = [NSURLRequest requestWithURL: url];

  return [self downloadTaskWithRequest: request
                     completionHandler: completionHandler];
}

- (NSURLSessionDownloadTask *) downloadTaskWithResumeData: (NSData *)resumeData
                                        completionHandler: (GSNSURLSessionDownloadCompletionHandler)completionHandler
{
  return [self notImplemented: _cmd];
}

@end

@implementation _SocketSources
{
    curl_socket_t _socket;
    dispatch_block_t _readReadyBlock;
    dispatch_block_t _writeReadyBlock;
    dispatch_queue_t _queue;
    dispatch_source_t _readSource;
    dispatch_source_t _writeSource;
}

- (instancetype) initWithSocket: (curl_socket_t) socket
                 readReadyBlock: (dispatch_block_t) readReadyBlock
                writeReadyBlock: (dispatch_block_t) writeReadyBlock
                          queue: (dispatch_queue_t) queue
{
    if ((self = [super init])) {
        _socket = socket;
        _readReadyBlock = [readReadyBlock copy];
        _writeReadyBlock = [writeReadyBlock copy];
        _queue = queue;
    }

    return self;
}

- (void) setReadable: (BOOL)readable
         andWritable: (BOOL)writable
{
    if (_readSource && !readable)
      {
        dispatch_source_cancel(_readSource);
        dispatch_release(_readSource);
        _readSource = NULL;
      }
    else if (readable && !_readSource)
      {
        _readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _socket, 0, _queue);
        dispatch_source_set_event_handler(_readSource, _readReadyBlock);
        dispatch_resume(_readSource);
      }

    if (_writeSource && !writable)
      {
        dispatch_source_cancel(_writeSource);
        dispatch_release(_writeSource);
        _writeSource = NULL;
      }
    else if (writable && !_writeSource)
      {
        _writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, _socket, 0, _queue);
        dispatch_source_set_event_handler(_writeSource, _writeReadyBlock);
        dispatch_resume(_writeSource);
      }
}

- (void) dealloc
{
  dispatch_group_t group;

  NSDebugMLLog(GS_NSURLSESSION_DEBUG_KEY, @"Remove socket with _Sources: %@", self);

  group = dispatch_group_create();

  if (_readSource)
    {
      dispatch_group_enter(group);
      dispatch_source_set_cancel_handler(
        _readSource,
        ^{
            dispatch_group_leave(group);
        });
      dispatch_source_cancel(_readSource);
    }

  if (_writeSource)
    {
      dispatch_group_enter(group);
      dispatch_source_set_cancel_handler(
        _writeSource,
        ^{
            dispatch_group_leave(group);
        });
      dispatch_source_cancel(_writeSource);
    }

  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
  dispatch_release(group);
  group = nil;

  if (_readSource)
    {
      dispatch_release(_readSource);
      _readSource = nil;
    }

  if (_writeSource)
    {
      dispatch_release(_writeSource);
      _writeSource = nil;
    }

  _socket = 0;
  DESTROY(_readReadyBlock);
  DESTROY(_writeReadyBlock);
  _queue = nil;

  [super dealloc];
}

@end
