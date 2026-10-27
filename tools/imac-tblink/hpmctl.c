// hpmctl: inspect / reset the iMac USB-C PD controllers via AppleHPMLib (needs root).
//   hpmctl status            -> one line per chip: plug, roles, tbt, usb
//   hpmctl cmd <chip> <4CC>  -> run a PD controller 4CC command (e.g. Gaid)
//   hpmctl watch             -> daemon: if a port has a cable but no Thunderbolt link
//                               after a grace period, cold-reset that port's PD chip
//                               so the connection renegotiates (an electronic replug).
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "AppleHPMLib.h"
#include <time.h>
#include <unistd.h>

#define GRACE_SEC      5   // normal Thunderbolt negotiation finishes in ~4 s
#define MAX_ATTEMPTS   5   // per plug-in; then wait until the cable is unplugged
#define POLL_SEC       2

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    char ts[32]; time_t t = time(NULL); strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    printf("%s ", ts); va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap); putchar('\n'); fflush(stdout);
}

static AppleHPMLib **open_hpm(IOCFPlugInInterface ***plugOut) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleHPM"));
    if (!s) return NULL;
    SInt32 score; IOCFPlugInInterface **plug = NULL; AppleHPMLib **d = NULL;
    if (IOCreatePlugInInterfaceForService(s, kAppleHPMLibType, kIOCFPlugInInterfaceID, &plug, &score)) { IOObjectRelease(s); return NULL; }
    IOObjectRelease(s);
    if ((*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kAppleHPMLibInterface), (LPVOID *)&d) != S_OK) return NULL;
    *plugOut = plug; return d;
}

static int rd32(AppleHPMLib **d, uint64_t chip, uint8_t reg, uint32_t *v) {
    unsigned char b[64] = {0}; uint64_t n = 0;
    if ((*d)->Read(d, chip, reg, b, 64, 0, &n) || n < 4) return -1;
    *v = b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24; return 0;
}


// Port state as seen by the PD controller.
typedef struct { int ok, plug, tbt; uint32_t st, ds; } port_t;

static port_t read_port(AppleHPMLib **d, uint64_t chip) {
    port_t p = {0};
    if (rd32(d, chip, 0x1a, &p.st) || rd32(d, chip, 0x5f, &p.ds)) return p;
    p.ok = 1; p.plug = p.st & 1; p.tbt = (p.ds >> 16) & 1; return p;
}

static int watch(AppleHPMLib **d) {
    time_t badSince[2] = {0}, nextTry[2] = {0}; int attempts[2] = {0}, lastPlug[2] = {-1, -1}, lastTbt[2] = {-1, -1};
    logf_("watch started (grace %ds, max %d resets per plug-in)", GRACE_SEC, MAX_ATTEMPTS);
    for (;;) {
        time_t now = time(NULL);
        for (uint64_t c = 0; c < 2; c++) {
            port_t p = read_port(d, c);
            if (!p.ok) continue;
            if (p.plug != lastPlug[c] || p.tbt != lastTbt[c])
                logf_("port%llu plug=%d tbt=%d status=0x%08x data=0x%08x", c + 1, p.plug, p.tbt, p.st, p.ds);
            if (!p.plug) { attempts[c] = 0; badSince[c] = 0; nextTry[c] = 0; }      // unplugged: reset budget
            else if (p.tbt) { if (attempts[c]) logf_("port%llu Thunderbolt restored after %d reset(s)", c + 1, attempts[c]);
                              attempts[c] = 0; badSince[c] = 0; nextTry[c] = 0; }
            else {
                if (!badSince[c]) badSince[c] = now;
                if (now - badSince[c] >= GRACE_SEC && now >= nextTry[c] && attempts[c] < MAX_ATTEMPTS) {
                    attempts[c]++;
                    IOReturn r = (*d)->Command(d, c, 'Gaid', 0);
                    logf_("port%llu cable present without Thunderbolt for %lds: reset %d/%d (ioreturn=0x%x)",
                          c + 1, (long)(now - badSince[c]), attempts[c], MAX_ATTEMPTS, r);
                    nextTry[c] = now + 15 * attempts[c];                              // 15, 30, 45 ... s backoff
                    if (attempts[c] == MAX_ATTEMPTS) logf_("port%llu giving up until the cable is unplugged", c + 1);
                }
            }
            lastPlug[c] = p.plug; lastTbt[c] = p.tbt;
        }
        sleep(POLL_SEC);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: hpmctl status | watch | cmd <chip> <4CC>\n"); return 64; }
    IOCFPlugInInterface **plug = NULL; AppleHPMLib **d = open_hpm(&plug);
    if (!d) { fprintf(stderr, "cannot open AppleHPM (root required)\n"); return 2; }
    int rc = 0;
    if (!strcmp(argv[1], "watch")) {
        rc = watch(d);
    } else if (!strcmp(argv[1], "status")) {
        for (uint64_t c = 0; c < 2; c++) {
            uint32_t st = 0, ds = 0;
            if (rd32(d, c, 0x1a, &st) || rd32(d, c, 0x5f, &ds)) { printf("chip%llu read-error\n", c); rc = 1; continue; }
            printf("chip%llu plug=%u conn=%u power=%s data=%s dataConn=%u usb2=%u usb3=%u tbt=%u status=0x%08x data=0x%08x\n",
                   c, st & 1, (st >> 1) & 7, (st >> 5) & 1 ? "source" : "sink", (st >> 6) & 1 ? "DFP" : "UFP",
                   ds & 1, (ds >> 4) & 1, (ds >> 5) & 1, (ds >> 16) & 1, st, ds);
        }
    } else if (!strcmp(argv[1], "cmd") && argc == 4 && strlen(argv[3]) == 4) {
        uint64_t chip = strtoull(argv[2], NULL, 0);
        uint32_t cc = (uint32_t)argv[3][0] << 24 | argv[3][1] << 16 | argv[3][2] << 8 | argv[3][3];
        IOReturn r = (*d)->Command(d, chip, cc, 0);
        unsigned char b[64] = {0}; uint64_t n = 0;
        (*d)->Read(d, chip, 0x08, b, 64, 0, &n);  // CMD1 register: 0 = done, "!CMD" = rejected
        printf("command %s chip%llu ioreturn=0x%x cmdreg=%02x%02x%02x%02x\n", argv[3], chip, r, b[0], b[1], b[2], b[3]);
        rc = r ? 1 : 0;
    } else { fprintf(stderr, "bad args\n"); rc = 64; }
    (*d)->Release(d); IODestroyPlugInInterface(plug);
    return rc;
}
