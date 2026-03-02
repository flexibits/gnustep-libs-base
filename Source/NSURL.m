/*
 * NSURL.m — Clean NSURL reimplementation for GNUstep
 *
 * Replaces the original GNUstep implementation with a clean implementation.
 * Follows RFC 3986 for parsing. Apple NSURL is the reference implementation for behavior.
 *
 * Key improvements over the original:
 *   - NSString* fields for correct Unicode handling
 *   - No shared buffer / pointer aliasing
 *   - Correct RFC 3986 query and fragment inheritance for relative URLs
 *   - Valid percent-encoding validation (returns nil instead of throwing)
 *   - Forced hierarchical parsing API (URLWithString:forcingHierarchical:)
 *   - Global hierarchical-scheme registry
 *   - No deprecated stringByAddingPercentEscapesUsingEncoding:
 *   - NSURLComponents.URL fixed to not double-encode
 */

// These macros must be defined before importing NSURL.h so that the
// GS_EXPOSE blocks in the header expand the ivar declarations.
#define GS_NSURLQueryItem_IVARS \
    NSString *_name; \
    NSString *_value;

#define GS_NSURLComponents_IVARS \
    NSString *_string; \
    NSString *_fragment; \
    NSString *_host; \
    NSString *_password; \
    NSString *_path; \
    NSNumber *_port; \
    NSArray  *_queryItems; \
    NSString *_scheme; \
    NSString *_user; \
    NSRange   _rangeOfFragment; \
    NSRange   _rangeOfHost; \
    NSRange   _rangeOfPassword; \
    NSRange   _rangeOfPath; \
    NSRange   _rangeOfPort; \
    NSRange   _rangeOfQuery; \
    NSRange   _rangeOfQueryItems; \
    NSRange   _rangeOfScheme; \
    NSRange   _rangeOfUser; \
    BOOL      _dirty;

#import "common.h"
#define EXPOSE_NSURL_IVARS 1
#import "Foundation/NSArray.h"
#import "Foundation/NSAutoreleasePool.h"
#import "Foundation/NSCoder.h"
#import "Foundation/NSData.h"
#import "Foundation/NSDictionary.h"
#import "Foundation/NSError.h"
#import "Foundation/NSException.h"
#import "Foundation/NSFileManager.h"
#import "Foundation/NSLock.h"
#import "Foundation/NSMapTable.h"
#import "Foundation/NSPortCoder.h"
#import "Foundation/NSRunLoop.h"
#import "Foundation/NSURL.h"
#import "Foundation/NSURLHandle.h"
#import "Foundation/NSValue.h"
#import "Foundation/NSCharacterSet.h"
#import "Foundation/NSString.h"
#import "GNUstepBase/NSURL+GNUstepBase.h"

// ============================================================
// MARK: - Internal ParsedURL structure
// ============================================================

/**
 * Internal parsed URL representation. All string fields are in percent-encoded
 * form (original encoding preserved). Decoded forms are computed on demand by
 * accessor methods.
 *
 * Unlike the original GNUstep implementation the fields are NSString* objects
 * rather than char* pointers into a shared buffer, which gives correct Unicode
 * handling and independent lifetime management.
 *
 * The path field does NOT include the leading '/' — pathIsAbsolute tracks that
 * separately (consistent with the original GNUstep approach so that the same
 * path-building logic can be reused).
 */
typedef struct {
    NSString   *absolute;           ///< Cached absoluteString (nil until first access)
    NSString   *scheme;             ///< Lowercased scheme (e.g. @"http"), or nil
    NSString   *encodedUser;        ///< Percent-encoded user, or nil
    NSString   *encodedPassword;    ///< Percent-encoded password, or nil
    NSString   *encodedHost;        ///< Percent-encoded host including [] for IPv6, or nil
    NSString   *portString;         ///< Port as digit string (e.g. @"8080"), or nil
    NSString   *encodedPath;        ///< Percent-encoded path WITHOUT leading '/', or nil/""
    NSString   *encodedParameters;  ///< Percent-encoded parameters (after ';'), or nil
    NSString   *encodedQuery;       ///< Percent-encoded query (after '?'), or nil
    NSString   *encodedFragment;    ///< Percent-encoded fragment (after '#'), or nil
    BOOL        pathIsAbsolute;     ///< YES if path starts with '/'
    /**
     * Return @"" (not nil) for missing path (HTTP, HTTPS, WS, WSS, FTP, webcal,
     * webcals, caldav, caldavs).  These schemes always produce an empty-string
     * path via the public -path accessor when the URL string contains no path
     * segment (e.g. "http://host"), matching Apple behaviour.
     * Independent of hasNoPath — a URL can have emptyPath=YES AND hasNoPath=YES
     * simultaneously (e.g. "http://host" has no path segment, but -path returns @"").
     */
    BOOL        emptyPath;
    /**
     * The URL string contained no path segment at all after the authority.
     * For example, "http://host" and "http://host?q" both have hasNoPath=YES.
     * Contrast with "http://host/" which has hasNoPath=NO (the trailing '/'
     * constitutes a path).
     * This flag is orthogonal to emptyPath: hasNoPath records the syntactic
     * absence of a path; emptyPath controls the public -path return value.
     */
    BOOL        hasNoPath;
    BOOL        isGeneric;          ///< URL has an authority section (// was present)
    BOOL        isFile;             ///< Scheme is "file"
    BOOL        isIPv6Host;         ///< Host was an IPv6 literal [...]
    BOOL        ownAuthority;       ///< URL string provided its own authority (not inherited)
    BOOL        ownQuery;           ///< URL string contained a '?' query delimiter
    BOOL        ownFragment;        ///< URL string contained a '#' fragment delimiter
    BOOL        forcedHierarchical; ///< Was parsed with forcingHierarchical:YES
} ParsedURL;

/// Access the ParsedURL struct for self.
#define myData    ((ParsedURL *)(_data))
/// Access the ParsedURL struct of the base URL (may be NULL if no base).
#define baseData  ((_baseURL == nil) ? (ParsedURL *)NULL : (ParsedURL *)(_baseURL->_data))

// ============================================================
// MARK: - Static state
// ============================================================

/// Lock protecting NSURLHandle client callbacks.
static NSLock *clientsLock = nil;

/// Character set used for percent-encoding file URL paths.
static NSCharacterSet *fileCharSet = nil;

/// Global set of scheme strings that are always treated as hierarchical.
/// Protected by sSchemeRegistryLock.
static NSMutableSet *sHierarchicalSchemes = nil;

/// Lock protecting sHierarchicalSchemes.
static NSRecursiveLock *sSchemeRegistryLock = nil;

// ============================================================
// MARK: - Static helper functions
// ============================================================

/** Returns YES if every percent sequence in s is well-formed (% + 2 hex digits). */
static BOOL hasValidPercentEncoding(const char *s)
{
    while (*s != '\0') {
        if (*s == '%') {
            if (!isxdigit((unsigned char)s[1]) || !isxdigit((unsigned char)s[2])) {
                return NO;
            }
            s += 3;
        } else {
            s++;
        }
    }
    return YES;
}

/**
 * Returns YES if the lowercased scheme string is in the built-in list of schemes
 * that always use hierarchical (authority) parsing.
 */
static BOOL isBuiltInHierarchicalScheme(const char *scheme)
{
    static const char *builtIn[] = {
        "http", "https", "ftp", "ftps", "file", "ws", "wss",
        "webcal", "webcals", "caldav", "caldavs",
        "x-fantastical", "com.flexibits.fantastical3.mac",
        "com.flexibits.fantastical3.ios",
        "ms-outlook", "googlechrome", "firefox", "zoom",
        NULL
    };
    for (int i = 0; builtIn[i] != NULL; i++) {
        if (strcmp(scheme, builtIn[i]) == 0) {
            return YES;
        }
    }
    return NO;
}

/**
 * Applies RFC 3986 §5.2.4 "remove_dot_segments" to path.
 * Handles /./, /../, and leading dot-only segments.
 */
/**
 * Removes dot segments ("." and "..") from a URL path per RFC 3986 §5.2.4.
 * Implements the exact pseudocode from the RFC to ensure correct behaviour
 * for all edge cases including paths that become root-only or empty.
 */
static NSString *removeDotSegments(NSString *path)
{
    if ([path length] == 0) return path;

    NSMutableString *input  = [NSMutableString stringWithString:path];
    NSMutableString *output = [NSMutableString stringWithCapacity:[path length]];

    while ([input length] > 0) {
        // (A) Prefix "../" or "./" — remove the prefix.
        if ([input hasPrefix:@"../"]) {
            [input deleteCharactersInRange:NSMakeRange(0, 3)];
        } else if ([input hasPrefix:@"./"]) {
            [input deleteCharactersInRange:NSMakeRange(0, 2)];
        // (B) Prefix "/./" or segment "/." at end — replace with "/".
        } else if ([input hasPrefix:@"/./"]) {
            [input replaceCharactersInRange:NSMakeRange(0, 3) withString:@"/"];
        } else if ([input isEqualToString:@"/."]) {
            [input replaceCharactersInRange:NSMakeRange(0, 2) withString:@"/"];
        // (C) Prefix "/../" or segment "/.." at end — pop last output segment.
        } else if ([input hasPrefix:@"/../"]) {
            [input replaceCharactersInRange:NSMakeRange(0, 4) withString:@"/"];
            NSRange lastSlash = [output rangeOfString:@"/"
                                              options:NSBackwardsSearch];
            if (lastSlash.location != NSNotFound) {
                [output deleteCharactersInRange:
                    NSMakeRange(lastSlash.location,
                                [output length] - lastSlash.location)];
            } else {
                [output setString:@""];
            }
        } else if ([input isEqualToString:@"/.."]) {
            [input replaceCharactersInRange:NSMakeRange(0, 3) withString:@"/"];
            NSRange lastSlash = [output rangeOfString:@"/"
                                              options:NSBackwardsSearch];
            if (lastSlash.location != NSNotFound) {
                [output deleteCharactersInRange:
                    NSMakeRange(lastSlash.location,
                                [output length] - lastSlash.location)];
            } else {
                [output setString:@""];
            }
        // (D) Lone "." or ".." — discard.
        } else if ([input isEqualToString:@"."]) {
            [input setString:@""];
        } else if ([input isEqualToString:@".."]) {
            [input setString:@""];
        // (E) Move the first path segment (including its leading "/" if any)
        //     to the end of the output buffer.
        } else {
            NSUInteger searchFrom = ([input hasPrefix:@"/"]) ? 1 : 0;
            NSRange nextSlash = [input rangeOfString:@"/"
                                             options:0
                                               range:NSMakeRange(searchFrom,
                                                                 [input length] - searchFrom)];
            NSUInteger segEnd = (nextSlash.location != NSNotFound)
                                ? nextSlash.location
                                : [input length];
            [output appendString:[input substringToIndex:segEnd]];
            [input deleteCharactersInRange:NSMakeRange(0, segEnd)];
        }
    }
    return output;
}

