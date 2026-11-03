#ifndef USHR_USB_H
#define USHR_USB_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to an IOUSBDeviceInterface obtained WITHOUT USBDeviceOpen
/// (the audio driver owns the device; only default-pipe vendor requests are used).
typedef struct ushr_dev ushr_dev;

ushr_dev *ushr_dev_create(io_service_t service, kern_return_t *err);
void ushr_dev_destroy(ushr_dev *dev);

/// bmRequestType 0x40, wValue 0, wIndex 0, 1000 ms timeouts.
kern_return_t ushr_dev_vendor_out(ushr_dev *dev, uint8_t bRequest, const uint8_t *buf, uint16_t len);
/// bmRequestType 0xC0, wValue 0, wIndex 0, 1000 ms timeouts. `actual` receives bytes transferred.
kern_return_t ushr_dev_vendor_in(ushr_dev *dev, uint8_t bRequest, uint8_t *buf, uint16_t len, uint16_t *actual);

#ifdef __cplusplus
}
#endif

#endif
