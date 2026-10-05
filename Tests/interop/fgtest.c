// Drives the firmware's real fg_stream.c / fg_secure.c on the host.
// stdin lines:  cmd <64 hex> | key <usage> <pressed> <mods> | tick <ms> | cancel | sup <keycode> <pressed>
// stdout lines: resp <hex> | frame <hex> | evt <hex> | sup <0|1>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fg_stream.h"
#include "fg_proto.h"

static uint32_t now_ms;
uint32_t timer_read32(void) { return now_ms; }

static void hex(const char *tag, const uint8_t *p, int n) {
    printf("%s ", tag);
    for (int i = 0; i < n; i++) printf("%02x", p[i]);
    printf("\n"); fflush(stdout);
}

void raw_hid_send(uint8_t *data, uint8_t length) {
    hex(data[0] == FG_EVT_STREAM_FRAME ? "frame" : "evt", data, length);
}

int main(void) {
    char line[256];
    while (fgets(line, sizeof line, stdin)) {
        if (!strncmp(line, "cmd ", 4)) {
            uint8_t data[32], resp[32] = {0};
            for (int i = 0; i < 32; i++) { unsigned v; sscanf(line + 4 + 2 * i, "%2x", &v); data[i] = v; }
            fg_stream_handle(data, resp);
            hex("resp", resp, 32);
        } else if (!strncmp(line, "key ", 4)) {
            unsigned u, p, m; sscanf(line + 4, "%u %u %u", &u, &p, &m);
            fg_stream_emit(u, p, m);
        } else if (!strncmp(line, "sup ", 4)) {
            unsigned k, p; sscanf(line + 4, "%u %u", &k, &p);
            printf("sup %d\n", fg_stream_suppress(k, p) ? 1 : 0); fflush(stdout);
        } else if (!strncmp(line, "cancel", 6)) {
            fg_stream_cancel();
        } else if (!strncmp(line, "tick ", 5)) {
            now_ms += (uint32_t)atoi(line + 5);
            fg_stream_task();
        }
    }
    return 0;
}
