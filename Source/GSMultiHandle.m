#import "GSMultiHandle.h"
#import "GSTimeoutSource.h"
#import "GSEasyHandle.h"

#import "Foundation/NSArray.h"
#import "Foundation/NSDictionary.h"
#import "Foundation/NSError.h"
#import "Foundation/NSException.h"
#import "Foundation/NSURLError.h"
#import "Foundation/NSURLSession.h"
#import "Foundation/NSValue.h"

@interface GSMultiHandle ()

- (void) readAndWriteAvailableDataOnSocket: (curl_socket_t)socket;

- (void) readMessages;

- (void) completedTransferForEasyHandle: (CURL*)rawEasyHandle  
                               easyCode: (CURLcode)easyCode;

- (void) performAction: (int) action
             forSocket: (curl_socket_t) socket;

- (int) socketCallback: (CURL *) easy
                socket: (curl_socket_t) socket
                  what: (int) what
               socketp: (void *)socketp;
 
- (int) timerCallback: (CURLM *)multi 
           timeout_ms: (long)timeout_ms; 

@end

/*
 * Read and write libdispatch sources for a specific socket.
 *
 * A simple helper that combines two sources -- both being optional.
 *
 * This info is stored into the socket using `curl_multi_assign()`.
 *
 * - SeeAlso: GSSocketRegisterAction
 */
@interface GSSocketSources : NSObject

- (instancetype) initWithSocket: (curl_socket_t)socket
                 readReadyBlock: (dispatch_block_t)readReadyBlock
                writeReadyBlock: (dispatch_block_t)writeReadyBlock
                          queue: (dispatch_queue_t)queue;

- (void) setReadable: (BOOL)readable
         andWritable: (BOOL)writable;

@end

static void handleEasyCode(int code)
{
  if (CURLE_OK != code)
    {
      NSString    *reason;
      NSException *e;

      reason = [NSString stringWithFormat: @"An error occurred, CURLcode is %d", 
        code];
      e = [NSException exceptionWithName: @"libcurl.easy" 
                                  reason: reason 
                                userInfo: nil];
      [e raise];
    }
}

static void handleMultiCode(int code)
{
  if (CURLM_OK != code)
    {
      NSString    *reason;
      NSException *e;

      reason = [NSString stringWithFormat: @"An error occurred, CURLcode is %d", code];
      e = [NSException exceptionWithName: @"libcurl.multi" 
                                  reason: reason 
                                userInfo: nil];
      [e raise];
    }
}

static int curl_socket_function(CURL *easy, curl_socket_t socket, int what, void *clientp, void *socketp)
{
  GSMultiHandle *handle = (GSMultiHandle *)clientp;

  return [handle socketCallback: easy
                         socket: socket
                           what: what
                        socketp: socketp];
}

static int curl_timer_function(CURLM *multi, long timeout_ms, void *clientp)
{
    GSMultiHandle *handle = (GSMultiHandle *)clientp; 

    return [handle timerCallback: multi
                      timeout_ms: timeout_ms];
}

@implementation GSMultiHandle
{
  NSMutableArray    *_easyHandles;
  dispatch_queue_t _sourcesQueue;
  dispatch_queue_t  _queue;
  GSTimeoutSource   *_timeoutSource;
  int _runningHandlesCount;
} 

- (CURLM*) rawHandle
{
  return _rawHandle;
}

- (instancetype) initWithConfiguration: (NSURLSessionConfiguration*)conf 
                             workQueue: (dispatch_queue_t)aQueue
{
  if (nil != (self = [super init]))
    {
      _rawHandle = curl_multi_init();
      _easyHandles = [[NSMutableArray alloc] init];
      _sourcesQueue = dispatch_queue_create("GSMultiHandle.sourcesqueue", DISPATCH_QUEUE_SERIAL);
#if HAVE_DISPATCH_QUEUE_CREATE_WITH_TARGET
      _queue = dispatch_queue_create_with_target("GSMultiHandle.isolation",
	DISPATCH_QUEUE_SERIAL, aQueue);
#else
      _queue = dispatch_queue_create("GSMultiHandle.isolation",
	DISPATCH_QUEUE_SERIAL);
      dispatch_set_target_queue(_queue, aQueue);
#endif
      [self setupCallbacks];
      [self configureWithConfiguration: conf];
    }

  return self;
}

