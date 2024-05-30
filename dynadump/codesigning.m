//
//  codesigning.c
//  dynadump
//
//

#import "codesigning.h"

#ifndef log_debug
#define log_debug(S, ...)  {fprintf(stdout, "dbg %4d: " S, __LINE__, ##__VA_ARGS__); }
#endif
#ifndef log_error
#define log_error(S, ...)  { fprintf(stderr, "ERR: %s:%5d", __FILE__, __LINE__);} fprintf(stderr, S, ##__VA_ARGS__);
#endif

/*********************************************************************/
# pragma mark - codesigning + private APIs -
/*********************************************************************/

extern const CFStringRef kSecCodeSignerApplicationData;
extern const CFStringRef kSecCodeSignerDetached;
extern const CFStringRef kSecCodeSignerDigestAlgorithm;
extern const CFStringRef kSecCodeSignerDryRun;
extern const CFStringRef kSecCodeSignerEntitlements;
extern const CFStringRef kSecCodeSignerFlags;
extern const CFStringRef kSecCodeSignerIdentifier;
extern const CFStringRef kSecCodeSignerIdentifierPrefix;
extern const CFStringRef kSecCodeSignerIdentity;
extern const CFStringRef kSecCodeSignerPageSize;
extern const CFStringRef kSecCodeSignerRequirements;
extern const CFStringRef kSecCodeSignerResourceRules;
extern const CFStringRef kSecCodeSignerSDKRoot;
extern const CFStringRef kSecCodeSignerSigningTime;
extern const CFStringRef kSecCodeSignerTimestampAuthentication;
extern const CFStringRef kSecCodeSignerRequireTimestamp;
extern const CFStringRef kSecCodeSignerTimestampServer;
extern const CFStringRef kSecCodeSignerTimestampOmitCertificates;
extern const CFStringRef kSecCodeSignerPreserveMetadata;
extern const CFStringRef kSecCodeSignerTeamIdentifier;
extern const CFStringRef kSecCodeSignerPlatformIdentifier;
extern const CFStringRef kSecCodeSignerRuntimeVersion;
extern const CFStringRef kSecCodeSignerPreserveAFSC;

enum {
    kSecCodeSignerPreserveIdentifier = 1 << 0,        // preserve signing identifier
    kSecCodeSignerPreserveRequirements = 1 << 1,    // preserve internal requirements (including DR)
    kSecCodeSignerPreserveEntitlements = 1 << 2,    // preserve entitlements
    kSecCodeSignerPreserveResourceRules = 1 << 3,    // preserve resource rules (and thus resources)
    kSecCodeSignerPreserveFlags = 1 << 4,            // preserve signing flags
    kSecCodeSignerPreserveTeamIdentifier = 1 << 5,  // preserve team identifier flags
    kSecCodeSignerPreserveDigestAlgorithm = 1 << 6, // preserve digest algorithms used
    kSecCodeSignerPreservePEH = 1 << 7,                // preserve pre-encryption hashes
    kSecCodeSignerPreserveRuntime = 1 << 8,        // preserve the runtime version
};

enum {
    kSecCSRemoveSignature = 1 << 0,        // strip existing signature
    kSecCSSignPreserveSignature = 1 << 1, // do not (re)sign if an embedded signature is already present
    kSecCSSignNestedCode = 1 << 2,        // recursive (deep) signing
    kSecCSSignOpaque = 1 << 3,            // treat all files as resources (no nest scan, no flexibility)
    kSecCSSignV1 = 1 << 4,                // sign ONLY in V1 form
    kSecCSSignNoV1 = 1 << 5,            // do not include V1 form
    kSecCSSignBundleRoot = 1 << 6,        // include files in bundle root
    kSecCSSignStrictPreflight = 1 << 7, // fail signing operation if signature would fail strict validation
    kSecCSSignGeneratePEH = 1 << 8,        // generate pre-encryption hashes
    kSecCSSignGenerateEntitlementDER = 1 << 9, // generate entitlement DER
    kSecCSEditSignature = 1 << 10,      // edit existing signature
    kSecCSSingleThreadedSigning = 1 << 11, // disable concurrency when building the resource seal
};

typedef struct __SecCodeSigner *SecCodeSignerRef;

// Get around private imports for iOS which don't seem to have these in the sdk
#ifndef _H_CSCOMMON
typedef uint32_t SecCSFlags;
typedef struct SecStaticCode *SecStaticCodeRef;
#endif

__attribute__((weak))
OSStatus SecCodeSignerCreate(CFDictionaryRef parameters, SecCSFlags flags,
    SecCodeSignerRef *signer);

__attribute__((weak))
OSStatus SecCodeSignerAddSignature(SecCodeSignerRef signer,
    SecStaticCodeRef code, SecCSFlags flags);
    
__attribute__((weak))
OSStatus SecCodeSignerAddSignatureWithErrors(SecCodeSignerRef signer,
    SecStaticCodeRef code, SecCSFlags flags, CFErrorRef *errors);

__attribute__((weak))
extern OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path, SecCSFlags flags, CFDictionaryRef attributes,
    SecStaticCodeRef * __nonnull CF_RETURNS_RETAINED staticCode);


/*********************************************************************/
# pragma mark - public -
/*********************************************************************/

int ad_hoc_codesign_file(const char *path) {
    NSDictionary *dict = @{ @"signer" :  [NSNull null]};
    SecCodeSignerRef ref = NULL;
    if (!SecCodeSignerCreate || !SecCodeSignerAddSignature || !SecCodeSignerAddSignatureWithErrors) {
        log_error("SDK doesn't support the required APIs, are you on iOS 15+/macOS 10.5+?\n")
        return -1;
    }
    
    OSStatus status = SecCodeSignerCreate((__bridge CFDictionaryRef)(dict),  /*kSecCSDefaultFlags*/ 0, &ref);
    if (status) {
        log_error("SecCodeSignerCreate error: %d\n", status);
        return -1;
    }
    
    NSString *pathStr = [NSString stringWithCString:path encoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL fileURLWithPath:pathStr];
    SecStaticCodeRef staticCodeRef = nil;

    status = SecStaticCodeCreateWithPathAndAttributes((__bridge CFURLRef _Nonnull)(url), 0, (__bridge CFDictionaryRef _Nonnull)@{}, &staticCodeRef);
    if (status) {
        log_error("SecStaticCodeCreateWithPathAndAttributes error: %d\n", status);
        return -1;
    }
    
    CFErrorRef error = NULL;
    status = SecCodeSignerAddSignatureWithErrors(ref, staticCodeRef, /*kSecCSDefaultFlags*/ 0, &error);
    if (status || error) {
        log_error("SecCodeSignerAddSignatureWithErrors error: %d\n", status);
        return -1;
    }
    
    log_debug("we appeared to have codesigned \'%s\' correctly...\n", path);
    /*
        NSDictionary *verifyDict = nil;
        CFDictionaryRef omg = (__bridge CFDictionaryRef)verifyDict;
        status = SecCodeCopySigningInformation(staticCodeRef , kSecCSDynamicInformation | kSecCSSigningInformation | kSecCSRequirementInformation | kSecCSInternalInformation, &omg);
     */
    
    
    return 0;
}