/** Returns the NSURLHandle observer for a given handle from the clients map. */
static id clientForHandle(void *data, NSURLHandle *hdl)
{
    id client = nil;
    if (data != NULL) {
        [clientsLock lock];
        client = RETAIN((id)NSMapGet((NSMapTable *)data, hdl));
        [clientsLock unlock];
    }
    return AUTORELEASE(client);
}

// ============================================================
// MARK: - Forward declarations
// ============================================================

/**
 * Anonymous class extension for private methods implemented in the main
 * @implementation NSURL block. This avoids the "-Wincomplete-implementation"
 * warning that would result from declaring them in a named category.
 */
@interface NSURL () <NSSecureCoding>
- (NSString *) _buildResolvedEncodedPath;
- (NSString *) _pathWithEscapes:(BOOL)withEscapes;
- (void) _parseAuthority:(char *)authorityStart
                    into:(ParsedURL *)buf
          adjustingStart:(char **)startPtr;
- (void) _parseForcedAuthority:(char *)src
                          into:(ParsedURL *)buf
                adjustingStart:(char **)startPtr;
@end

/** Declares the GSPrivate methods that are implemented in @implementation NSURL (GSPrivate). */
@interface NSURL (GSPrivate)
- (NSURL *) _URLBySettingPath:(NSString *)newPath;
- (NSURL *) _URLBySettingPath:(NSString *)newPath encoded:(BOOL)encoded;
@end

// ============================================================
// MARK: - NSURL implementation
// ============================================================

@implementation NSURL

// --------------------------------------------------------
// MARK: Initialisation
// --------------------------------------------------------

