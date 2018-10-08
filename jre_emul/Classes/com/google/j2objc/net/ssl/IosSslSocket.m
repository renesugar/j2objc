// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "com/google/j2objc/net/ssl/IosSslSocket.h"

#import <Security/Security.h>

#import "J2ObjC_source.h"
#import "java/io/InputStream.h"
#import "java/io/OutputStream.h"
#import "java/lang/Exception.h"
#import "java/lang/UnsupportedOperationException.h"
#import "java/net/InetAddress.h"
#import "java/net/SocketException.h"
#import "java/io/IOException.h"
#import "jni_util.h"

@class SslInputStream;
@class SslOutputStream;
static OSStatus SslReadCallback(SSLConnectionRef connection, void *data, size_t *dataLength);
static OSStatus SslWriteCallback(SSLConnectionRef connection, const void *data, size_t *dataLength);
static void checkStatus(OSStatus status);
static void setUpContext(ComGoogleJ2objcNetSslIosSslSocket *self);
static void tearDownContext(ComGoogleJ2objcNetSslIosSslSocket *self);

// The users of this class perform I/O via the two stream specializations: SslInputStream and
// SslOutputStream. The actual network I/O operations are perfomed by the inherited java streams.
// Expected data flow:
//
// - Read: SslInputStream.read --> SSLRead --> SslReadCallback --> JavaIoInputStream.read
// - Write: SslOutputStream.write --> SSLWrite --> SslWriteCallback --> JavaIoOutputStream.write
@interface ComGoogleJ2objcNetSslIosSslSocket() {
@public
  SSLContextRef _sslContext;
  SslInputStream *_sslInputStream;
  SslOutputStream *_sslOutputStream;
  BOOL handshakeCompleted;

  // Used to forward exceptions from the plain streams to the SSL streams.
  JavaLangException *_sslException;
}
- (JavaIoInputStream *)plainInputStream;
- (JavaIoOutputStream *)plainOutputStream;
@end

// An input stream that uses Apple's SSLRead.
@interface SslInputStream : JavaIoInputStream {
  ComGoogleJ2objcNetSslIosSslSocket *_socket;
}
- (instancetype)initWithSocket:(ComGoogleJ2objcNetSslIosSslSocket *)socket;
@end

@implementation SslInputStream

- (instancetype)initWithSocket:(ComGoogleJ2objcNetSslIosSslSocket *)socket {
  if (self = [super init]) {
    _socket = socket;
  }
  return self;
}

- (jint)readWithByteArray:(IOSByteArray *)b
                  withInt:(jint)off
                  withInt:(jint)len {
  size_t processed = 0;
  OSStatus status;

  [_socket startHandshake];
  @synchronized (_socket) {
    do {
      size_t temp;
      status = SSLRead(_socket->_sslContext, b->buffer_ + off, len, &temp);
      off += temp;
      len -= temp;
      processed += temp;
      // if less data than requested was actually transferred then, keep calling SSLRead until
      // something different from errSSLWouldBlock is returned.
    } while (status == errSSLWouldBlock);
  }

  if (status == errSSLClosedGraceful || status == errSSLClosedAbort) {
    processed = -1;
  } else {
    checkStatus(status);
  }
  if (_socket->_sslException) {
    @throw _socket->_sslException;
  }
  return (jint)processed;
}

- (jint)read {
  IOSByteArray *b = [IOSByteArray arrayWithLength:1];
  jint processed = [self readWithByteArray:b];
  if (processed == 1) {
    return b->buffer_[0];
  }
  return processed;
}

