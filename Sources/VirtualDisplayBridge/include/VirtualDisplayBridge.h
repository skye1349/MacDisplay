#ifndef VIRTUAL_DISPLAY_BRIDGE_H
#define VIRTUAL_DISPLAY_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *MDVirtualDisplayHandle;

bool MDVirtualDisplayAPIAvailable(void);

bool MDVirtualDisplayCreate(
    const char *name,
    uint32_t framebufferWidth,
    uint32_t framebufferHeight,
    uint32_t refreshRate,
    bool hiDPI,
    uint32_t serialNumber,
    MDVirtualDisplayHandle *outHandle,
    uint32_t *outDisplayID,
    char *errorBuffer,
    size_t errorBufferSize
);

void MDVirtualDisplayRelease(MDVirtualDisplayHandle handle);

#ifdef __cplusplus
}
#endif

#endif