+ (void) initialize
{
    if (clientsLock == nil) {
        clientsLock = [NSLock new];
        [[NSObject leakAt:&clientsLock] release];

        ASSIGN(fileCharSet,
               [NSCharacterSet characterSetWithCharactersInString:
                @"!$&'()*+,-./0123456789:=@"
                @"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                @"_abcdefghijklmnopqrstuvwxyz~"]);

        sHierarchicalSchemes = [NSMutableSet new];
        [[NSObject leakAt:&sHierarchicalSchemes] release];

        sSchemeRegistryLock = [NSRecursiveLock new];
        [[NSObject leakAt:&sSchemeRegistryLock] release];
    }
}

// --------------------------------------------------------
// MARK: Class factory methods
// --------------------------------------------------------

+ (instancetype) fileURLWithPath:(NSString *)aPath
{
    return AUTORELEASE([[self alloc] initFileURLWithPath:aPath]);
}

+ (instancetype) fileURLWithPath:(NSString *)aPath isDirectory:(BOOL)isDir
{
    return AUTORELEASE([[self alloc] initFileURLWithPath:aPath isDirectory:isDir]);
}

+ (instancetype) fileURLWithPath:(NSString *)aPath
                     isDirectory:(BOOL)isDir
                   relativeToURL:(NSURL *)baseURL
{
    return AUTORELEASE([[self alloc] initFileURLWithPath:aPath
                                            isDirectory:isDir
                                          relativeToURL:baseURL]);
}

+ (instancetype) fileURLWithPath:(NSString *)aPath relativeToURL:(NSURL *)baseURL
{
    return AUTORELEASE([[self alloc] initFileURLWithPath:aPath relativeToURL:baseURL]);
}

+ (instancetype) fileURLWithPathComponents:(NSArray *)components
{
    return [self fileURLWithPath:[NSString pathWithComponents:components]];
}

+ (instancetype) URLWithString:(NSString *)aUrlString
{
    return AUTORELEASE([[self alloc] initWithString:aUrlString relativeToURL:nil]);
}

+ (instancetype) URLWithString:(NSString *)aUrlString relativeToURL:(NSURL *)aBaseUrl
{
    return AUTORELEASE([[self alloc] initWithString:aUrlString relativeToURL:aBaseUrl]);
}

/**
 * Creates a URL from aUrlString, optionally forcing hierarchical (authority) parsing.
 * When forceHierarchical is YES a URL like @"myapp:host/path" will have
 * host=@"host" and path=@"/path" even though it lacks '://'.
 */
+ (instancetype) URLWithString:(NSString *)aUrlString
          forcingHierarchical:(BOOL)forceHierarchical
{
    return AUTORELEASE([[self alloc] initWithString:aUrlString
                                     relativeToURL:nil
                              forcingHierarchical:forceHierarchical]);
}

+ (instancetype) URLWithString:(NSString *)aUrlString
                 relativeToURL:(NSURL *)aBaseUrl
          forcingHierarchical:(BOOL)forceHierarchical
{
    return AUTORELEASE([[self alloc] initWithString:aUrlString
                                     relativeToURL:aBaseUrl
                              forcingHierarchical:forceHierarchical]);
}

/**
 * Registers the given scheme strings (lowercased, case-insensitive) so that any
 * URL whose scheme matches is always parsed hierarchically without '://'.
 * Thread-safe.
 */
+ (void) registerHierarchicalSchemes:(NSArray *)schemes
{
    [sSchemeRegistryLock lock];
    for (NSString *s in schemes) {
        [sHierarchicalSchemes addObject:[s lowercaseString]];
    }
    [sSchemeRegistryLock unlock];
}

/** Returns the current set of globally registered hierarchical schemes. */
+ (NSSet *) registeredHierarchicalSchemes
{
    [sSchemeRegistryLock lock];
    NSSet *copy = [[sHierarchicalSchemes copy] autorelease];
    [sSchemeRegistryLock unlock];
    return copy;
}

/** Removes previously registered schemes (primarily for tests). */
+ (void) unregisterHierarchicalSchemes:(NSArray *)schemes
{
    [sSchemeRegistryLock lock];
    for (NSString *s in schemes) {
        [sHierarchicalSchemes removeObject:[s lowercaseString]];
    }
    [sSchemeRegistryLock unlock];
}

+ (instancetype) URLByResolvingAliasFileAtURL:(NSURL *)url
                                      options:(NSURLBookmarkResolutionOptions)options
                                        error:(NSError **)error
{
    return nil;
}

+ (instancetype) URLByResolvingBookmarkData:(NSData *)bookmarkData
                                    options:(NSURLBookmarkResolutionOptions)options
                              relativeToURL:(NSURL *)relativeURL
                        bookmarkDataIsStale:(BOOL *)isStale
                                      error:(NSError **)error
{
    return nil;
}

// --------------------------------------------------------
// MARK: Instance init — file URLs
// --------------------------------------------------------

- (instancetype) initFileURLWithPath:(NSString *)aPath
{
    return [self initFileURLWithPath:aPath isDirectory:NO relativeToURL:nil];
}

- (instancetype) initFileURLWithPath:(NSString *)aPath isDirectory:(BOOL)isDir
{
    return [self initFileURLWithPath:aPath isDirectory:isDir relativeToURL:nil];
}

- (instancetype) initFileURLWithPath:(NSString *)aPath relativeToURL:(NSURL *)baseURL
{
    return [self initFileURLWithPath:aPath isDirectory:NO relativeToURL:baseURL];
}

- (instancetype) initFileURLWithPath:(NSString *)aPath
                         isDirectory:(BOOL)isDir
                       relativeToURL:(NSURL *)baseURL
{
    if (nil == aPath) {
        [NSException raise:NSInvalidArgumentException
                    format:@"[%@ %@] nil path parameter",
            NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    }

    NSFileManager *mgr = [NSFileManager defaultManager];

    if (![aPath isAbsolutePath]) {
        if (baseURL != nil) {
            aPath = [[baseURL relativePath] stringByAppendingPathComponent:aPath];
        } else {
            aPath = [[mgr currentDirectoryPath] stringByAppendingPathComponent:aPath];
        }
    }

    BOOL flag = NO;
    if ([mgr fileExistsAtPath:aPath isDirectory:&flag]) {
        if (![aPath isAbsolutePath]) {
            aPath = [aPath stringByStandardizingPath];
        }
        isDir = flag;
    }

    if (isDir && ![aPath hasSuffix:@"/"]) {
        aPath = [aPath stringByAppendingString:@"/"];
    }

    return [self initWithScheme:NSURLFileScheme host:@"" path:aPath];
}

// --------------------------------------------------------
// MARK: Instance init — scheme/host/path
// --------------------------------------------------------

/**
 * Builds a URL string from the given scheme, host, and path and delegates to
 * initWithString:relativeToURL:. The path is percent-encoded appropriately.
 * Handles IPv6 literals in aHost and user:password@host notation.
 */
- (instancetype) initWithScheme:(NSString *)aScheme
                           host:(NSString *)aHost
                           path:(NSString *)aPath
{
    NSCharacterSet *pathCS = [aScheme isEqualToString:@"file"]
        ? fileCharSet
        : [NSCharacterSet URLPathAllowedCharacterSet];
    NSString *encodedPath = [aPath stringByAddingPercentEncodingWithAllowedCharacters:pathCS];

    // Separate any user:password@host prefix.
    NSString *auth = nil;
    NSRange atRange = [aHost rangeOfString:@"@"];
    if (atRange.length > 0) {
        auth  = [aHost substringToIndex:atRange.location];
        aHost = [aHost substringFromIndex:NSMaxRange(atRange)];
    }

    // Wrap bare IPv6 addresses in brackets.
    if ([[aHost componentsSeparatedByString:@":"] count] > 2 &&
        ![aHost hasPrefix:@"["]) {
        aHost = [NSString stringWithFormat:@"[%@]", aHost];
    }

    if (auth != nil) {
        aHost = [NSString stringWithFormat:@"%@@%@", auth, aHost];
    }

    NSString *urlString;
    if ([encodedPath length] > 0) {
        if ([encodedPath hasPrefix:@"/"]) {
            urlString = [NSString stringWithFormat:@"%@://%@%@", aScheme, aHost, encodedPath];
        }
#if defined(_WIN32)
        else if ([aScheme isEqualToString:@"file"] &&
                 [encodedPath length] > 1 &&
                 [encodedPath characterAtIndex:1] == ':') {
            urlString = [NSString stringWithFormat:@"%@:///%@", aScheme, encodedPath];
        }
#endif
        else {
            urlString = [NSString stringWithFormat:@"%@://%@/%@", aScheme, aHost, encodedPath];
        }
    } else {
        urlString = [NSString stringWithFormat:@"%@://%@/", aScheme, aHost];
    }

    return [self initWithString:urlString relativeToURL:nil];
}

// --------------------------------------------------------
// MARK: Core designated initializer
// --------------------------------------------------------

- (instancetype) initWithString:(NSString *)aUrlString
{
    return [self initWithString:aUrlString relativeToURL:nil];
}

- (instancetype) initWithString:(NSString *)aUrlString relativeToURL:(NSURL *)aBaseUrl
{
    return [self initWithString:aUrlString
                  relativeToURL:aBaseUrl
           forcingHierarchical:NO];
}

/**
 * Designated NSURL initializer. Parses aUrlString into URL components.
 *
 * Returns nil for nil aUrlString; non-ASCII input; invalid percent-encoding;
 * and strings with no scheme and no base URL.
 *
 * When forceHierarchical is YES the URL is parsed as hierarchical (with an
 * authority) even if it lacks '://'. Used for custom app schemes such as
 * "myapp:hostname/path" that should yield host=@"hostname", path=@"/path".
 */
- (instancetype) initWithString:(NSString *)aUrlString
                  relativeToURL:(NSURL *)aBaseUrl
           forcingHierarchical:(BOOL)forceHierarchical
{
    if (nil == aUrlString) {
        RELEASE(self);
        return nil;
    }
    if (![aUrlString isKindOfClass:[NSString class]]) {
        [NSException raise:NSInvalidArgumentException
                    format:@"[%@ %@] bad string parameter",
            NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    }
    if (aBaseUrl != nil && ![aBaseUrl isKindOfClass:[NSURL class]]) {
        [NSException raise:NSInvalidArgumentException
                    format:@"[%@ %@] bad base URL parameter",
            NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    }

    ASSIGNCOPY(_urlString, aUrlString);
    ASSIGN(_baseURL, [aBaseUrl absoluteURL]);

    // Declare workBuf outside NS_DURING so it is accessible in NS_HANDLER
    // for cleanup when an exception occurs during parsing.
    char *workBuf = NULL;

    NS_DURING
    {
        ParsedURL *buf = NSZoneMalloc(NSDefaultMallocZone(), sizeof(ParsedURL));
        memset(buf, 0, sizeof(ParsedURL));
        _data = buf;

        ParsedURL *base = baseData;

        // Convert to ASCII; fail gracefully for non-ASCII input (Apple behavior).
        NSUInteger inputLen = [aUrlString length];
        NSUInteger bufSize  = inputLen + 4;
        workBuf             = (char *)malloc(bufSize);
        BOOL gotAscii = [aUrlString getCString:workBuf
                                     maxLength:bufSize
                                      encoding:NSASCIIStringEncoding];
        if (!gotAscii) {
            free(workBuf);
            RELEASE(self);
            return nil;
        }

        // Validate all percent sequences before parsing.
        if (!hasValidPercentEncoding(workBuf)) {
            free(workBuf);
            RELEASE(self);
            return nil;
        }

        char *ptr   = workBuf;
        char *start = workBuf;

        // ------ Step 1: Extract scheme ------
        // scheme = ALPHA *( ALPHA | DIGIT | "+" | "-" | "." ) ":"
        BOOL foundScheme = NO;
        if (isalpha((unsigned char)*ptr)) {
            ptr++;
            while (isalnum((unsigned char)*ptr) ||
                   *ptr == '+' || *ptr == '-' || *ptr == '.') {
                ptr++;
            }
            if (*ptr == ':') {
                NSUInteger schemeLen = (NSUInteger)(ptr - start);
                // Scheme names are always short (RFC 3986 §3.1); 256 bytes
                // is more than enough. This avoids alloca which requires
                // a separate header include on some toolchains.
                char schemeBuf[256];
                NSUInteger copyLen = schemeLen < 255 ? schemeLen : 255;
                for (NSUInteger i = 0; i < copyLen; i++) {
                    schemeBuf[i] = (char)tolower((unsigned char)start[i]);
                }
                schemeBuf[copyLen] = '\0';
                buf->scheme = [[NSString alloc] initWithUTF8String:schemeBuf];
                start = ptr + 1;  // Skip ':'.
                foundScheme = YES;
            } else {
                ptr = start;  // No scheme — backtrack.
            }
        }

        // Bare ':' at start would be an invalid empty scheme.
        if (!foundScheme && *start == ':') {
            free(workBuf);
            RELEASE(self);
            return nil;
        }

        // ------ Step 2: Scheme vs. base reconciliation ------
        if (buf->scheme != nil && base != nil &&
            base->scheme != nil &&
            ![buf->scheme isEqualToString:base->scheme]) {
            // Different scheme → absolute URL; discard base.
            DESTROY(_baseURL);
            base = nil;
        }
        if (buf->scheme == nil && base != nil) {
            buf->scheme = RETAIN(base->scheme);
        }
        if (buf->scheme == nil && base == nil) {
            free(workBuf);
            RELEASE(self);
            return nil;
        }

        // ------ Step 3: Scheme-specific flags ------
        BOOL canBeGeneric = YES;
        if (buf->scheme != nil) {
            const char *sch = [buf->scheme UTF8String];
            if (strcmp(sch, "file") == 0) {
                buf->isFile = YES;
            } else if (strcmp(sch, "http")    == 0 ||
                       strcmp(sch, "https")   == 0 ||
                       strcmp(sch, "webcal")  == 0 ||
                       strcmp(sch, "webcals") == 0 ||
                       strcmp(sch, "caldav")  == 0 ||
                       strcmp(sch, "caldavs") == 0 ||
                       strcmp(sch, "ftp")     == 0 ||
                       strcmp(sch, "ftps")    == 0 ||
                       strcmp(sch, "ws")      == 0 ||
                       strcmp(sch, "wss")     == 0) {
                buf->emptyPath = YES;
            } else if (strstr(sch, "fantastical") != NULL               ||
                       strncmp(sch, "com.flexibits.", 14) == 0          ||
                       strncmp(sch, "com.googleusercontent.", 22) == 0  ||
                       strcmp(sch, "ms-outlook")   == 0                 ||
                       strcmp(sch, "googlechrome") == 0                 ||
                       strcmp(sch, "firefox")      == 0                 ||
                       strcmp(sch, "zoom")         == 0) {
                buf->emptyPath = YES;
            } else if (strcmp(sch, "data")       == 0 ||
                       strcmp(sch, "mailto")     == 0 ||
                       strcmp(sch, "tel")        == 0 ||
                       strcmp(sch, "javascript") == 0) {
                canBeGeneric = NO;
                DESTROY(_baseURL);
                base = nil;
            }
            // Unknown schemes: canBeGeneric stays YES; hierarchical vs. opaque
            // is decided by the presence of '//' below (Step 4).
        }

        // ------ Step 3b: Check forced hierarchical flag ------
        if (canBeGeneric && !forceHierarchical && buf->scheme != nil) {
            [sSchemeRegistryLock lock];
            if ([sHierarchicalSchemes containsObject:buf->scheme]) {
                forceHierarchical = YES;
            }
            [sSchemeRegistryLock unlock];
        }
        if (canBeGeneric && !forceHierarchical && buf->scheme != nil) {
            if (isBuiltInHierarchicalScheme([buf->scheme UTF8String])) {
                forceHierarchical = YES;
            }
        }
        buf->forcedHierarchical = forceHierarchical;

        // ------ Step 4: Parse authority and path ------
        if (canBeGeneric) {
            if (start[0] == '/' && start[1] == '/') {
                // Explicit authority ('//').
                buf->isGeneric    = YES;
                buf->ownAuthority = YES;
                start += 2;
                [self _parseAuthority:start into:buf adjustingStart:&start];
            } else if (forceHierarchical && foundScheme) {
                // Force hierarchical: treat scheme:hostPart/path as //hostPart/path.
                buf->isGeneric    = YES;
                buf->ownAuthority = YES;
                [self _parseForcedAuthority:start into:buf adjustingStart:&start];
            } else {
                if (base != nil) {
                    buf->isGeneric = base->isGeneric;
                }
                if (*start == '/') {
                    buf->pathIsAbsolute = YES;
                    start++;
                }
            }

            // ------ Step 5: Fragment ('#') ------
            {
                char *hashPtr = strchr(start, '#');
                if (hashPtr != NULL) {
                    *hashPtr = '\0';
                    buf->encodedFragment = [[NSString alloc] initWithUTF8String:hashPtr + 1];
                    buf->ownFragment = YES;
                }
            }

            // ------ Step 6: Query ('?') ------
            {
                char *qPtr = strchr(start, '?');
                if (qPtr != NULL) {
                    *qPtr = '\0';
                    buf->encodedQuery = [[NSString alloc] initWithUTF8String:qPtr + 1];
                    buf->ownQuery = YES;
                }
            }

            // ------ Step 7: Parameters (';') ------
            {
                char *semiPtr = strchr(start, ';');
                if (semiPtr != NULL) {
                    *semiPtr = '\0';
                    if (*(semiPtr + 1) != '\0') {
                        buf->encodedParameters = [[NSString alloc]
                                                   initWithUTF8String:semiPtr + 1];
                    }
                }
            }

            // ------ Step 8: Store path ------
            buf->encodedPath = [[NSString alloc] initWithUTF8String:start];

            if (!buf->pathIsAbsolute && base == nil && !buf->hasNoPath &&
                [buf->encodedPath length] == 0) {
                buf->hasNoPath = YES;
            }

            // ------ Step 9: File URL cleanup ------
            if (buf->isFile) {
                DESTROY(buf->encodedUser);
                DESTROY(buf->encodedPassword);
                DESTROY(buf->portString);
                buf->isGeneric = YES;
                // Keep empty host: file:/// has host="" per Apple behavior.
                // Do NOT destroy buf->encodedHost here even if it is @"".
            }

            // ------ Step 10: Inherit from base ------
            if (base != nil) {
                // Inherit authority from base when relative URL has none.
                if (!buf->ownAuthority && !buf->isFile) {
                    if (buf->encodedHost == nil && base->encodedHost != nil) {
                        buf->encodedHost = RETAIN(base->encodedHost);
                    }
                    if (buf->encodedUser == nil && base->encodedUser != nil) {
                        buf->encodedUser = RETAIN(base->encodedUser);
                    }
                    if (buf->encodedPassword == nil && base->encodedPassword != nil) {
                        buf->encodedPassword = RETAIN(base->encodedPassword);
                    }
                    if (buf->portString == nil && base->portString != nil) {
                        buf->portString = RETAIN(base->portString);
                    }
                    if (!buf->isGeneric) {
                        buf->isGeneric = base->isGeneric;
                    }
                    buf->isIPv6Host = base->isIPv6Host;
                    buf->emptyPath |= base->emptyPath;
                    buf->isFile     = base->isFile;
                }

                // Inherit query from base ONLY when relative path is empty (RFC §5.2.2).
                if (!buf->ownQuery) {
                    BOOL relPathEmpty = (!buf->pathIsAbsolute &&
                                        !buf->hasNoPath &&
                                        !buf->ownAuthority &&
                                        (buf->encodedPath == nil ||
                                         [buf->encodedPath length] == 0));
                    if (relPathEmpty && base->encodedQuery != nil) {
                        buf->encodedQuery = RETAIN(base->encodedQuery);
                    }
                }
                // Fragment: NOT inherited from base per RFC §5.2.2.
            }
        } else {
            // Opaque URL: everything after the scheme colon is the resource specifier.
            buf->encodedPath = [[NSString alloc] initWithUTF8String:start];
            buf->isGeneric   = NO;
        }

        free(workBuf);
    }
    NS_HANDLER
    {
        free(workBuf);
        NSDebugLog(@"NSURL parse error: %@", localException);
        RELEASE(self);
        return nil;
    }
    NS_ENDHANDLER

    return self;
}

/** Parses the authority section (after '//') and advances *startPtr past it. */
- (void) _parseAuthority:(char *)authorityStart
                    into:(ParsedURL *)buf
          adjustingStart:(char **)startPtr
{
    char *p = authorityStart;
    while (*p && *p != '/' && *p != '?' && *p != '#') {
        p++;
    }

    char savedChar = *p;
    *p = '\0';

    char *auth = authorityStart;

    // Split userinfo@host.
    char *atSign = strchr(auth, '@');
    if (atSign != NULL) {
        *atSign = '\0';
        char *colonInUser = strchr(auth, ':');
        if (colonInUser != NULL) {
            *colonInUser = '\0';
            buf->encodedUser     = [[NSString alloc] initWithUTF8String:auth];
            buf->encodedPassword = [[NSString alloc] initWithUTF8String:colonInUser + 1];
        } else {
            buf->encodedUser = [[NSString alloc] initWithUTF8String:auth];
        }
        auth = atSign + 1;
    }

    // Parse host[:port]; handle IPv6.
    if (*auth == '[') {
        char *closeBracket = strchr(auth, ']');
        if (closeBracket == NULL) {
            *p = savedChar;
            [NSException raise:NSInvalidArgumentException
                        format:@"Malformed IPv6 address in URL"];
        }
        buf->isIPv6Host = YES;
        char *portColon = strchr(closeBracket, ':');
        if (portColon != NULL) {
            *portColon = '\0';
            buf->encodedHost = [[NSString alloc] initWithUTF8String:auth];
            char *portStr = portColon + 1;
            if (*portStr != '\0') {
                buf->portString = [[NSString alloc] initWithUTF8String:portStr];
            }
        } else {
            buf->encodedHost = [[NSString alloc] initWithUTF8String:auth];
        }
    } else {
        char *portColon = strchr(auth, ':');
        if (portColon != NULL) {
            *portColon = '\0';
            buf->encodedHost = [[NSString alloc] initWithUTF8String:auth];
            char *portStr = portColon + 1;
            if (*portStr != '\0') {
                BOOL allDigits = YES;
                for (char *q = portStr; *q; q++) {
                    if (!isdigit((unsigned char)*q)) { allDigits = NO; break; }
                }
                if (allDigits) {
                    buf->portString = [[NSString alloc] initWithUTF8String:portStr];
                }
            }
        } else {
            buf->encodedHost = [[NSString alloc] initWithUTF8String:auth];
        }
    }

    *p = savedChar;

    if (*p == '/') {
        buf->pathIsAbsolute = YES;
        p++;
    } else {
        buf->hasNoPath = YES;
    }

    *startPtr = p;
}

/**
 * Parses a forced-hierarchical authority from a URL string without '//'.
 * For "myapp:hostname/path" the authority is "hostname" and path is "/path".
 */
- (void) _parseForcedAuthority:(char *)src
                          into:(ParsedURL *)buf
                adjustingStart:(char **)startPtr
{
    char *slash = strchr(src, '/');
    char *qmark = strchr(src, '?');
    char *hash  = strchr(src, '#');

    char *hostEnd = slash;
    if (qmark && (!hostEnd || qmark < hostEnd)) hostEnd = qmark;
    if (hash  && (!hostEnd || hash  < hostEnd)) hostEnd = hash;
    if (hostEnd == NULL) hostEnd = src + strlen(src);

    char savedChar = *hostEnd;
    *hostEnd = '\0';
    buf->encodedHost = [[NSString alloc] initWithUTF8String:src];
    *hostEnd = savedChar;

    if (*hostEnd == '/') {
        buf->pathIsAbsolute = YES;
        hostEnd++;
    } else {
        // No path component: set both hasNoPath and emptyPath so that
        // -path returns @"" (not nil), matching Apple's behavior for
        // hierarchical URLs that have an authority but no path.
        buf->hasNoPath = YES;
        buf->emptyPath = YES;
    }

    *startPtr = hostEnd;
}

// --------------------------------------------------------
// MARK: Bookmark stubs (not used by Fantastical on Windows)
// --------------------------------------------------------

- (instancetype) initByResolvingBookmarkData:(NSData *)bookmarkData
                                     options:(NSURLBookmarkResolutionOptions)options
                               relativeToURL:(NSURL *)relativeURL
                         bookmarkDataIsStale:(BOOL *)isStale
                                       error:(NSError **)error
{
    RELEASE(self);
    return nil;
}

- (NSData *) bookmarkDataWithOptions:(NSURLBookmarkCreationOptions)options
    includingResourceValuesForKeys:(NSArray *)keys
                     relativeToURL:(NSURL *)relativeURL
                             error:(NSError **)error
{
    return nil;
}

// --------------------------------------------------------
// MARK: Dealloc
// --------------------------------------------------------

- (void) dealloc
{
    if (_clients != NULL) {
        NSFreeMapTable(_clients);
        _clients = NULL;
    }
    if (_data != NULL) {
        ParsedURL *p = myData;
        RELEASE(p->absolute);
        RELEASE(p->scheme);
        RELEASE(p->encodedUser);
        RELEASE(p->encodedPassword);
        RELEASE(p->encodedHost);
        RELEASE(p->portString);
        RELEASE(p->encodedPath);
        RELEASE(p->encodedParameters);
        RELEASE(p->encodedQuery);
        RELEASE(p->encodedFragment);
        NSZoneFree([self zone], _data);
        _data = NULL;
    }
    DESTROY(_urlString);
    DESTROY(_baseURL);
    [super dealloc];
}

// --------------------------------------------------------
// MARK: NSCopying
// --------------------------------------------------------

- (id) copyWithZone:(NSZone *)zone
{
    if (NSShouldRetainWithZone(self, zone) == NO) {
        return [[[self class] allocWithZone:zone] initWithString:_urlString
                                                   relativeToURL:_baseURL
                                            forcingHierarchical:myData->forcedHierarchical];
    }
    return RETAIN(self);
}

// --------------------------------------------------------
// MARK: NSCoding
// --------------------------------------------------------

/**
 * Returns YES so that NSKeyedArchiver with requiringSecureCoding:YES accepts
 * NSURL as a root object (and nested object when decoding).
 */
+ (BOOL) supportsSecureCoding
{
    return YES;
}

- (void) encodeWithCoder:(NSCoder *)aCoder
{
    if ([aCoder allowsKeyedCoding]) {
        [aCoder encodeObject:_baseURL forKey:@"NS.base"];
        [aCoder encodeObject:_urlString forKey:@"NS.relative"];
        if (myData->forcedHierarchical) {
            [aCoder encodeBool:YES forKey:@"NS.forcedHierarchical"];
        }
    } else {
        [aCoder encodeObject:_urlString];
        [aCoder encodeObject:_baseURL];
    }
}

- (instancetype) initWithCoder:(NSCoder *)aCoder
{
    NSString *rel;
    NSURL    *base;
    BOOL      forced = NO;

    if ([aCoder allowsKeyedCoding]) {
        // Use class-constrained decoding when available (NSSecureCoding).
        if ([aCoder respondsToSelector:@selector(decodeObjectOfClass:forKey:)]) {
            base = [aCoder decodeObjectOfClass:[NSURL class]   forKey:@"NS.base"];
            rel  = [aCoder decodeObjectOfClass:[NSString class] forKey:@"NS.relative"];
        } else {
            base = [aCoder decodeObjectForKey:@"NS.base"];
            rel  = [aCoder decodeObjectForKey:@"NS.relative"];
        }
        forced = [aCoder containsValueForKey:@"NS.forcedHierarchical"]
                     ? [aCoder decodeBoolForKey:@"NS.forcedHierarchical"]
                     : NO;
    } else {
        rel  = [aCoder decodeObject];
        base = [aCoder decodeObject];
    }
    if (rel == nil) rel = @"";
    return [self initWithString:rel relativeToURL:base forcingHierarchical:forced];
}

// --------------------------------------------------------
// MARK: Identity / equality
// --------------------------------------------------------

- (NSString *) description
{
    if (_baseURL != nil) {
        return [NSString stringWithFormat:@"%@ -- %@", _urlString, _baseURL];
    }
    return _urlString;
}

- (BOOL) isEqual:(id)other
{
    if (other == nil || ![other isKindOfClass:[NSURL class]]) {
        return NO;
    }
    return [[self absoluteString] isEqualToString:[other absoluteString]];
}

- (NSUInteger) hash
{
    return [[self absoluteString] hash];
}

// --------------------------------------------------------
// MARK: absoluteString
// --------------------------------------------------------

/**
 * Returns the fully-resolved, absolute URL string for this URL.
 * For relative URLs, applies RFC 3986 §5.2.2 path merging and uses the
 * corrected query-inheritance rule (inherit query only when the relative
 * path is empty; never inherit fragment).
 */
- (NSString *) absoluteString
{
    NSString *cached = myData->absolute;
    if (cached != nil) {
        return cached;
    }

    if (_baseURL == nil) {
        ASSIGN(myData->absolute, _urlString);
        return _urlString;
    }

    ParsedURL *R = myData;
    ParsedURL *B = baseData;

    NSMutableString *result = [NSMutableString stringWithCapacity:256];

    // Scheme: RFC §5.2.2 — use R's scheme if present, else inherit from base.
    NSString *effectiveScheme = R->scheme ? R->scheme : (B ? B->scheme : nil);
    if (effectiveScheme != nil) {
        [result appendString:effectiveScheme];
        [result appendString:@":"];
    }

    // Authority (host may have been inherited from base at parse time).
    NSString *effectiveHost = R->encodedHost;
    if (R->isGeneric || effectiveHost != nil ||
        R->encodedUser != nil || R->portString != nil) {
        [result appendString:@"//"];
        if (R->encodedUser != nil) {
            [result appendString:R->encodedUser];
            if (R->encodedPassword != nil) {
                [result appendString:@":"];
                [result appendString:R->encodedPassword];
            }
            [result appendString:@"@"];
        }
        if (effectiveHost != nil) {
            [result appendString:effectiveHost];
        }
        if (R->portString != nil) {
            [result appendString:@":"];
            [result appendString:R->portString];
        }
    }

    // Path (merged with dot-segment removal).
    NSString *resolvedPath = [self _buildResolvedEncodedPath];
    if (resolvedPath != nil) {
        [result appendString:resolvedPath];
    }

    // Parameters.
    if (R->encodedParameters != nil) {
        [result appendString:@";"];
        [result appendString:R->encodedParameters];
    }

    // Query: RFC §5.2.2 — inherit from base ONLY when relative path is empty.
    NSString *effectiveQuery = R->encodedQuery;
    if (!R->ownQuery && B != nil) {
        BOOL relPathEmpty = (!R->pathIsAbsolute &&
                             !R->hasNoPath &&
                             !R->ownAuthority &&
                             (R->encodedPath == nil ||
                              [R->encodedPath length] == 0));
        if (relPathEmpty) {
            effectiveQuery = B->encodedQuery;
        }
    }
    if (effectiveQuery != nil) {
        [result appendString:@"?"];
        [result appendString:effectiveQuery];
    }

    // Fragment: never inherited (RFC §5.2.2).
    if (R->encodedFragment != nil) {
        [result appendString:@"#"];
        [result appendString:R->encodedFragment];
    }

    NSString *abs = [result copy];
    // Protect the cache write: two threads could compute the same result
    // concurrently, but only one should perform the ASSIGN to avoid a
    // retain/release race on the shared pointer.
    @synchronized(self) {
        if (myData->absolute == nil) {
            myData->absolute = abs;   // Transfer ownership (already retained by copy)
        } else {
            RELEASE(abs);             // Another thread won the race; discard ours
        }
    }
    return myData->absolute;
}

/**
 * Builds the resolved, encoded path string (including leading '/') by merging
 * the relative URL's path with the base URL's path per RFC 3986 §5.2.3.
 */
- (NSString *) _buildResolvedEncodedPath
{
    ParsedURL *R = myData;

    // 1. R has its own absolute path (starts with '/').
    //    RFC §5.2.2: T.path = remove_dot_segments(R.path).
    if (R->pathIsAbsolute) {
        if (R->hasNoPath) return nil;
        NSString *p = R->encodedPath ? R->encodedPath : @"";
        return removeDotSegments([@"/" stringByAppendingString:p]);
    }

    ParsedURL *B = baseData;
    NSString  *relPath = R->encodedPath ? R->encodedPath : @"";

    // 2. R has its own authority, or there is no base: use R's path directly.
    //    This handles "//authority/path" references where the path may be empty.
    if (B == nil || R->ownAuthority) {
        return removeDotSegments(relPath);
    }

    // 3. R has no authority, no base, and an empty relative path: inherit base path.
    if ([relPath length] == 0) {
        if (B->hasNoPath) return nil;
        NSString *basePath = B->encodedPath ? B->encodedPath : @"";
        if ([basePath length] == 0 && !B->pathIsAbsolute) return nil;
        return B->pathIsAbsolute ? [@"/" stringByAppendingString:basePath] : basePath;
    }

    // 4. Non-empty relative path: merge with base (RFC §5.2.3) then remove dots.
    NSString *basePath = B->encodedPath ? B->encodedPath : @"";
    NSRange lastSlash = [basePath rangeOfString:@"/" options:NSBackwardsSearch];

    NSString *merged;
    if (lastSlash.location != NSNotFound) {
        NSString *baseDir = [basePath substringToIndex:NSMaxRange(lastSlash)];
        merged = [NSString stringWithFormat:@"/%@%@", baseDir, relPath];
    } else if (B->pathIsAbsolute) {
        merged = [NSString stringWithFormat:@"/%@", relPath];
    } else {
        merged = relPath;
    }

    return removeDotSegments(merged);
}

// --------------------------------------------------------
// MARK: Property accessors
// --------------------------------------------------------

- (NSURL *) absoluteURL
{
    return (_baseURL == nil) ? self : [NSURL URLWithString:[self absoluteString]];
}

- (NSURL *) baseURL
{
    return _baseURL;
}

- (NSString *) scheme
{
    return myData->scheme;
}

/** Returns the decoded host. For IPv6 literals, brackets are stripped. */
- (NSString *) host
{
    NSString *encoded = myData->encodedHost;
    if (encoded == nil) return nil;

    NSString *host;
    if (myData->isIPv6Host) {
        NSUInteger len = [encoded length];
        host = (len >= 2) ? [encoded substringWithRange:NSMakeRange(1, len - 2)] : encoded;
    } else {
        host = encoded;
    }
    return [host stringByRemovingPercentEncoding];
}

/** Returns the port number. Uses NSInteger to avoid wrapping for ports > 65535. */
- (NSNumber *) port
{
    return (myData->portString != nil)
        ? [NSNumber numberWithInteger:[myData->portString integerValue]]
        : nil;
}

- (NSString *) user
{
    return (myData->encodedUser != nil)
        ? [myData->encodedUser stringByRemovingPercentEncoding]
        : nil;
}

- (NSString *) password
{
    return (myData->encodedPassword != nil)
        ? [myData->encodedPassword stringByRemovingPercentEncoding]
        : nil;
}

/**
 * Returns the decoded, resolved path.
 * Returns @"" for HTTP/HTTPS URLs with no path (e.g. http://example.com).
 * Returns nil for opaque URLs.
 */
- (NSString *) path
{
    return [self _pathWithEscapes:NO];
}

- (NSArray *) pathComponents   { return [[self path] pathComponents]; }
- (NSString *) pathExtension   { return [[self path] pathExtension]; }
- (NSString *) lastPathComponent { return [[self path] lastPathComponent]; }

/** Decoded path of the relative URL string only (not resolved against base). */
- (NSString *) relativePath
{
    if (_baseURL == nil) return [self path];

    ParsedURL *R = myData;
    if (!R->isGeneric && R->scheme != nil) return nil;  // Opaque.

    NSString *encoded = R->encodedPath;
    if (encoded == nil) return nil;
    NSString *result = [encoded stringByRemovingPercentEncoding];
    if (R->pathIsAbsolute && result != nil) {
        result = [@"/" stringByAppendingString:result];
    }
    return result;
}

- (NSString *) relativeString
{
    return _urlString;
}

/**
 * Returns the query component, percent-decoded (Apple/RFC behavior).
 * NSURLComponents.percentEncodedQuery gives the raw form if needed.
 */
- (NSString *) query
{
    NSString *raw = myData->encodedQuery;
    if (raw == nil) return nil;
    NSString *decoded = [raw stringByRemovingPercentEncoding];
    return decoded ? decoded : raw;
}

/**
 * Returns the fragment component, percent-decoded (Apple/RFC behavior).
 */
- (NSString *) fragment
{
    NSString *raw = myData->encodedFragment;
    if (raw == nil) return nil;
    NSString *decoded = [raw stringByRemovingPercentEncoding];
    return decoded ? decoded : raw;
}

- (NSString *) parameterString
{
    return myData->encodedParameters;
}

- (BOOL) isFileURL
{
    return myData->isFile;
}

- (BOOL) isFileReferenceURL { return NO; }
- (NSURL *) fileReferenceURL { return [self isFileURL] ? self : nil; }
- (NSURL *) filePathURL      { return [self isFileURL] ? self : nil; }

/**
 * Returns everything after the scheme colon.
 * For generic URLs this is the "//authority/path...?query#fragment" portion.
 * For opaque URLs it is the resource specifier stored in encodedPath.
 * For relative URLs with a base, the resolved absolute URL is used so the
 * result matches Apple behaviour (the full resolved resource specifier).
 */
- (NSString *) resourceSpecifier
{
    // For relative URLs with a base, resolve first so that the result
    // reflects the merged absolute URL (matches Apple behavior).
    if (_baseURL != nil) {
        return [[self absoluteURL] resourceSpecifier];
    }

    if (myData->isGeneric) {
        NSRange range = [_urlString rangeOfString:@"://"];
        if (range.length > 0) {
            return ([self host] == nil)
                ? [_urlString substringFromIndex:NSMaxRange(range)]      // Strip extra "/"
                : [_urlString substringFromIndex:range.location + 1];    // Include "//"
        }
        range = [_urlString rangeOfString:@":"];
        if (range.length > 0) {
            return [_urlString substringFromIndex:NSMaxRange(range)];
        }
        return _urlString;
    }
    return myData->encodedPath;
}

// --------------------------------------------------------
// MARK: Internal path building
// --------------------------------------------------------

/**
 * Returns the resolved path string, encoded (YES) or decoded (NO).
 * Handles emptyPath schemes, relative-URL resolution, and Windows drive paths.
 */
- (NSString *) _pathWithEscapes:(BOOL)withEscapes
{
    ParsedURL *R = myData;

    // Opaque URL with scheme: no path.
    if (!R->isGeneric && R->scheme != nil) return nil;

    NSString *encodedResult = nil;

    if (R->pathIsAbsolute) {
        if (R->hasNoPath) {
            return R->emptyPath ? @"" : nil;
        }
        NSString *p = R->encodedPath ? R->encodedPath : @"";
        encodedResult = [@"/" stringByAppendingString:p];
    } else if (_baseURL == nil) {
        NSString *p = R->encodedPath ? R->encodedPath : @"";
        if ([p length] == 0) {
            return R->emptyPath ? @"" : nil;
        }
        encodedResult = p;
    } else {
        encodedResult = [self _buildResolvedEncodedPath];
        if (encodedResult == nil) {
            return R->emptyPath ? @"" : nil;
        }
    }

    if (encodedResult == nil) {
        return R->emptyPath ? @"" : nil;
    }

    if (!withEscapes) {
        NSString *decoded = [encodedResult stringByRemovingPercentEncoding];
        encodedResult = decoded ? decoded : encodedResult;
    }

#if defined(_WIN32)
    // Strip leading '/' from Windows absolute drive-letter paths.
    if (R->isFile && !withEscapes && encodedResult != nil) {
        NSUInteger len = [encodedResult length];
        if (len >= 3 &&
            [encodedResult characterAtIndex:0] == '/' &&
            isalpha((unsigned char)[encodedResult characterAtIndex:1]) &&
            [encodedResult characterAtIndex:2] == ':') {
            encodedResult = [encodedResult substringFromIndex:1];
        }
    }
#endif

    return encodedResult;
}

// --------------------------------------------------------
// MARK: URL manipulation helpers
// --------------------------------------------------------

- (NSURL *) standardizedURL
{
    NSURL *target = [self absoluteURL];
    NSString *path = [target _pathWithEscapes:YES];
    if (path == nil) return target;
    NSString *std = removeDotSegments(path);
    if ([std isEqualToString:path]) return target;
    return [target _URLBySettingPath:std encoded:YES];
}

- (NSURL *) URLByAppendingPathComponent:(NSString *)pathComponent
{
    return [self _URLBySettingPath:[[self path] stringByAppendingPathComponent:pathComponent]];
}

- (NSURL *) URLByAppendingPathComponent:(NSString *)pathComponent isDirectory:(BOOL)isDirectory
{
    NSString *newPath = [[self path] stringByAppendingPathComponent:pathComponent];
    if (isDirectory && ![newPath hasSuffix:@"/"]) {
        newPath = [newPath stringByAppendingString:@"/"];
    }
    return [self _URLBySettingPath:newPath];
}

- (NSURL *) URLByAppendingPathExtension:(NSString *)pathExtension
{
    return [self _URLBySettingPath:[[self path] stringByAppendingPathExtension:pathExtension]];
}

- (NSURL *) URLByDeletingLastPathComponent
{
    // Apple's behavior: always append trailing slash to indicate the result is
    // a directory. NSString's -stringByDeletingLastPathComponent does not add
    // one, so we do it explicitly.
    NSString *newPath = [[self path] stringByDeletingLastPathComponent];
    if (newPath.length > 0 && ![newPath hasSuffix:@"/"]) {
        newPath = [newPath stringByAppendingString:@"/"];
    }
    return [self _URLBySettingPath:newPath];
}

- (NSURL *) URLByDeletingPathExtension
{
    return [self _URLBySettingPath:[[self path] stringByDeletingPathExtension]];
}

- (NSURL *) URLByResolvingSymlinksInPath
{
    return [self isFileURL]
        ? [NSURL fileURLWithPath:[[self path] stringByResolvingSymlinksInPath]]
        : self;
}

- (NSURL *) URLByStandardizingPath
{
    return [self isFileURL]
        ? [NSURL fileURLWithPath:[[self path] stringByStandardizingPath]]
        : self;
}

// --------------------------------------------------------
// MARK: Resource access
// --------------------------------------------------------

- (BOOL) checkResourceIsReachableAndReturnError:(NSError **)error
{
    if ([self isFileURL]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = [self path];
        if ([fm fileExistsAtPath:path]) {
            if (![fm isReadableFileAtPath:path]) {
                if (error) {
                    *error = [NSError errorWithDomain:@"NSURLError"
                                                 code:0
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                        @"File not readable"}];
                }
                return NO;
            }
            return YES;
        }
        if (error) {
            *error = [NSError errorWithDomain:@"NSURLError"
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"File does not exist"}];
        }
        return NO;
    }
    if (error) {
        *error = [NSError errorWithDomain:@"NSURLError"
                                     code:0
                                 userInfo:@{NSLocalizedDescriptionKey: @"Not a file URL"}];
    }
    return NO;
}

- (BOOL) getResourceValue:(id *)value forKey:(NSString *)key error:(NSError **)error
{
    return NO;
}

- (void) loadResourceDataNotifyingClient:(id)client usingCache:(BOOL)shouldUseCache
{
    NSURLHandle *handle = [self URLHandleUsingCache:shouldUseCache];
    NSData *d;

    if (shouldUseCache && (d = [handle availableResourceData]) != nil) {
        if ([client respondsToSelector:@selector(URL:resourceDataDidBecomeAvailable:)]) {
            [client URL:self resourceDataDidBecomeAvailable:d];
        }
        if ([client respondsToSelector:@selector(URLResourceDidFinishLoading:)]) {
            [client URLResourceDidFinishLoading:self];
        }
    } else {
        if (client != nil) {
            [clientsLock lock];
            if (_clients == NULL) {
                _clients = NSCreateMapTable(NSObjectMapKeyCallBacks,
                                            NSNonRetainedObjectMapValueCallBacks, 0);
            }
            NSMapInsert((NSMapTable *)_clients, (void *)handle, (void *)client);
            [clientsLock unlock];
            [handle addClient:self];
        }
        [handle loadInBackground];
    }
}

- (id) propertyForKey:(NSString *)propertyKey
{
    return [[self URLHandleUsingCache:YES] propertyForKey:propertyKey];
}

- (NSData *) resourceDataUsingCache:(BOOL)shouldUseCache
{
    NSURLHandle *handle = [self URLHandleUsingCache:YES];
    NSData *data = nil;
    if ([handle status] == NSURLHandleLoadSucceeded) {
        data = [handle availableResourceData];
    }
    if (!shouldUseCache || [handle status] != NSURLHandleLoadSucceeded) {
        data = [handle loadInForeground];
    }
    if (data == nil) {
        data = [handle availableResourceData];
    }
    return data;
}

- (BOOL) setProperty:(id)property forKey:(NSString *)propertyKey
{
    return [[self URLHandleUsingCache:YES] writeProperty:property forKey:propertyKey];
}

- (BOOL) setResourceData:(NSData *)data
{
    NSURLHandle *handle = [self URLHandleUsingCache:YES];
    if (handle == nil || ![handle writeData:data]) return NO;
    if ([handle loadInForeground] == nil) return NO;
    return YES;
}

- (NSURLHandle *) URLHandleUsingCache:(BOOL)shouldUseCache
{
    NSURLHandle *handle = nil;
    if (shouldUseCache) handle = [NSURLHandle cachedHandleForURL:self];
    if (handle == nil) {
        Class c = [NSURLHandle URLHandleClassForURL:self];
        if (c != NULL) {
            handle = AUTORELEASE([[c alloc] initWithURL:self cached:shouldUseCache]);
        }
    }
    return handle;
}

// --------------------------------------------------------
// MARK: NSURLHandleClient callbacks
// --------------------------------------------------------

- (void) URLHandle:(NSURLHandle *)sender
    resourceDataDidBecomeAvailable:(NSData *)newData
{
    id c = clientForHandle(_clients, sender);
    if ([c respondsToSelector:@selector(URL:resourceDataDidBecomeAvailable:)]) {
        [c URL:self resourceDataDidBecomeAvailable:newData];
    }
}

- (void) URLHandle:(NSURLHandle *)sender
    resourceDidFailLoadingWithReason:(NSString *)reason
{
    id c = clientForHandle(_clients, sender);
    RETAIN(self);
    [sender removeClient:self];
    if (c != nil) {
        [clientsLock lock];
        NSMapRemove((NSMapTable *)_clients, (void *)sender);
        [clientsLock unlock];
        if ([c respondsToSelector:@selector(URL:resourceDidFailLoadingWithReason:)]) {
            [c URL:self resourceDidFailLoadingWithReason:reason];
        }
    }
    RELEASE(self);
}

- (void) URLHandleResourceDidBeginLoading:(NSURLHandle *)sender {}

- (void) URLHandleResourceDidCancelLoading:(NSURLHandle *)sender
{
    id c = clientForHandle(_clients, sender);
    RETAIN(self);
    [sender removeClient:self];
    if (c != nil) {
        [clientsLock lock];
        NSMapRemove((NSMapTable *)_clients, (void *)sender);
        [clientsLock unlock];
        if ([c respondsToSelector:@selector(URLResourceDidCancelLoading:)]) {
            [c URLResourceDidCancelLoading:self];
        }
    }
    RELEASE(self);
}

- (void) URLHandleResourceDidFinishLoading:(NSURLHandle *)sender
{
    id c = clientForHandle(_clients, sender);
    RETAIN(self);
    [sender removeClient:self];
    if (c != nil) {
        [clientsLock lock];
        NSMapRemove((NSMapTable *)_clients, (void *)sender);
        [clientsLock unlock];
        if ([c respondsToSelector:@selector(URLResourceDidFinishLoading:)]) {
            [c URLResourceDidFinishLoading:self];
        }
    }
    RELEASE(self);
}

- (id) replacementObjectForPortCoder:(NSPortCoder *)aCoder
{
    return ([aCoder isByref] == NO) ? self : [super replacementObjectForPortCoder:aCoder];
}

@end // @implementation NSURL

// ============================================================
// MARK: - GSPrivate category
// ============================================================

@implementation NSURL (GSPrivate)

/**
 * Creates a new URL with the same scheme, host, user, password, port, query, and
 * fragment as the receiver, but with the path replaced by newPath (decoded).
 */
- (NSURL *) _URLBySettingPath:(NSString *)newPath
{
    return [self _URLBySettingPath:newPath encoded:NO];
}

/**
 * Returns the raw percent-encoded query string (without '?'), or nil.
 * Unlike -query this does NOT decode percent-encoding.
 */
- (NSString *) _encodedQuery
{
    return myData->encodedQuery;
}

/**
 * Returns the raw percent-encoded fragment string (without '#'), or nil.
 * Unlike -fragment this does NOT decode percent-encoding.
 */
- (NSString *) _encodedFragment
{
    return myData->encodedFragment;
}

- (NSURL *) _URLBySettingPath:(NSString *)newPath encoded:(BOOL)encoded
{
    if ([self isFileURL]) {
        // Build file URL directly rather than using fileURLWithPath:, which
        // resolves POSIX-style paths (/path/to/file) against the Windows CWD.
        // We preserve the original host component (e.g. file://host/path).
        NSString *host = myData->encodedHost ? myData->encodedHost : @"";
        NSString *encodedPath = encoded
            ? newPath
            : [newPath stringByAddingPercentEncodingWithAllowedCharacters:
               [NSCharacterSet URLPathAllowedCharacterSet]];
        return [NSURL URLWithString:[NSString stringWithFormat:@"file://%@%@",
                                     host, encodedPath]];
    }
    // Use initWithScheme:user:password:host:port:fullPath:parameterString:query:fragment:
    // which re-encodes the path correctly. The query and fragment parameters are
    // appended raw (no encoding applied), so pass the percent-encoded forms directly.
    NSString *pathArg = encoded ? [newPath stringByRemovingPercentEncoding] : newPath;
    NSURL *u = [[NSURL alloc] initWithScheme:[self scheme]
                                        user:[self user]
                                    password:[self password]
                                        host:[self host]
                                        port:[self port]
                                    fullPath:pathArg
                             parameterString:[self parameterString]
                                       query:myData->encodedQuery
                                    fragment:myData->encodedFragment];
    return AUTORELEASE(u);
}

@end // @implementation NSURL (GSPrivate)

// ============================================================
// MARK: - NSObject (NSURLClient) informal protocol
// ============================================================

@implementation NSObject (NSURLClient)

- (void) URL:(NSURL *)sender resourceDataDidBecomeAvailable:(NSData *)newBytes {}
- (void) URL:(NSURL *)sender resourceDidFailLoadingWithReason:(NSString *)reason {}
- (void) URLResourceDidCancelLoading:(NSURL *)sender {}
- (void) URLResourceDidFinishLoading:(NSURL *)sender {}

@end

// ============================================================
// MARK: - NSURL (GNUstepBase) category
// ============================================================

@implementation NSURL (GNUstepBase)

/**
 * Returns the full percent-encoded path including any parameter string (';…')
 * but excluding the query and fragment. Unlike -path this does NOT decode
 * percent-encoding, so %2F and / remain distinct.
 */
- (NSString *) fullPath
{
    NSString *encoded = [self _pathWithEscapes:YES];
    if (encoded == nil) return nil;
    if (myData->encodedParameters != nil) {
        encoded = [encoded stringByAppendingFormat:@";%@", myData->encodedParameters];
    }
    return encoded;
}

/**
 * Returns the percent-encoded path without decoding any sequences.
 * Useful when a caller must distinguish %2F (literal slash in a segment)
 * from / (path separator).
 */
- (NSString *) pathWithEscapes
{
    return [self _pathWithEscapes:YES];
}

@end // @implementation NSURL (GNUstepBase)

// ============================================================
// MARK: - NSURLQueryItem
// ============================================================

#define GSInternal  NSURLQueryItemInternal
#include "GSInternal.h"
GS_PRIVATE_INTERNAL(NSURLQueryItem)

@implementation NSURLQueryItem

+ (instancetype) queryItemWithName:(NSString *)name value:(NSString *)value
{
    return AUTORELEASE([[self alloc] initWithName:name value:value]);
}

- (instancetype) init
{
    return [self initWithName:nil value:nil];
}

- (instancetype) initWithName:(NSString *)name value:(NSString *)value
{
    self = [super init];
    if (self != nil) {
        GS_CREATE_INTERNAL(NSURLQueryItem);
        ASSIGNCOPY(internal->_name,  name != nil ? name : @"");
        ASSIGNCOPY(internal->_value, value);
    }
    return self;
}

- (void) dealloc
{
    RELEASE(internal->_name);
    RELEASE(internal->_value);
    GS_DESTROY_INTERNAL(NSURLQueryItem);
    [super dealloc];
}

- (NSString *) name  { return internal->_name; }
- (NSString *) value { return internal->_value; }

- (id) initWithCoder:(NSCoder *)aCoder
{
    if ((self = [super init]) != nil) {
        GS_CREATE_INTERNAL(NSURLQueryItem);
        if ([aCoder allowsKeyedCoding]) {
            ASSIGN(internal->_name,  [aCoder decodeObjectForKey:@"NS.name"]);
            ASSIGN(internal->_value, [aCoder decodeObjectForKey:@"NS.value"]);
        } else {
            ASSIGN(internal->_name,  [aCoder decodeObject]);
            ASSIGN(internal->_value, [aCoder decodeObject]);
        }
    }
    return self;
}

- (void) encodeWithCoder:(NSCoder *)aCoder
{
    if ([aCoder allowsKeyedCoding]) {
        [aCoder encodeObject:internal->_name  forKey:@"NS.name"];
        [aCoder encodeObject:internal->_value forKey:@"NS.value"];
    } else {
        [aCoder encodeObject:internal->_name];
        [aCoder encodeObject:internal->_value];
    }
}

- (id) copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] initWithName:internal->_name
                                                     value:internal->_value];
}