- (void) dealloc
{
  NSEnumerator   *e;
  GSEasyHandle   *handle;

  [_timeoutSource cancel];
  DESTROY(_timeoutSource);

  dispatch_release(_sourcesQueue);
  dispatch_release(_queue);

  e = [_easyHandles objectEnumerator];
  while (nil != (handle = [e nextObject]))
    {
      curl_multi_remove_handle([handle rawHandle], _rawHandle);
    }
  DESTROY(_easyHandles);

  curl_multi_cleanup(_rawHandle);

  [super dealloc];
}

- (void) configureWithConfiguration: (NSURLSessionConfiguration*)configuration 
{
  handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_MAX_HOST_CONNECTIONS, [configuration HTTPMaximumConnectionsPerHost])); 
  handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_PIPELINING, [configuration HTTPShouldUsePipelining] ? CURLPIPE_MULTIPLEX : CURLPIPE_NOTHING)); 
}

- (void)setupCallbacks 
{
  handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_SOCKETDATA, (void*)self));
  handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_SOCKETFUNCTION, curl_socket_function));

  handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_TIMERDATA, (__bridge void *)self));
  handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_TIMERFUNCTION, curl_timer_function));
}

- (void) addHandle: (GSEasyHandle*)easyHandle
{
  // If this is the first handle being added, we need to `kick` the
  // underlying multi handle by calling `timeoutTimerFired` as
  // described in
  // <https://curl.haxx.se/libcurl/c/curl_multi_socket_action.html>.
  // That will initiate the registration for timeout timer and socket
  // readiness.
  BOOL needsTimeout = false;
  
  if ([_easyHandles count] == 0)
    {
      needsTimeout = YES;
    }

  [_easyHandles addObject: easyHandle];

  handleMultiCode(curl_multi_add_handle(_rawHandle, [easyHandle rawHandle]));

  if (needsTimeout)
    {
      [self timeoutTimerFired];
    }
}

- (void) removeHandle: (GSEasyHandle*)easyHandle
{
  NSEnumerator  *e;
  int           idx = 0;
  BOOL          found = NO;
  GSEasyHandle  *h;

  e = [_easyHandles objectEnumerator];
  while (nil != (h = [e nextObject]))
    {
      if ([h rawHandle] == [easyHandle rawHandle])
        {
          found = YES;
          break;
        }
      idx++;
    }

  NSAssert(found, @"Handle not in list.");

  handleMultiCode(curl_multi_remove_handle(_rawHandle, [easyHandle rawHandle]));
  [_easyHandles removeObjectAtIndex: idx];
}

- (void) timeoutTimerFired 
{
  [self readAndWriteAvailableDataOnSocket: CURL_SOCKET_TIMEOUT];
}

- (void) readAndWriteAvailableDataOnSocket: (curl_socket_t)socket
{
  int numfds = 0;
  
  do
    {
      handleMultiCode(curl_multi_perform(_rawHandle, &_runningHandlesCount));

      if (_runningHandlesCount)
        {
          handleMultiCode(curl_multi_poll(_rawHandle, NULL, 0, 1000, &numfds));
        }
    }
    while (_runningHandlesCount && numfds);

  handleMultiCode(curl_multi_socket_action(_rawHandle, socket, 0, &_runningHandlesCount));
  
  [self readMessages];
}

/// Check the status of all individual transfers.
///
/// libcurl refers to this as “read multi stack informationals”.
/// Check for transfers that completed.
- (void) readMessages 
{
  while (true) 
    {
      int      count = 0;
      CURLMsg  *msg;
      CURL     *easyHandle;
      int      code;

      msg = curl_multi_info_read(_rawHandle, &count);

      if (NULL == msg || CURLMSG_DONE != msg->msg || !msg->easy_handle) break;
      
      easyHandle = msg->easy_handle;
      code = msg->data.result;
      [self completedTransferForEasyHandle: easyHandle easyCode: code];
    }
}

