#include "ushr_usb.h"

#include <stdlib.h>
#include <string.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

// IOUSBLib's device interface is deprecated in recent SDKs but remains the only
// way to issue default-pipe requests without opening/seizing the device.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define USHR_TIMEOUT_MS 1000

struct ushr_dev {
    IOUSBDeviceInterface942 **intf;
};

ushr_dev *ushr_dev_create(io_service_t service, kern_return_t *err)
{
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || plug == NULL) {
        if (err) *err = (kr != KERN_SUCCESS) ? kr : kIOReturnError;
        return NULL;
    }

    IOUSBDeviceInterface942 **intf = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID942), (LPVOID *)&intf);
    IODestroyPlugInInterface(plug);
    if (hr != S_OK || intf == NULL) {
        if (err) *err = kIOReturnUnsupported;
        return NULL;
    }

    ushr_dev *dev = calloc(1, sizeof(*dev));
    if (dev == NULL) {
        (*intf)->Release(intf);
        if (err) *err = kIOReturnNoMemory;
        return NULL;
    }
    dev->intf = intf;
    if (err) *err = KERN_SUCCESS;
    return dev;
}

void ushr_dev_destroy(ushr_dev *dev)
{
    if (dev == NULL) return;
    if (dev->intf) (*dev->intf)->Release(dev->intf);
    free(dev);
}

static kern_return_t request(ushr_dev *dev, uint8_t type, uint8_t bRequest, void *buf, uint16_t len, uint16_t *actual)
{
    if (dev == NULL || dev->intf == NULL) return kIOReturnNoDevice;
    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof(req));
    req.bmRequestType = type;
    req.bRequest = bRequest;
    req.wValue = 0;
    req.wIndex = 0;
    req.wLength = len;
    req.pData = buf;
    req.noDataTimeout = USHR_TIMEOUT_MS;
    req.completionTimeout = USHR_TIMEOUT_MS;
    kern_return_t kr = (*dev->intf)->DeviceRequestTO(dev->intf, &req);
    if (actual) *actual = (kr == KERN_SUCCESS) ? (uint16_t)req.wLenDone : 0;
    return kr;
}

kern_return_t ushr_dev_vendor_out(ushr_dev *dev, uint8_t bRequest, const uint8_t *buf, uint16_t len)
{
    return request(dev, 0x40, bRequest, (void *)buf, len, NULL);
}

kern_return_t ushr_dev_vendor_in(ushr_dev *dev, uint8_t bRequest, uint8_t *buf, uint16_t len, uint16_t *actual)
{
    return request(dev, 0xC0, bRequest, buf, len, actual);
}
