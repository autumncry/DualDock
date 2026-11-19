#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import <unistd.h>

static void report(NSString *event) {
    NSString *dir = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FixtureOutputDirectory"];
    NSString *path = [dir stringByAppendingPathComponent:@"events.txt"];
    FILE *fp = fopen(path.fileSystemRepresentation, "a");
    if (fp) { fprintf(fp, "%s\n", event.UTF8String); fclose(fp); }
}
static void quit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}

@interface Driver: NSObject <SPUUserDriver, NSApplicationDelegate, SPUUpdaterDelegate>
@property (strong) SPUUpdater *updater;
@end
@implementation Driver
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    report([NSString stringWithFormat:@"launched %@ %@ %d", version, bundle.bundlePath, getpid()]);
    if (version.integerValue != FIXTURE_BUILD) { report(@"executable-version-mismatch"); quit(); return; }
    if (FIXTURE_BUILD == 2) { report(@"updated-executable-ran"); quit(); return; }
    self.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:self delegate:self];
    NSError *error=nil;
    if (![self.updater startUpdater:&error]) {
        report([NSString stringWithFormat:@"start-error %@ %td %@",error.domain,error.code,error.localizedDescription]); quit(); return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self.updater checkForUpdates]; });
}
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { return NO; }
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { report(@"checking"); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    report([NSString stringWithFormat:@"offered %@",item.versionString]);
    reply([item.versionString isEqual:@"2"] ? SPUUserUpdateChoiceInstall : SPUUserUpdateChoiceDismiss);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack { report(@"not-found"); ack(); quit(); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack {
    report([NSString stringWithFormat:@"error %@ %td %@",error.domain,error.code,error.localizedDescription]);
    BOOL badSignature = [error.domain isEqual:SUSparkleErrorDomain] && (error.code == SUSignatureError || error.code == SUValidationError);
    for (NSError *err = error.userInfo[NSUnderlyingErrorKey]; err != nil; err = err.userInfo[NSUnderlyingErrorKey]) {
        if ([err.domain isEqual:SUSparkleErrorDomain] && (err.code == SUSignatureError || err.code == SUValidationError)) badSignature = YES;
        report([NSString stringWithFormat:@"cause %@ %td %@",err.domain,err.code,err.localizedDescription]);
    }
    if (badSignature) report(@"signature-rejected");
    ack(); quit();
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { report(@"downloading"); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { report(@"extracting"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { report(@"install-confirmed"); reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry { report(@"installing"); }
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { report(@"installed"); ack(); }
- (void)dismissUpdateInstallation {}
@end
int main(int argc,const char **argv) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Driver *delegate = [Driver new];
        app.delegate = delegate; [app run];
        (void)delegate;
    }
    return 0;
}
