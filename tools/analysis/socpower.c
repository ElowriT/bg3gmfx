// SoC power by subsystem from the IOReport "Energy Model" counters (no root,
// unlike powermetrics). usage: socpower [seconds] [samples] [--json]
// Build: clang -fblocks -O2 tools/analysis/socpower.c -framework CoreFoundation -o build/bin/socpower
//
// Whole-machine figures, like powermetrics: CPU ("CPU Energy", cores and
// clusters), GPU ("GPU Energy"), DRAM, the memory controller and fabric (AMCC,
// DCS, FAB), the display engines (DISP internal, DISPEXT external) and the rest
// (ANE, video, ISP and other small blocks). Per-core channels and GPU0, which
// overlap the totals, are left out. The millijoule counters (all but the GPU)
// advance about every 2 s, so use intervals of 2 s or more, or the run's mean.
// libIOReport is private API, loaded at run time; channel names were checked on
// an M5 Pro (macOS 27).
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef CFDictionaryRef (*CopyChannels)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void *(*CreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamples)(void *, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int (*Iterate)(CFDictionaryRef, int (^)(CFDictionaryRef));
typedef CFStringRef (*ChannelString)(CFDictionaryRef);
typedef int64_t (*IntegerValue)(CFDictionaryRef, int32_t);

enum { CPU, GPU, DRAM, MEMORY, DISPLAY, OTHER, PARTS };
static const char *labels[PARTS] = {"cpu", "gpu", "dram", "memory+fabric", "display", "other"};

static int part(const char *name) {
    if (!strcmp(name, "CPU Energy")) return CPU;
    if (!strcmp(name, "GPU Energy")) return GPU;
    if (!strncmp(name, "DRAM", 4)) return DRAM;
    if (!strncmp(name, "AMCC", 4) || !strncmp(name, "DCS", 3) || !strncmp(name, "FAB", 3)) return MEMORY;
    if (!strncmp(name, "DISP", 4)) return DISPLAY;
    if (!strncmp(name, "ANE", 3) || !strncmp(name, "AVE", 3) || !strncmp(name, "ISP", 3) ||
        !strncmp(name, "AFR", 3) || !strncmp(name, "MSR", 3)) return OTHER;
    return -1;  // per-core and per-cluster detail, GPU0, PCIe
}

static double joules(int64_t value, const char *unit) {
    if (!strcmp(unit, "nJ")) return value * 1e-9;
    if (!strcmp(unit, "uJ")) return value * 1e-6;
    if (!strcmp(unit, "mJ")) return value * 1e-3;
    return 0;
}

int main(int argc, char **argv) {
    double seconds = 2; int samples = 1, json = 0, positional = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (positional++ == 0) seconds = atof(argv[i]);
        else samples = atoi(argv[i]);
    }
    if (seconds <= 0 || samples <= 0) { fprintf(stderr, "usage: socpower [seconds] [samples] [--json]\n"); return 2; }
    void *library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    CopyChannels copy = library ? (CopyChannels)dlsym(library, "IOReportCopyChannelsInGroup") : NULL;
    CreateSubscription subscribe = library ? (CreateSubscription)dlsym(library, "IOReportCreateSubscription") : NULL;
    CreateSamples sample = library ? (CreateSamples)dlsym(library, "IOReportCreateSamples") : NULL;
    CreateDelta delta = library ? (CreateDelta)dlsym(library, "IOReportCreateSamplesDelta") : NULL;
    Iterate iterate = library ? (Iterate)dlsym(library, "IOReportIterate") : NULL;
    ChannelString name = library ? (ChannelString)dlsym(library, "IOReportChannelGetChannelName") : NULL;
    ChannelString unit = library ? (ChannelString)dlsym(library, "IOReportChannelGetUnitLabel") : NULL;
    IntegerValue value = library ? (IntegerValue)dlsym(library, "IOReportSimpleGetIntegerValue") : NULL;
    if (!copy || !subscribe || !sample || !delta || !iterate || !name || !unit || !value) {
        fprintf(stderr, "socpower: IOReport is unavailable\n"); return 1;
    }
    CFDictionaryRef channels = copy(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) { fprintf(stderr, "socpower: no Energy Model channels\n"); return 1; }
    CFMutableDictionaryRef wanted = CFDictionaryCreateMutableCopy(NULL, 0, channels), subscribed = NULL;
    void *subscription = subscribe(NULL, wanted, &subscribed, 0, NULL);
    if (!subscription) { fprintf(stderr, "socpower: subscription failed\n"); return 1; }
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    double total[PARTS] = {0}, wall = 0;
    CFDictionaryRef before = sample(subscription, subscribed, NULL);
    uint64_t start = mach_absolute_time();
    for (int n = 0; n < samples; ++n) {
        usleep((useconds_t)(seconds * 1e6));
        CFDictionaryRef after = sample(subscription, subscribed, NULL);
        uint64_t now = mach_absolute_time();
        double span = (now - start) * (double)timebase.numer / timebase.denom * 1e-9;
        double energy[PARTS] = {0}, *sums = energy;  // blocks cannot capture arrays
        CFDictionaryRef change = delta(before, after, NULL);
        iterate(change, ^int(CFDictionaryRef channel) {
            char channelName[128] = "", unitName[16] = "";
            CFStringRef channelString = name(channel), unitString = unit(channel);
            if (channelString) CFStringGetCString(channelString, channelName, sizeof channelName, kCFStringEncodingUTF8);
            if (unitString) CFStringGetCString(unitString, unitName, sizeof unitName, kCFStringEncodingUTF8);
            int which = part(channelName);
            if (which >= 0) sums[which] += joules(value(channel, 0), unitName);
            return 0;
        });
        CFRelease(change); CFRelease(before);
        before = after; start = now; wall += span;
        double sum = 0;
        for (int p = 0; p < PARTS; ++p) { total[p] += energy[p]; sum += energy[p]; }
        if (json) {
            printf("{\"seconds\":%.3f", span);
            for (int p = 0; p < PARTS; ++p) printf(",\"%s\":%.3f", labels[p], energy[p] / span);
            printf(",\"total\":%.3f}\n", sum / span);
        } else {
            for (int p = 0; p < PARTS; ++p) printf("%s %5.2f W  ", labels[p], energy[p] / span);
            printf("total %5.2f W\n", sum / span);
        }
        fflush(stdout);
    }
    if (samples > 1 && !json) {
        double sum = 0;
        printf("mean over %.0f s: ", wall);
        for (int p = 0; p < PARTS; ++p) { printf("%s %.2f W  ", labels[p], total[p] / wall); sum += total[p]; }
        printf("total %.2f W\n", sum / wall);
    }
    return 0;
}
