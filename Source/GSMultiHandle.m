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

/*
 * Read and write libdispatch sources for a specific socket.
 *
 * A simple helper that combines two sources -- both being optional.
 *
 * This info is stored into the socket using `curl_multi_assign()`.
 *
 */

@interface GSMultiHandleSocketContext : NSObject

- (instancetype) initWithSocket: (curl_socket_t) socket
                 readReadyBlock: (dispatch_block_t) readReadyBlock
                writeReadyBlock: (dispatch_block_t) writeReadyBlock
                          queue: (dispatch_queue_t) queue;

- (void) setReadable: (BOOL)readable
         andWritable: (BOOL)writable;

@end

@interface GSMultiHandle ()

- (void) readMessages;
- (void) completedTransferForEasyHandle: (CURL*)rawEasyHandle 
                               easyCode: (CURLcode)easyCode;
- (int) socketCallback: (CURL *)easy
                socket: (curl_socket_t)socket
                  what: (int)what
               socketp: (void *)socketp;

- (int) timerCallback: (CURLM *)multi
           timeout_ms: (long)timeout_ms;

@end


static void handleEasyCode(int code)
{
    if (CURLE_OK != code) {
        NSString *reason = [NSString stringWithFormat: @"An error occurred, CURLcode is %d", code];
        NSException *e = [NSException exceptionWithName: @"libcurl.easy" 
                                                 reason: reason 
                                               userInfo: nil];
        [e raise];
    }
}

static void handleMultiCode(int code)
{
    if (CURLM_OK != code) {
        NSString *reason = [NSString stringWithFormat: @"An error occurred, CURLcode is %d",  code];
        NSException *e = [NSException exceptionWithName: @"libcurl.multi" 
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
    GSMultiHandle *handle = (GSMultiHandle*)clientp;
   
    return [handle timerCallback:multi
                      timeout_ms:timeout_ms];
}

@implementation GSMultiHandle
{
    CURLM  *_rawHandle;
    NSMutableArray    *_easyHandles;
    dispatch_queue_t _queue;
    GSTimeoutSource   *_timeoutSource;
    int _runningHandlesCount;
}

- (CURLM *) rawHandle
{
  return _rawHandle;
}

- (instancetype) initWithConfiguration: (NSURLSessionConfiguration *)configuration 
                             workQueue: (dispatch_queue_t)workQueue
{
    if ((self = [super init])) {
        _rawHandle = curl_multi_init();
        _easyHandles = [[NSMutableArray alloc] init];
#if HAVE_DISPATCH_QUEUE_CREATE_WITH_TARGET
        _queue = dispatch_queue_create_with_target("GSMultiHandle.isolation", DISPATCH_QUEUE_SERIAL, workQueue);
#else
        _queue = dispatch_queue_create("GSMultiHandle.isolation", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue, workQueue);
#endif
      
        handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_SOCKETDATA, (void *)self));
        handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_SOCKETFUNCTION, curl_socket_function));

        handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_TIMERDATA, (__bridge void *)self));
        handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_TIMERFUNCTION, curl_timer_function));

        handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_MAX_HOST_CONNECTIONS, [configuration HTTPMaximumConnectionsPerHost])); 
        handleEasyCode(curl_multi_setopt(_rawHandle, CURLMOPT_PIPELINING, [configuration HTTPShouldUsePipelining] ? CURLPIPE_MULTIPLEX : CURLPIPE_NOTHING)); 
    }
    
    return self;
}

- (void) dealloc
{
    NSEnumerator   *e;
    GSEasyHandle   *handle;

    if (_timeoutSource) {
        [_timeoutSource cancel];
        DESTROY(_timeoutSource);
    }

    e = [_easyHandles objectEnumerator];

    while (nil != (handle = [e nextObject])) {
        curl_multi_remove_handle([handle rawHandle], _rawHandle);
    }

    DESTROY(_easyHandles);

    curl_multi_cleanup(_rawHandle);

    dispatch_release(_queue);
    _queue = nil;

    [super dealloc];
}


- (void) addHandle: (GSEasyHandle*)easyHandle
{
    if ([_easyHandles containsObject:easyHandle]) {
    }

    [_easyHandles addObject: easyHandle];
    handleMultiCode(curl_multi_add_handle(_rawHandle, [easyHandle rawHandle]));
}

- (void) removeHandle: (GSEasyHandle*)easyHandle
{
    NSEnumerator  *e;
    int           idx = 0;
    BOOL          found = NO;
    GSEasyHandle  *h;

    e = [_easyHandles objectEnumerator];

    while (nil != (h = [e nextObject])) {
        if ([h rawHandle] == [easyHandle rawHandle]) {
          found = YES;
          break;
        }
        
        idx++;
    }

  NSAssert(found, @"Handle not in list.");

  handleMultiCode(curl_multi_remove_handle(_rawHandle, [easyHandle rawHandle]));
  [_easyHandles removeObjectAtIndex: idx];
}