@end // @implementation NSURLQueryItem

// ============================================================
// MARK: - NSURLComponents
// ============================================================

#undef  GSInternal
#define GSInternal NSURLComponentsInternal
#include "GSInternal.h"
GS_PRIVATE_INTERNAL(NSURLComponents)

@implementation NSURLComponents

/// Character set for percent-encoding query item names/values:
/// URLQueryAllowedCharacterSet minus '&' and '='.
static NSCharacterSet *queryItemCharSet = nil;

+ (void) initialize
{
    if (queryItemCharSet == nil) {
        ENTER_POOL
        NSMutableCharacterSet *m =
            [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [m removeCharactersInString:@"&="];
        queryItemCharSet = [m copy];
        RELEASE(m);
        LEAVE_POOL
    }
}

+ (instancetype) componentsWithString:(NSString *)urlString
{
    return AUTORELEASE([[self alloc] initWithString:urlString]);
}

+ (instancetype) componentsWithURL:(NSURL *)url resolvingAgainstBaseURL:(BOOL)resolve
{
    return AUTORELEASE([[self alloc] initWithURL:url resolvingAgainstBaseURL:resolve]);
}

- (instancetype) init
{
    self = [super init];
    if (self != nil) {
        GS_CREATE_INTERNAL(NSURLComponents);
        internal->_rangeOfFragment    = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfHost        = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfPassword    = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfPath        = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfPort        = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfQuery       = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfQueryItems  = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfScheme      = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfUser        = NSMakeRange(NSNotFound, 0);
    }
    return self;
}

- (instancetype) initWithString:(NSString *)URLString
{
    NSURL *url = [NSURL URLWithString:URLString];
    if (url == nil) { RELEASE(self); return nil; }
    return [self initWithURL:url resolvingAgainstBaseURL:NO];
}

- (instancetype) initWithURL:(NSURL *)url resolvingAgainstBaseURL:(BOOL)resolve
{
    self = [self init];
    if (self != nil) {
        [self setURL:resolve ? [url absoluteURL] : url];
    }
    return self;
}

- (void) dealloc
{
    RELEASE(internal->_string);
    RELEASE(internal->_fragment);
    RELEASE(internal->_host);
    RELEASE(internal->_password);
    RELEASE(internal->_path);
    RELEASE(internal->_port);
    RELEASE(internal->_queryItems);
    RELEASE(internal->_scheme);
    RELEASE(internal->_user);
    GS_DESTROY_INTERNAL(NSURLComponents);
    [super dealloc];
}

- (id) copyWithZone:(NSZone *)zone
{
    return [[NSURLComponents allocWithZone:zone] initWithURL:[self URL]
                                     resolvingAgainstBaseURL:NO];
}

// ---- URL String regeneration ----

/**
 * Rebuilds the URL string from component fields using percent-encoded setters
 * so that already-encoded sequences such as %20 are never double-encoded to %2520.
 */
- (void) _regenerateURL
{
    if (!internal->_dirty) return;

    NSMutableString *s = [[NSMutableString alloc] initWithCapacity:256];
    NSUInteger location = 0;
    NSUInteger len;
    NSString *component;

    if (internal->_scheme != nil) {
        component = [self scheme];
        len = [component length];
        [s appendString:component];
        internal->_rangeOfScheme = NSMakeRange(location, len);
        // Emit "://" only when the URL has an authority component (host or user);
        // otherwise emit just ":" for scheme-only or scheme+path URLs.
        if (internal->_host != nil || internal->_user != nil) {
            [s appendString:@"://"];
            location += len + 3;
        } else {
            [s appendString:@":"];
            location += len + 1;
        }
    } else {
        internal->_rangeOfScheme = NSMakeRange(NSNotFound, 0);
    }

    if (internal->_user != nil) {
        component = [self percentEncodedUser];
        len = [component length];
        [s appendString:component];
        internal->_rangeOfUser = NSMakeRange(location, len);
        location += len;

        if (internal->_password != nil) {
            [s appendString:@":"];
            location++;
            component = [self percentEncodedPassword];
            len = [component length];
            [s appendString:component];
            internal->_rangeOfPassword = NSMakeRange(location, len);
            location += len;
        } else {
            internal->_rangeOfPassword = NSMakeRange(NSNotFound, 0);
        }
        [s appendString:@"@"];
        location++;
    } else {
        internal->_rangeOfUser     = NSMakeRange(NSNotFound, 0);
        internal->_rangeOfPassword = NSMakeRange(NSNotFound, 0);
    }

    if (internal->_host != nil) {
        component = [self percentEncodedHost];
        len = [component length];
        [s appendString:component];
        internal->_rangeOfHost = NSMakeRange(location, len);
        location += len;
    } else {
        internal->_rangeOfHost = NSMakeRange(NSNotFound, 0);
    }

    if (internal->_port != nil) {
        component = [[self port] stringValue];
        len = [component length];
        [s appendString:@":"];
        location++;
        [s appendString:component];
        internal->_rangeOfPort = NSMakeRange(location, len);
        location += len;
    } else {
        internal->_rangeOfPort = NSMakeRange(NSNotFound, 0);
    }

    if (internal->_path != nil) {
        component = [self percentEncodedPath];
        len = [component length];
        [s appendString:component];
        internal->_rangeOfPath = NSMakeRange(location, len);
        location += len;
    } else {
        internal->_rangeOfPath = NSMakeRange(NSNotFound, 0);
    }

    if ([internal->_queryItems count] > 0) {
        component = [self percentEncodedQuery];
        len = [component length];
        [s appendString:@"?"];
        location++;
        [s appendString:component];
        internal->_rangeOfQuery = NSMakeRange(location, len);
        location += len;
    } else {
        internal->_rangeOfQuery = NSMakeRange(NSNotFound, 0);
    }

    if (internal->_fragment != nil) {
        component = [self percentEncodedFragment];
        len = [component length];
        [s appendString:@"#"];
        location++;
        [s appendString:component];
        internal->_rangeOfFragment = NSMakeRange(location, len);
        location += len;
    } else {
        internal->_rangeOfFragment = NSMakeRange(NSNotFound, 0);
    }

    ASSIGNCOPY(internal->_string, s);
    RELEASE(s);
    internal->_dirty = NO;
}

- (NSString *) string
{
    [self _regenerateURL];
    return internal->_string;
}

/** Re-parses urlString and repopulates all components from the resulting NSURL. */
- (void) setString:(NSString *)urlString
{
    if (urlString == nil) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (url != nil) [self setURL:url];
}

/**
 * Returns an NSURL built from the regenerated URL string directly.
 *
 * This avoids the double-encoding bug of the original implementation which went
 * through initWithScheme:user:password:host:port:fullPath:parameterString:query:fragment:,
 * causing already-encoded sequences like %20 to be re-encoded to %2520.
 */
- (NSURL *) URL
{
    NSString *s = [self string];
    return s != nil ? [NSURL URLWithString:s] : nil;
}

/**
 * Populates components from the given NSURL using percent-encoded setters for
 * path and fragment. This prevents double-encoding: NSURL accessors return
 * already-encoded values for path, query, and fragment, and the encoded setters
 * store them correctly by decoding once.
 */
- (void) setURL:(NSURL *)url
{
    [self setScheme:[url scheme]];
    [self setHost:[url host]];
    [self setPort:[url port]];
    [self setUser:[url user]];
    [self setPassword:[url password]];

    // fullPath preserves %2F vs '/'; use the percent-encoded path setter to
    // avoid a second round of encoding.
    NSString *encodedPath = [url fullPath];
    if (encodedPath != nil) {
        [self setPercentEncodedPath:encodedPath];
    } else {
        [self setPath:nil];
    }

    // query and fragment are returned DECODED by NSURL's public accessors;
    // use the private _encodedQuery/_encodedFragment helpers to get the raw
    // percent-encoded form that setPercentEncodedQuery:/setPercentEncodedFragment: expect.
    [self setPercentEncodedQuery:[url _encodedQuery]];
    [self setPercentEncodedFragment:[url _encodedFragment]];
}

- (NSURL *) URLRelativeToURL:(NSURL *)baseURL
{
    return nil;
}

// ---- Decoded component accessors ----

- (NSString *) fragment { return internal->_fragment; }
- (void) setFragment:(NSString *)fragment
{
    ASSIGNCOPY(internal->_fragment, fragment);
    internal->_dirty = YES;
}

- (NSString *) host { return internal->_host; }
- (void) setHost:(NSString *)host
{
    ASSIGNCOPY(internal->_host, host);
    internal->_dirty = YES;
}

- (NSString *) password { return internal->_password; }
- (void) setPassword:(NSString *)password
{
    ASSIGNCOPY(internal->_password, password);
    internal->_dirty = YES;
}

- (NSString *) path { return internal->_path; }
- (void) setPath:(NSString *)path
{
    ASSIGNCOPY(internal->_path, path);
    internal->_dirty = YES;
}

- (NSNumber *) port { return internal->_port; }
- (void) setPort:(NSNumber *)port
{
    ASSIGNCOPY(internal->_port, port);
    internal->_dirty = YES;
}

- (NSString *) query
{
    // Build query string from query items.
    if (internal->_queryItems == nil) return nil;

    NSMutableString *q = nil;
    for (NSURLQueryItem *item in internal->_queryItems) {
        if (q == nil) {
            q = [[NSMutableString alloc] initWithCapacity:64];
        } else {
            [q appendString:@"&"];
        }
        NSString *name  = [item name];
        NSString *value = [item value];
        [q appendString:name];
        if (value != nil) {
            [q appendString:@"="];
            [q appendString:value];
        }
    }
    if (q == nil) return @"";
    return AUTORELEASE([q copy]);
}

- (void) _setQuery:(NSString *)query fromPercentEncodedString:(BOOL)encoded
{
    if (query == nil) { [self setQueryItems:nil]; return; }
    if ([query length] == 0) { [self setQueryItems:[NSArray array]]; return; }

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:8];
    for (NSString *item in [query componentsSeparatedByString:@"&"]) {
        NSString *name, *value;
        if ([item length] == 0) {
            name = @""; value = nil;
        } else {
            NSRange eq = [item rangeOfString:@"="];
            if (eq.length == 0) {
                name = item; value = nil;
            } else {
                name  = [item substringToIndex:eq.location];
                value = [item substringFromIndex:NSMaxRange(eq)];
            }
        }
        if (encoded) {
            name  = [name  stringByRemovingPercentEncoding];
            value = [value stringByRemovingPercentEncoding];
        }
        [result addObject:[NSURLQueryItem queryItemWithName:name value:value]];
    }
    [self setQueryItems:result];
}

