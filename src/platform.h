#ifndef PLATFORM_H
#define PLATFORM_H

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#define EE_IOS 1
#endif
#endif

// Touch-first platforms: no OS pointer to emulate, a system on-screen keyboard,
// and no access to recording hardware without a scary permission prompt.
#if defined(ANDROID) || defined(__ANDROID__) || defined(EE_IOS)
#define EE_MOBILE 1
#endif

#endif//PLATFORM_H
