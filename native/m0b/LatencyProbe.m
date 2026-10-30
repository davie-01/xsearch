#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <unistd.h>
@protocol XSLatencyProtocol
- (void)echo:(NSData *)data reply:(void (^)(NSData *, int))reply;
@end
@interface XSLatency : NSObject <XSLatencyProtocol,NSXPCListenerDelegate>
@end
@implementation XSLatency
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(XSLatencyProtocol)];
    connection.exportedObject=self;[connection resume];return YES;
}
- (void)echo:(NSData *)data reply:(void (^)(NSData *, int))reply {reply(data,getpid());}
@end
static double micros(uint64_t start) {mach_timebase_info_data_t info;mach_timebase_info(&info);return (mach_continuous_time()-start)*(double)info.numer/info.denom/1000.;}
static NSDictionary *summary(NSArray<NSNumber *> *values) {
    NSArray *sorted=[values sortedArrayUsingSelector:@selector(compare:)];NSUInteger n=sorted.count;
    return @{ @"count":@(n),@"p50_us":sorted[(n-1)/2],@"p95_us":sorted[(NSUInteger)ceil(n*.95)-1],@"p99_us":sorted[(NSUInteger)ceil(n*.99)-1] };
}
int main(int argc,const char **argv) { @autoreleasepool {
#ifdef XS_SERVICE
    XSLatency *delegate=[XSLatency new];NSXPCListener *listener=[NSXPCListener serviceListener];listener.delegate=delegate;[listener resume];return 0;
#else
    NSMutableArray *rows=[NSMutableArray array];NSMutableArray *connections=[NSMutableArray array];__block NSString *errorText=nil;
    for(int round=0;round<3 && !errorText;round++) {
        uint64_t started=mach_continuous_time();
        NSXPCConnection *connection=[[NSXPCConnection alloc] initWithServiceName:@"org.xsearch.m0b.LatencyService"];
        connection.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(XSLatencyProtocol)];[connection resume];double setup=micros(started);
        NSArray *sizes=round%2 ? @[@65536,@4096,@64,@0] : @[@0,@64,@4096,@65536];
        __block int servicePID=0;__block double first=0;
        for(NSNumber *size in sizes) {
            NSMutableData *payload=[NSMutableData dataWithLength:size.unsignedIntegerValue];uint8_t *bytes=payload.mutableBytes;
            for(NSUInteger b=0;b<payload.length;b++)bytes[b]=(uint8_t)(b*31);
            NSMutableArray *samples=[NSMutableArray array];
            for(int i=-20;i<500 && !errorText;i++) { @autoreleasepool {
                dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);__block NSData *received=nil;
                uint64_t begin=mach_continuous_time();__block double elapsed=0;
                id<XSLatencyProtocol> proxy=[connection remoteObjectProxyWithErrorHandler:^(NSError *error){errorText=error.description;dispatch_semaphore_signal(semaphore);}];
                [proxy echo:payload reply:^(NSData *response,int pid){elapsed=micros(begin);received=response;servicePID=pid;dispatch_semaphore_signal(semaphore);}];
                if(dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))!=0)errorText=@"XPC response timed out";
                if(!errorText && ![received isEqualToData:payload])errorText=@"echo payload mismatch";
                if(first==0)first=elapsed;
                if(i>=0 && !errorText)[samples addObject:@(elapsed)];
            }}
            if(errorText)break;
            [rows addObject:@{@"round":@(round),@"payload_bytes":size,@"xpc":summary(samples)}];
        }
        [connections addObject:@{@"round":@(round),@"setup_us":@(setup),@"first_roundtrip_us":@(first),@"service_pid":@(servicePID)}];
        [connection invalidate];
    }
    NSDictionary *result=errorText ? @{ @"status":@"failed",@"error":errorText } : @{ @"status":@"passed",@"rows":rows,@"connections":connections,@"client_pid":@(getpid()),@"timer":@"mach_continuous_time; callback arrival; no run-loop polling delay" };
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    if(argc>1){[json writeToFile:@(argv[1]) atomically:YES];}
    fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return errorText?1:0;
#endif
}}