- (void) setQuery:(NSString *)query
{
    [self _setQuery:query fromPercentEncodedString:NO];
}

- (NSArray *) queryItems { return AUTORELEASE(RETAIN(internal->_queryItems)); }
- (void) setQueryItems:(NSArray *)queryItems
{
    ASSIGNCOPY(internal->_queryItems, queryItems);
    internal->_dirty = YES;
}

- (NSString *) scheme { return internal->_scheme; }
- (void) setScheme:(NSString *)scheme
{
    ASSIGNCOPY(internal->_scheme, scheme);
    internal->_dirty = YES;
}

- (NSString *) user { return internal->_user; }
- (void) setUser:(NSString *)user
{
    ASSIGNCOPY(internal->_user, user);
    internal->_dirty = YES;
}

// ---- Percent-encoded accessors ----

- (NSString *) percentEncodedFragment
{
    return [internal->_fragment
            stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLFragmentAllowedCharacterSet]];
}

- (void) setPercentEncodedFragment:(NSString *)fragment
{
    [self setFragment:[fragment stringByRemovingPercentEncoding]];
}

- (NSString *) percentEncodedHost
{
    return [internal->_host
            stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLHostAllowedCharacterSet]];
}

- (void) setPercentEncodedHost:(NSString *)host
{
    [self setHost:[host stringByRemovingPercentEncoding]];
}