- (jlong)skipWithLong:(jlong)n {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

@end

// An output stream that uses Apple's SSLWrite.
@interface SslOutputStream : JavaIoOutputStream {
  ComGoogleJ2objcNetSslIosSslSocket *_socket;
}
- (instancetype)initWithSocket:(ComGoogleJ2objcNetSslIosSslSocket *)socket;
@end

@implementation SslOutputStream

- (instancetype)initWithSocket:(ComGoogleJ2objcNetSslIosSslSocket *)socket {
  if (self = [super init]) {
    _socket = socket;
  }
  return self;
}

- (void)writeWithByteArray:(IOSByteArray *)b
                   withInt:(jint)off
                   withInt:(jint)len {
  OSStatus status;
  size_t processed = 0;

  [_socket startHandshake];
  while (len > 0) {
    @synchronized (_socket) {
      status = SSLWrite(_socket->_sslContext, b->buffer_ + off, len, &processed);
    }
    if (status == errSecSuccess || status == errSSLWouldBlock) {
      off += processed;
      len -= processed;
    } else if (_socket->_sslException) {
      @throw _socket->_sslException;
    } else {
      checkStatus(status);
    }
  }
}

- (void)writeWithInt:(jint)b {
  IOSByteArray *array = [IOSByteArray arrayWithLength:1];
  array->buffer_[0] = b;
  [self writeWithByteArray:array];
}

- (void)flush {
  // The framework keeps SSL caches for reading and writing. Whenever a call to SSLWrite returns
  // errSSLWouldBlock, the data has been copied to the cache, but not yet (completely) sent.
  // In order to flush this cache, we have to call SSLWrite on an empty buffer.
  OSStatus status;
  size_t processed = 0;
  @synchronized (_socket) {
    do {
      status = SSLWrite(_socket->_sslContext, nil, 0, &processed);
    } while (status == errSSLWouldBlock);
  }
  [[_socket plainOutputStream] flush];
}

@end


@implementation ComGoogleJ2objcNetSslIosSslSocket

- (JavaIoInputStream *)plainInputStream {
  return [super getInputStream];
}

- (JavaIoOutputStream *)plainOutputStream {
  return [super getOutputStream];
}

- (void)dealloc {
  tearDownContext(self);
  [_sslInputStream release];
  [_sslOutputStream release];
  [_sslException release];
  [super dealloc];
}

#pragma mark JavaNetSocket methods

- (void)close {
  @synchronized(self) {
    if ([self isClosed]) return;
    tearDownContext(self);
    [super close];
  }
}

- (JavaIoInputStream *)getInputStream {
  return JreRetainedLocalValue(_sslInputStream);
}

- (JavaIoOutputStream *)getOutputStream {
  return JreRetainedLocalValue(_sslOutputStream);
}

#pragma mark JavaNetSSlSocket methods

- (IOSObjectArray *)getSupportedCipherSuites {
  return [IOSObjectArray arrayWithLength:0 type:NSString_class_()];
}

- (IOSObjectArray *)getEnabledCipherSuites {
  return [IOSObjectArray arrayWithLength:0 type:NSString_class_()];
}

- (void)setEnabledCipherSuitesWithNSStringArray:(IOSObjectArray *)suites {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (IOSObjectArray *)getSupportedProtocols {
  return [IOSObjectArray arrayWithLength:0 type:NSString_class_()];
}

- (IOSObjectArray *)getEnabledProtocols {
  return [IOSObjectArray arrayWithLength:0 type:NSString_class_()];
}

- (void)setEnabledProtocolsWithNSStringArray:(IOSObjectArray *)protocols {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (id<JavaxNetSslSSLSession>)getSession {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (void)addHandshakeCompletedListenerWithJavaxNetSslHandshakeCompletedListener:
    (id<JavaxNetSslHandshakeCompletedListener>)listener {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (void)removeHandshakeCompletedListenerWithJavaxNetSslHandshakeCompletedListener:
    (id<JavaxNetSslHandshakeCompletedListener>)listener {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (void)startHandshake {
  @synchronized(self) {
    if (!handshakeCompleted) {
      setUpContext(self);
      OSStatus status;
      do {
        status = SSLHandshake(_sslContext);
      } while (status == errSSLWouldBlock);
      checkStatus(status);
      handshakeCompleted = TRUE;
    }
  }
}

- (void)setUseClientModeWithBoolean:(jboolean)mode {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (jboolean)getUseClientMode {
  return TRUE;  // Currently only client mode is supported.
}

- (void)setNeedClientAuthWithBoolean:(jboolean)need {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (jboolean)getNeedClientAuth {
  return FALSE;
}

- (void)setWantClientAuthWithBoolean:(jboolean)want {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (jboolean)getWantClientAuth {
  return FALSE;
}

- (void)setEnableSessionCreationWithBoolean:(jboolean)flag {
  J2ObjCThrowByName(JavaLangUnsupportedOperationException, @"");
}

- (jboolean)getEnableSessionCreation {
  return FALSE;
}

@end

static OSStatus SslReadCallback(SSLConnectionRef connection, void *data, size_t *dataLength) {
  ComGoogleJ2objcNetSslIosSslSocket *socket = (ComGoogleJ2objcNetSslIosSslSocket *) connection;
  IOSByteArray *array = [IOSByteArray arrayWithLength:*dataLength];
  jint processed;
  @try {
    processed = [[socket plainInputStream] readWithByteArray:array];
  } @catch (JavaIoIOException *e) {
    JreStrongAssign(&socket->_sslException, e);
    return errSSLInternal;
  }

  if (processed  < 0) {
    *dataLength = 0;
    return errSSLClosedGraceful;
  }

  OSStatus status = processed < *dataLength ? errSSLWouldBlock : errSecSuccess;
  if (processed > 0) {
    [array getBytes:(jbyte *)data length:processed];
  }
  *dataLength = processed;
  return status;
}

static OSStatus SslWriteCallback(SSLConnectionRef connection,
                                 const void *data,
                                 size_t *dataLength) {
  ComGoogleJ2objcNetSslIosSslSocket *socket = (ComGoogleJ2objcNetSslIosSslSocket *) connection;
  IOSByteArray *array = [IOSByteArray arrayWithBytes:(const jbyte *)data count:*dataLength];
  @try {
    [[socket plainOutputStream] writeWithByteArray:array];
    [[socket plainOutputStream] flush];
  } @catch (JavaIoIOException *e) {
    JreStrongAssign(&socket->_sslException, e);
    return errSSLInternal;
  }
  return errSecSuccess;
}

static void checkStatus(OSStatus status) {
  if (status != errSecSuccess) {
    NSString *msg = [NSString stringWithFormat:@"status: %d", (int)status];
    J2ObjCThrowByName(JavaNetSocketException, msg);
  }
}

static void init(ComGoogleJ2objcNetSslIosSslSocket *self) {
  self->_sslInputStream = [[SslInputStream alloc] initWithSocket:self];
  self->_sslOutputStream = [[SslOutputStream alloc] initWithSocket:self];
  self->_sslException = nil;
}

static void setUpContext(ComGoogleJ2objcNetSslIosSslSocket *self) {
  self->_sslContext = SSLCreateContext(nil, kSSLClientSide, kSSLStreamType);
  checkStatus(SSLSetIOFuncs(self->_sslContext, SslReadCallback, SslWriteCallback));
  checkStatus(SSLSetConnection(self->_sslContext, self));
  NSString *hostName = [[self getInetAddress] getHostName];
  checkStatus(SSLSetPeerDomainName(self->_sslContext, [hostName UTF8String], [hostName length]));
}

static void tearDownContext(ComGoogleJ2objcNetSslIosSslSocket *self) {
  if (self->_sslContext) {
    checkStatus(SSLClose(self->_sslContext));
    CFRelease(self->_sslContext);
    self->_sslContext = nil;
  }
}

// public IosSslSocket()
void ComGoogleJ2objcNetSslIosSslSocket_init(ComGoogleJ2objcNetSslIosSslSocket *self) {
  JavaxNetSslSSLSocket_init(self);
  init(self);
}

ComGoogleJ2objcNetSslIosSslSocket *new_ComGoogleJ2objcNetSslIosSslSocket_init(void) {
  J2OBJC_NEW_IMPL(ComGoogleJ2objcNetSslIosSslSocket, init)
}

ComGoogleJ2objcNetSslIosSslSocket *create_ComGoogleJ2objcNetSslIosSslSocket_init(void) {
  J2OBJC_CREATE_IMPL(ComGoogleJ2objcNetSslIosSslSocket, init)
}

// public IosSslSocket(String host, int port)
void ComGoogleJ2objcNetSslIosSslSocket_initWithNSString_withInt_(
    ComGoogleJ2objcNetSslIosSslSocket *self, NSString *host, jint port) {
  JavaxNetSslSSLSocket_initWithNSString_withInt_(self, host, port);
  init(self);
}

ComGoogleJ2objcNetSslIosSslSocket *
    new_ComGoogleJ2objcNetSslIosSslSocket_initWithNSString_withInt_(NSString *host, jint port) {
  J2OBJC_NEW_IMPL(ComGoogleJ2objcNetSslIosSslSocket, initWithNSString_withInt_, host, port)
}

ComGoogleJ2objcNetSslIosSslSocket *
    create_ComGoogleJ2objcNetSslIosSslSocket_initWithNSString_withInt_(NSString *host, jint port) {
  J2OBJC_CREATE_IMPL(ComGoogleJ2objcNetSslIosSslSocket, initWithNSString_withInt_, host, port)
}

// public IosSslSocket(String host, int port, InetAddress localAddr, int localPort)
void ComGoogleJ2objcNetSslIosSslSocket_initWithNSString_withInt_withJavaNetInetAddress_withInt_(
    ComGoogleJ2objcNetSslIosSslSocket *self, NSString *host, jint port,
    JavaNetInetAddress *localAddr, jint localPort) {
  JavaxNetSslSSLSocket_initWithNSString_withInt_withJavaNetInetAddress_withInt_(
      self, host, port, localAddr, localPort);
  init(self);
}

ComGoogleJ2objcNetSslIosSslSocket *
new_ComGoogleJ2objcNetSslIosSslSocket_initWithNSString_withInt_withJavaNetInetAddress_withInt_(
    NSString *host, jint port, JavaNetInetAddress *localAddr, jint localPort) {
  J2OBJC_NEW_IMPL(ComGoogleJ2objcNetSslIosSslSocket,
                  initWithNSString_withInt_withJavaNetInetAddress_withInt_, host, port, localAddr,
                  localPort)
}

ComGoogleJ2objcNetSslIosSslSocket *
create_ComGoogleJ2objcNetSslIosSslSocket_initWithNSString_withInt_withJavaNetInetAddress_withInt_(
    NSString *host, jint port, JavaNetInetAddress *localAddr, jint localPort) {
  J2OBJC_CREATE_IMPL(ComGoogleJ2objcNetSslIosSslSocket,
                     initWithNSString_withInt_withJavaNetInetAddress_withInt_, host, port,
                     localAddr, localPort)
}

// public IosSslSocket(InetAddress host, int port)
void ComGoogleJ2objcNetSslIosSslSocket_initWithJavaNetInetAddress_withInt_(
    ComGoogleJ2objcNetSslIosSslSocket *self, JavaNetInetAddress *address, jint port) {
  JavaxNetSslSSLSocket_initWithJavaNetInetAddress_withInt_(self, address, port);
  init(self);
}

ComGoogleJ2objcNetSslIosSslSocket *
new_ComGoogleJ2objcNetSslIosSslSocket_initWithJavaNetInetAddress_withInt_(
    JavaNetInetAddress *address, jint port) {
  J2OBJC_NEW_IMPL(ComGoogleJ2objcNetSslIosSslSocket, initWithJavaNetInetAddress_withInt_, address,
                  port)
}

ComGoogleJ2objcNetSslIosSslSocket *
create_ComGoogleJ2objcNetSslIosSslSocket_initWithJavaNetInetAddress_withInt_(
    JavaNetInetAddress *address, jint port) {
  J2OBJC_CREATE_IMPL(ComGoogleJ2objcNetSslIosSslSocket, initWithJavaNetInetAddress_withInt_,
                     address, port)
}

// public IosSslSocket(InetAddress address, int port, InetAddress localAddr, int localPort)
// NOLINTNEXTLINE
void ComGoogleJ2objcNetSslIosSslSocket_initWithJavaNetInetAddress_withInt_withJavaNetInetAddress_withInt_(
    ComGoogleJ2objcNetSslIosSslSocket *self, JavaNetInetAddress *address, jint port,
    JavaNetInetAddress *localAddr, jint localPort) {
  JavaxNetSslSSLSocket_initWithJavaNetInetAddress_withInt_withJavaNetInetAddress_withInt_(
      self, address, port, localAddr, localPort);
  init(self);
}

// NOLINTNEXTLINE
ComGoogleJ2objcNetSslIosSslSocket *new_ComGoogleJ2objcNetSslIosSslSocket_initWithJavaNetInetAddress_withInt_withJavaNetInetAddress_withInt_(
    JavaNetInetAddress *address, jint port, JavaNetInetAddress *localAddr, jint localPort) {
  J2OBJC_NEW_IMPL(ComGoogleJ2objcNetSslIosSslSocket,
                  initWithJavaNetInetAddress_withInt_withJavaNetInetAddress_withInt_, address, port,
                  localAddr, localPort)
}

// NOLINTNEXTLINE
ComGoogleJ2objcNetSslIosSslSocket *create_ComGoogleJ2objcNetSslIosSslSocket_initWithJavaNetInetAddress_withInt_withJavaNetInetAddress_withInt_(
    JavaNetInetAddress *address, jint port, JavaNetInetAddress *localAddr, jint localPort) {
  J2OBJC_CREATE_IMPL(ComGoogleJ2objcNetSslIosSslSocket,
                     initWithJavaNetInetAddress_withInt_withJavaNetInetAddress_withInt_, address,
                     port, localAddr, localPort)
}

J2OBJC_CLASS_TYPE_LITERAL_SOURCE(ComGoogleJ2objcNetSslIosSslSocket)