/// Check the status of all individual transfers.
///
/// libcurl refers to this as “read multi stack informationals”.
/// Check for transfers that completed.
- (void) readMessages
{
    CURLMsg *m;
    int messageCount;

    do {
        m = curl_multi_info_read(_rawHandle, &messageCount);

        if (m && m->msg == CURLMSG_DONE) {
            [self completedTransferForEasyHandle: m->easy_handle easyCode: m->data.result];
        }
    } while (m);

    int c1 = _runningHandlesCount;
    int c2 = [_easyHandles count];

    if (_runningHandlesCount != [_easyHandles count]) {
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
    
    while (nil != (h = [e nextObject])) {
      if ([h rawHandle] == rawEasyHandle) {
          handle = h;
          break;
        }
    }

    NSAssert(nil != handle, @"Transfer completed for easy handle @, but it is not in the list of added handles.");
    
    errCode = [handle urlErrorCodeWithEasyCode: easyCode];
    
    if (0 != errCode) {
        NSString *d = nil;
        
        if ([handle errorBuffer][0] == 0) {
            const char *description = curl_easy_strerror(errCode);
            d = [[NSString alloc] initWithCString: description 
                                         encoding: NSUTF8StringEncoding];
        } else {
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

- (int) socketCallback: (CURL *)easy
                socket: (curl_socket_t)socket
                  what: (int)what
               socketp: (void *)socketp
{
  GSMultiHandleSocketContext *context = (GSMultiHandleSocketContext *)socketp;

  switch(what) {
      case CURL_POLL_IN:
      case CURL_POLL_OUT:
      case CURL_POLL_INOUT:
        if (!context) {
            context = [[GSMultiHandleSocketContext alloc] initWithSocket: socket
                                                          readReadyBlock: ^{
                                                              curl_multi_socket_action(_rawHandle, socket, CURL_CSELECT_IN, &_runningHandlesCount);

                                                              int runningHandlesCount = _runningHandlesCount;

                                                              [self readMessages];
                                                          }
                                                          writeReadyBlock: ^{
                                                              curl_multi_socket_action(_rawHandle, socket, CURL_CSELECT_OUT, &_runningHandlesCount);

                                                              int runningHandlesCount = _runningHandlesCount;

                                                              [self readMessages];
                                                          }
                                                          queue: _queue];
            curl_multi_assign(_rawHandle, socket, (void *)context);
        }

        [context setReadable: (what != CURL_POLL_OUT)
                 andWritable: (what != CURL_POLL_IN)];

        break;
      case CURL_POLL_REMOVE:
        curl_multi_assign(_rawHandle, socket, NULL);
        DESTROY(context);
        break;
      default:
        NSAssert(NO, @"Invalid CURL_POLL value"); 
  }

  return 0;
}

- (int) timerCallback: (CURLM *)multi
           timeout_ms: (long)timeout_ms
{
  // A timeout_ms value of -1 passed to this callback means you should delete 
  // the timer. All other values are valid expire times in number 
  // of milliseconds.
  if (-1 == timeout_ms) {
      [_timeoutSource suspend];
  } else {
      if (!_timeoutSource) {
          _timeoutSource = [[GSTimeoutSource alloc] initWithQueue: _queue
                                                          handler: ^{
                                                            handleMultiCode(curl_multi_socket_action(_rawHandle, CURL_SOCKET_TIMEOUT, 0, &_runningHandlesCount));
    
                                                            [self readMessages];
                                                          }];
      }

      [_timeoutSource setTimeout: timeout_ms];
    }

    return 0;
}

@end

static dispatch_source_t createSocketSourceWithType(dispatch_source_type_t type, curl_socket_t socket, dispatch_queue_t queue, dispatch_block_t handler)
{
    dispatch_source_t source = dispatch_source_create(type, socket, 0, queue);
    dispatch_source_set_event_handler(source, handler);
    dispatch_resume(source);
    
    return source;
}

@implementation GSMultiHandleSocketContext
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
#if 1
    if (_readSource) {
        dispatch_source_cancel(_readSource);
        dispatch_release(_readSource);
        _readSource = NULL;
    }

    if (readable) {
        _readSource = createSocketSourceWithType(DISPATCH_SOURCE_TYPE_READ, _socket, _queue, _readReadyBlock);
    }

    if (_writeSource) {
        dispatch_source_cancel(_writeSource);
        dispatch_release(_writeSource);
        _writeSource = NULL;
    }

    if (writable) {
        _writeSource = createSocketSourceWithType(DISPATCH_SOURCE_TYPE_WRITE, _socket, _queue, _writeReadyBlock);
    }
#else
    if (!readable && _readSource) {
        dispatch_source_cancel(_readSource);
        dispatch_release(_readSource);
        _readSource = NULL;
    } else if (readable && !_readSource) {
        _readSource = createSocketSourceWithType(DISPATCH_SOURCE_TYPE_READ, _socket, _queue, _readReadyBlock);
    }

    if (!writable && _writeSource) {
        dispatch_source_cancel(_writeSource);
        dispatch_release(_writeSource);
        _writeSource = NULL;
    } else if (writable && !_writeSource) {
        _writeSource = createSocketSourceWithType(DISPATCH_SOURCE_TYPE_WRITE, _socket, _queue, _writeReadyBlock);
    }
#endif
}

- (void) dealloc
{
  if (_readSource)  {
      dispatch_source_cancel(_readSource);
      dispatch_release(_readSource);
      _readSource = NULL;
  }

  if (_writeSource)  {
      dispatch_source_cancel(_writeSource);
      dispatch_release(_writeSource);
      _writeSource = NULL;
  }

  DESTROY(_readReadyBlock);
  DESTROY(_writeReadyBlock);

  [super dealloc];
}

@end