- (NSString *) percentEncodedPassword
{
    return [internal->_password
            stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPasswordAllowedCharacterSet]];
}

- (void) setPercentEncodedPassword:(NSString *)password
{
    [self setPassword:[password stringByRemovingPercentEncoding]];
}

- (NSString *) percentEncodedPath
{
    return [internal->_path
            stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]];
}

- (void) setPercentEncodedPath:(NSString *)path
{
    [self setPath:[path stringByRemovingPercentEncoding]];
}

- (NSString *) percentEncodedQuery
{
    if (internal->_queryItems == nil) return nil;

    NSMutableString *q = nil;
    for (NSURLQueryItem *item in [self percentEncodedQueryItems]) {
        if (q == nil) {
            q = [[NSMutableString alloc] initWithCapacity:64];
        } else {
            [q appendString:@"&"];
        }
        NSString *name  = [item name];
        NSString *value = [item value];
        [q appendString:name];
        if (value != nil) {
            [q appendString:@"="];
            [q appendString:value];
        }
    }
    if (q == nil) return @"";
    return AUTORELEASE([q copy]);
}

- (void) setPercentEncodedQuery:(NSString *)query
{
    [self _setQuery:query fromPercentEncodedString:YES];
}

- (NSArray *) percentEncodedQueryItems
{
    if (internal->_queryItems == nil) return nil;

    NSMutableArray *items = [NSMutableArray arrayWithCapacity:[internal->_queryItems count]];
    for (NSURLQueryItem *i in internal->_queryItems) {
        NSString *name  = [[i name]  stringByAddingPercentEncodingWithAllowedCharacters:queryItemCharSet];
        NSString *value = [[i value] stringByAddingPercentEncodingWithAllowedCharacters:queryItemCharSet];
        [items addObject:[NSURLQueryItem queryItemWithName:name value:value]];
    }
    return AUTORELEASE([items copy]);
}

