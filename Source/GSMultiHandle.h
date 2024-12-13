#ifndef	INCLUDED_GSMULTIHANDLE_H
#define	INCLUDED_GSMULTIHANDLE_H

#import "common.h"
#import <curl/curl.h>
#import "GSDispatch.h"

@class NSURLSessionConfiguration;
@class GSEasyHandle;

/*
 * Minimal wrapper around curl multi interface
 * (https://curl.haxx.se/libcurl/c/libcurl-multi.html).
 *
 * The the *multi handle* manages the sockets for easy handles
 * (`GSEasyHandle`), and this implementation uses
 * libdispatch to listen for sockets being read / write ready.
 *
 * Using `dispatch_source_t` allows this implementation to be
 * non-blocking and all code to run on the same thread 
 * thus keeping is simple.
 *
 * - SeeAlso: GSEasyHandle
 */
@interface GSMultiHandle : NSObject
{
  CURLM  *_rawHandle;
}

- (CURLM*) rawHandle;
- (instancetype) initWithConfiguration: (NSURLSessionConfiguration*)configuration 
                             workQueue: (dispatch_queue_t)workQueque;
- (void) addHandle: (GSEasyHandle*)easyHandle;
- (void) removeHandle: (GSEasyHandle*)easyHandle;

@end

#endif
