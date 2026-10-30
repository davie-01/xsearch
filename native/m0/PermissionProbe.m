#import <Foundation/Foundation.h>
#import <unistd.h>

@protocol XSProbeProtocol
- (void)readPath:(NSString *)path reply:(void (^)(NSDictionary *))reply;
@end

static NSDictionary *readProbe(NSString *path) {
    NSError *error=nil;
    NSFileHandle *handle=[NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:&error];
    if (!handle) return @{ @"read":@NO, @"error":error.localizedDescription ?: @"unknown" };
    NSData *prefix=[handle readDataOfLength:16];[handle closeFile];
    return @{ @"read":@YES, @"prefixBytes":@(prefix.length), @"pid":@(getpid()) };
}
static void writeResult(NSDictionary *result) {
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);fflush(stdout);
}

@interface XSProbe : NSObject <XSProbeProtocol,NSXPCListenerDelegate>
@end
@implementation XSProbe
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(XSProbeProtocol)];
    connection.exportedObject=self;[connection resume];return YES;
}
- (void)readPath:(NSString *)path reply:(void (^)(NSDictionary *))reply {
    NSMutableDictionary *result=[readProbe(path) mutableCopy];
    NSURL *helper=[[NSBundle mainBundle] URLForAuxiliaryExecutable:@"FileChild"];
    NSTask *task=[NSTask new];task.executableURL=helper;task.arguments=@[path];
    NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=[NSFileHandle fileHandleWithNullDevice];
    NSError *error=nil;
    if([task launchAndReturnError:&error]) {
        NSData *data=[pipe.fileHandleForReading readDataToEndOfFile];[task waitUntilExit];
        result[@"child"]=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] ?: @{ @"read":@NO };
    } else result[@"child"]=@{@"read":@NO,@"error":error.localizedDescription ?: @"launch failed"};
    reply(result);
}
@end

int main(int argc,const char **argv) { @autoreleasepool {
#if defined(XS_CHILD)
    if(argc<2)return 2;writeResult(readProbe(@(argv[1])));return 0;
#elif defined(XS_SERVICE)
    XSProbe *delegate=[XSProbe new];NSXPCListener *listener=[NSXPCListener serviceListener];listener.delegate=delegate;[listener resume];return 0;
#else
    if(argc<2)return 2;
    NSString *path=@(argv[1]);NSMutableDictionary *result=[@{@"app":readProbe(path)} mutableCopy];
    __block BOOL done=NO;
    NSXPCConnection *connection=[[NSXPCConnection alloc] initWithServiceName:@"org.xsearch.m0.ExtractionProbe"];
    connection.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(XSProbeProtocol)];
    [connection resume];
    id<XSProbeProtocol> service=[connection remoteObjectProxyWithErrorHandler:^(NSError *error){result[@"xpc_error"]=error.description;done=YES;}];
    [service readPath:path reply:^(NSDictionary *response){result[@"xpc"]=response;done=YES;}];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:15];
    while(!done && [end timeIntervalSinceNow]>0){[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];}
    if(!done)result[@"timeout"]=@YES;
    [connection invalidate];writeResult(result);
    return [result[@"xpc"][@"read"] boolValue] && [result[@"xpc"][@"child"][@"read"] boolValue] ? 0 : 1;
#endif
} }