- (void) setPercentEncodedQueryItems:(NSArray *)queryItems
{
    NSMutableArray *items = nil;
    if (queryItems != nil) {
        items = [NSMutableArray arrayWithCapacity:[queryItems count]];
        for (NSURLQueryItem *i in queryItems) {
            NSString *name  = [[i name]  stringByRemovingPercentEncoding];
            NSString *value = [[i value] stringByRemovingPercentEncoding];
            [items addObject:[NSURLQueryItem queryItemWithName:name value:value]];
        }
    }
    [self setQueryItems:items];
}

- (NSString *) percentEncodedUser
{
    return [internal->_user
            stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLUserAllowedCharacterSet]];
}

- (void) setPercentEncodedUser:(NSString *)user
{
    [self setUser:[user stringByRemovingPercentEncoding]];
}

// ---- Range accessors ----

- (NSRange) rangeOfFragment  { [self _regenerateURL]; return internal->_rangeOfFragment; }
- (NSRange) rangeOfHost       { [self _regenerateURL]; return internal->_rangeOfHost; }
- (NSRange) rangeOfPassword   { [self _regenerateURL]; return internal->_rangeOfPassword; }
- (NSRange) rangeOfPath       { [self _regenerateURL]; return internal->_rangeOfPath; }
- (NSRange) rangeOfPort       { [self _regenerateURL]; return internal->_rangeOfPort; }
- (NSRange) rangeOfQuery      { [self _regenerateURL]; return internal->_rangeOfQuery; }
- (NSRange) rangeOfScheme     { [self _regenerateURL]; return internal->_rangeOfScheme; }
- (NSRange) rangeOfUser       { [self _regenerateURL]; return internal->_rangeOfUser; }

@end // @implementation NSURLComponents