- (void) completedTransferForEasyHandle: (CURL*)rawEasyHandle 
                               easyCode: (CURLcode)easyCode 
{
  NSEnumerator  *e;
  GSEasyHandle  *h;
  GSEasyHandle  *handle = nil;
  NSError       *err = nil;
  int           errCode;

  e = [_easyHandles objectEnumerator];
  while (nil != (h = [e nextObject]))
    {
      if ([h rawHandle] == rawEasyHandle)
        {
          handle = h;
          break;
        }
    }

  NSAssert(nil != handle, @"Transfer completed for easy handle"
    @", but it is not in the list of added handles.");

  errCode = [handle urlErrorCodeWithEasyCode: easyCode];
  if (0 != errCode)
    {
      NSString *d = nil;

      if ([handle errorBuffer][0] == 0)
        {
          const char *description = curl_easy_strerror(errCode);
          d = [[NSString alloc] initWithCString: description 
                                       encoding: NSUTF8StringEncoding];
        } 
      else 
        {
          d = [[NSString alloc] initWithCString: [handle errorBuffer] 
                                       encoding: NSUTF8StringEncoding];
        }
      err = [NSError errorWithDomain: NSURLErrorDomain 
                                code: errCode 
                            userInfo: @{NSLocalizedDescriptionKey : d, NSUnderlyingErrorKey: [NSNumber numberWithInt:easyCode]}];
      RELEASE(d);
    }

  [handle transferCompletedWithError: err];
}

- (void) performAction: (int)action
             forSocket: (curl_socket_t)socket
{
  dispatch_async(_queue,
    ^{
      curl_multi_socket_action(_rawHandle, socket, action, &_runningHandlesCount);

      [self readMessages];
    });
}

- (int) socketCallback: (CURL *)easy 
                socket: (curl_socket_t)socket 
                  what: (int)what 
               socketp: (void *)socketp 
{ 
  GSSocketSources *sources = (GSSocketSources *)socketp; 
 
  switch(what)
    {
      case CURL_POLL_IN:
      case CURL_POLL_OUT:
      case CURL_POLL_INOUT:
        if (!sources)
          {
            sources = [[GSSocketSources alloc] initWithSocket: socket 
                                                          readReadyBlock: ^{
                                                            [self performAction: CURL_CSELECT_IN forSocket: socket];
                                                          }
                                                          writeReadyBlock: ^{
                                                            [self performAction: CURL_CSELECT_OUT forSocket: socket];
                                                          }
                                                          queue: _sourcesQueue];

            curl_multi_assign(_rawHandle, socket, (void *)sources);
          }

        [sources setReadable: (what != CURL_POLL_OUT)
                 andWritable: (what != CURL_POLL_IN)];

        break;
      case CURL_POLL_REMOVE:
        curl_multi_assign(_rawHandle, socket, NULL);
        DESTROY(sources);
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

- (int) timerCallback: (CURLM *)multi 
           timeout_ms: (long)timeout_ms 
{
  // A timeout_ms value of -1 passed to this callback means you should delete 
  // the timer. All other values are valid expire times in number 
  // of milliseconds.
  if (-1 == timeout_ms)
    {
      [_timeoutSource suspend];
    }
  else 
    {
      if (!_timeoutSource)
        {
          _timeoutSource = [[GSTimeoutSource alloc] initWithQueue: _queue
                                                          handler: ^{
                                                            [self timeoutTimerFired];
                                                          }];
        }

      [_timeoutSource setTimeout: timeout_ms];
    }
}

@end

@implementation GSSocketSources
{
    curl_socket_t _socket;
    dispatch_block_t _readReadyBlock;
    dispatch_block_t _writeReadyBlock;
    dispatch_queue_t _queue;
    dispatch_source_t _readSource;
    dispatch_source_t _writeSource;
}

- (instancetype) initWithSocket: (curl_socket_t)socket
                 readReadyBlock: (dispatch_block_t)readReadyBlock
                writeReadyBlock: (dispatch_block_t)writeReadyBlock
                          queue: (dispatch_queue_t)queue
{
    if ((self = [super init]))
      {
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
      _readSource = NULL;
    }

  if (_writeSource)
    {
      dispatch_release(_writeSource);
      _writeSource = NULL;
    }

  _socket = 0;
  DESTROY(_readReadyBlock);
  DESTROY(_writeReadyBlock);
  _queue = nil;

  [super dealloc];
}

@end
